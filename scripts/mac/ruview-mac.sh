#!/bin/bash
# Run RuView's sensing server on a Mac, built from this checkout.
#
#   bash scripts/mac/ruview-mac.sh install          one-off: tools, linked repos, build
#   bash scripts/mac/ruview-mac.sh start            simulated data, no hardware needed
#   bash scripts/mac/ruview-mac.sh start --wifi     this Mac's WiFi signal strength (coarse)
#   bash scripts/mac/ruview-mac.sh start --esp32    ESP32 nodes on your home network
#   bash scripts/mac/ruview-mac.sh stop | status | token | logs
#
# The server listens on this Mac only (127.0.0.1) and needs an API token,
# kept in ~/.ruview/api-token. Nothing is installed without asking first.
# Written for the macOS system bash (3.2).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE="$HOME/.ruview"
BIN="$REPO/v2/target/release/sensing-server"
HELPER="$STATE/bin/mac_wifi"
TOKEN_FILE="$STATE/api-token"
PID_FILE="$STATE/sensing-server.pid"
LOG_FILE="$STATE/sensing-server.log"
HTTP_PORT=3000
WS_PORT=3001
# The server's root page is a plain link list; the dashboard lives under /ui.
URL="http://localhost:$HTTP_PORT/ui/index.html"
# Only these linked repositories are needed to build the sensing server.
SUBMODULES="v2/crates/worldgraph v2/crates/ruforecast v2/crates/ruview-swarm vendor/rufield"

say()  { printf '\n==> %s\n' "$*"; }
die()  { printf '\nError: %s\n' "$*" >&2; exit 1; }
ask()  { printf '%s [y/N] ' "$1"; read -r reply; case "$reply" in y|Y|yes|Yes|YES) return 0 ;; *) return 1 ;; esac; }
# shellcheck source=/dev/null
load_cargo() { if [ -f "$HOME/.cargo/env" ]; then . "$HOME/.cargo/env"; fi; }

rust_version() {
    sed -n 's/^channel *= *"\(.*\)"/\1/p' "$REPO/v2/rust-toolchain.toml"
}

running_pid() {
    if [ -f "$PID_FILE" ]; then
        pid="$(cat "$PID_FILE")"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
    fi
    return 1
}

ensure_state_dir() {
    mkdir -p "$STATE/bin"
    chmod 700 "$STATE"
}

ensure_token() {
    ensure_state_dir
    if [ ! -s "$TOKEN_FILE" ]; then
        (umask 077 && openssl rand -hex 32 > "$TOKEN_FILE")
        say "Created a new API token in $TOKEN_FILE"
    fi
    chmod 600 "$TOKEN_FILE"
}

lan_subnet() {
    iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
    [ -n "$iface" ] || return 1
    ip="$(ipconfig getifaddr "$iface" 2>/dev/null)" || return 1
    echo "$ip" | awk -F. '{print $1"."$2"."$3".0/24"}'
}

cmd_install() {
    [ "$(uname -s)" = "Darwin" ] || die "This script is for macOS."
    [ "$(uname -m)" = "arm64" ] || say "Note: this is not an Apple Silicon Mac ($(uname -m)). Carrying on."

    if ! xcode-select -p >/dev/null 2>&1; then
        say "Apple's Command Line Tools are needed (git, the compiler and Swift)."
        xcode-select --install 2>/dev/null || true
        die "Finish the Command Line Tools install in the window that opened, then run this again."
    fi

    want="$(rust_version)"
    [ -n "$want" ] || die "Could not read the Rust version from v2/rust-toolchain.toml."
    load_cargo
    if ! command -v rustup >/dev/null 2>&1; then
        say "Rust is not installed."
        echo "This downloads the official installer from https://sh.rustup.rs and installs"
        echo "Rust $want into ~/.rustup and ~/.cargo. Your shell profile is left unchanged."
        ask "Install Rust now?" || die "Rust is needed to build RuView from source."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --profile minimal --default-toolchain "$want" --no-modify-path
        load_cargo
    fi
    command -v rustup >/dev/null 2>&1 || die "rustup is still not on PATH after installing."
    say "Making sure Rust $want is available"
    rustup toolchain install "$want" --profile minimal

    say "Fetching the linked repositories the server needs"
    # shellcheck disable=SC2086
    git -C "$REPO" submodule update --init --recursive --depth 1 $SUBMODULES

    say "Building the sensing server. The first build downloads crates and can take 10 to 30 minutes."
    (cd "$REPO/v2" && cargo build --release --locked -p wifi-densepose-sensing-server)
    [ -x "$BIN" ] || die "The build finished but $BIN is missing."

    ensure_state_dir
    say "Building the macOS WiFi helper (only used by 'start --wifi')"
    if swiftc -O "$REPO/archive/v1/src/sensing/mac_wifi.swift" -o "$HELPER"; then
        echo "Helper ready at $HELPER"
    else
        echo "Could not build the WiFi helper. 'start' and 'start --esp32' still work."
    fi

    ensure_token
    say "Installed. Start it with:  bash $0 start"
}

cmd_start() {
    [ -x "$BIN" ] || die "Not built yet. Run:  bash $0 install"
    if pid="$(running_pid)"; then
        say "Already running (pid $pid). Open $URL"
        return 0
    fi
    ensure_token

    mode="simulated"
    extra=""
    case "${1:-}" in
        "") ;;
        --wifi)
            [ -x "$HELPER" ] || die "The WiFi helper was not built. Re-run install."
            mode="wifi" ;;
        --esp32)
            subnet="${2:-}"
            if [ -z "$subnet" ]; then
                subnet="$(lan_subnet)" || die "Could not work out your network. Pass it, e.g.: start --esp32 192.168.1.0/24"
            fi
            mode="esp32"
            extra="--udp-bind 0.0.0.0 --udp-allow $subnet"
            echo "Accepting ESP32 frames from $subnet on UDP port 5005."
            echo "If macOS asks whether sensing-server may accept incoming connections, choose Allow." ;;
        *) die "Unknown option '$1'. Use --wifi or --esp32." ;;
    esac

    say "Starting the sensing server ($mode)"
    cd "$REPO/v2"
    # shellcheck disable=SC2086
    PATH="$STATE/bin:$PATH" RUVIEW_API_TOKEN="$(cat "$TOKEN_FILE")" nohup "$BIN" \
        --source "$mode" \
        --bind-addr 127.0.0.1 \
        --http-port "$HTTP_PORT" \
        --ws-port "$WS_PORT" \
        --ui-path "$REPO/ui" \
        $extra \
        >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"

    i=0
    until curl -fsS "http://127.0.0.1:$HTTP_PORT/health/live" >/dev/null 2>&1; do
        i=$((i + 1))
        if [ "$i" -ge 30 ] || ! running_pid >/dev/null; then
            echo "The server did not come up. Last lines of $LOG_FILE:"
            tail -n 20 "$LOG_FILE"
            exit 1
        fi
        sleep 1
    done

    pbcopy < "$TOKEN_FILE"
    say "Running at $URL"
    echo "Your API token is on the clipboard. In the dashboard open Settings, then API Access, and paste it."
    echo "Stop it with:  bash $0 stop"
    open "$URL"
}

cmd_stop() {
    if pid="$(running_pid)"; then
        kill "$pid"
        rm -f "$PID_FILE"
        say "Stopped (pid $pid)."
    else
        rm -f "$PID_FILE"
        say "Not running."
    fi
}

cmd_status() {
    if pid="$(running_pid)"; then
        echo "Running (pid $pid) at $URL"
        curl -fsS "http://127.0.0.1:$HTTP_PORT/health/live" && echo
    else
        echo "Not running."
    fi
}

case "${1:-}" in
    install) cmd_install ;;
    start)   shift; cmd_start "$@" ;;
    stop)    cmd_stop ;;
    status)  cmd_status ;;
    token)   ensure_token; pbcopy < "$TOKEN_FILE"; echo "API token copied to the clipboard." ;;
    logs)    tail -n 50 -f "$LOG_FILE" ;;
    *)       sed -n '2,11p' "$0"; exit 1 ;;
esac
