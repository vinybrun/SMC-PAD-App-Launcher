#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
#  Pad Magic — Interactive Installer
#  Installs the Pad Magic MIDI-to-window-focus suite for GNOME 50.
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

# === Paths ================================================================
APP_NAME="Pad Magic"
INSTALL_DIR="${PAD_MAGIC_PREFIX:-$HOME/.local/lib/pad-magic}"
VENV_DIR="$INSTALL_DIR/venv"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config"
SYSTEMD_DIR="$CONFIG_DIR/systemd/user"
EXTENSION_SRC="gnome-shell/pad-magic-window-activator@pad-magic"
EXTENSION_UUID="pad-magic-window-activator@pad-magic"
EXTENSION_DST="$HOME/.local/share/gnome-shell/extensions/$EXTENSION_UUID"
CONFIG_FILE="$CONFIG_DIR/midi-triggers.json"
BLE_CONFIG_FILE="$CONFIG_DIR/midi-ble-bridge.json"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# === Terminal colours =====================================================
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; DIM=''; NC=''
fi

info()  { printf "${BLUE}[info]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[  ok]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[warn]${NC} %s\n" "$*"; }
fail()  { printf "${RED}[fail]${NC} %s\n" "$*"; }
step()  { printf "\n${BOLD}━━━ %s ━━━${NC}\n\n" "$*"; }
banner() {
    printf "\n${BOLD}"
    printf "  ╔═══════════════════════════════════════╗\n"
    printf "  ║         Pad Magic — Installer         ║\n"
    printf "  ║   MIDI controller → GNOME 50 focus    ║\n"
    printf "  ╚═══════════════════════════════════════╝\n"
    printf "${NC}\n"
}

ask_yn() {
    local prompt="$1" default="${2:-y}" yn_hint="[Y/n]"
    [[ "$default" == "n" ]] && yn_hint="[y/N]"
    local response
    read -rp "  $prompt $yn_hint: " response
    response="${response:-$default}"
    [[ "$response" =~ ^[Yy] ]]
}

CHOICE=""
ask_choice() {
    local prompt="$1"; shift
    local options=("$@")
    local i
    for i in "${!options[@]}"; do
        printf "  %d) %s\n" "$((i+1))" "${options[$i]}"
    done
    while true; do
        read -rp "  $prompt [1-${#options[@]}]: " CHOICE
        if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#options[@]} )); then
            return 0
        fi
        printf "  Invalid selection. Try again.\n"
    done
}

press_enter() {
    read -rp "  Press Enter to continue..." _unused
}

# === Uninstall ============================================================
do_uninstall() {
    step "Uninstalling $APP_NAME"

    if command -v systemctl &>/dev/null; then
        for svc in midi-execute midi-ble-bridge kitty-midi-backend; do
            local unit="${svc}.service"
            if systemctl --user is-active "$unit" &>/dev/null; then
                systemctl --user stop "$unit" 2>/dev/null || true
                ok "Stopped $unit"
            fi
            if systemctl --user is-enabled "$unit" &>/dev/null; then
                systemctl --user disable "$unit" 2>/dev/null || true
                ok "Disabled $unit"
            fi
            if [[ -f "$SYSTEMD_DIR/$unit" ]]; then
                rm -f "$SYSTEMD_DIR/$unit"
                ok "Removed $SYSTEMD_DIR/$unit"
            fi
        done
        systemctl --user daemon-reload 2>/dev/null || true
    fi

    if [[ -d "$EXTENSION_DST" ]]; then
        rm -rf "$EXTENSION_DST"
        ok "Removed GNOME extension"
    fi

    if [[ -f "$BIN_DIR/pad-magic" ]]; then
        rm -f "$BIN_DIR/pad-magic"
        ok "Removed $BIN_DIR/pad-magic"
    fi

    for name in raise-or-launch kitty-slot; do
        if [[ -L "$BIN_DIR/$name" || -e "$BIN_DIR/$name" ]]; then
            rm -f "$BIN_DIR/$name"
            ok "Removed $BIN_DIR/$name"
        fi
    done

    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        ok "Removed $INSTALL_DIR"
    fi

    if ask_yn "Remove configuration files ($CONFIG_FILE)?" "n"; then
        rm -f "$CONFIG_FILE" "$BLE_CONFIG_FILE"
        ok "Removed configuration files"
    else
        info "Kept configuration files"
    fi

    printf "\n${GREEN}${BOLD}Uninstall complete.${NC}\n"
    exit 0
}

# === Detect system ========================================================
PKG_MANAGER=""
DISTRO_NAME=""
DISTRO_VERSION=""
GNOME_VERSION=""

detect_system() {
    step "Step 1/6 — System Detection"

    # OS
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        DISTRO_NAME="${NAME:-Linux}"
        DISTRO_VERSION="${VERSION_ID:-unknown}"
    else
        DISTRO_NAME="Linux"
        DISTRO_VERSION="unknown"
    fi
    ok "Operating system: $DISTRO_NAME $DISTRO_VERSION"

    # Package manager
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
    elif command -v pacman &>/dev/null; then
        PKG_MANAGER="pacman"
    elif command -v zypper &>/dev/null; then
        PKG_MANAGER="zypper"
    else
        PKG_MANAGER=""
        warn "Could not detect package manager — you may need to install dependencies manually"
    fi
    [[ -n "$PKG_MANAGER" ]] && ok "Package manager: $PKG_MANAGER"

    # GNOME
    if command -v gnome-shell &>/dev/null; then
        GNOME_VERSION="$(gnome-shell --version 2>/dev/null | grep -oP '\d+' | head -1 || echo "")"
    fi

    if [[ -z "$GNOME_VERSION" ]]; then
        warn "Could not detect GNOME Shell version"
        if ! ask_yn "Continue anyway? (Pad Magic requires GNOME 50)" "n"; then
            fail "Aborting."
            exit 1
        fi
    elif [[ "$GNOME_VERSION" != "50" ]]; then
        warn "Detected GNOME $GNOME_VERSION — Pad Magic is built for GNOME 50"
        if ! ask_yn "Continue anyway?" "n"; then
            fail "Aborting."
            exit 1
        fi
    else
        ok "GNOME Shell: $GNOME_VERSION"
    fi

    # Python
    if command -v python3 &>/dev/null; then
        local pyver
        pyver="$(python3 --version 2>&1 | grep -oP '\d+\.\d+\.\d+' || echo "unknown")"
        ok "Python 3: $pyver"
    else
        fail "Python 3 is required but not found"
        exit 1
    fi

    # Existing installation
    if [[ -d "$INSTALL_DIR" ]]; then
        warn "Existing Pad Magic installation found at $INSTALL_DIR"
        info "This installer will upgrade the existing installation"
    fi
}

# === Dependencies =========================================================
install_dependencies() {
    step "Step 2/6 — Dependencies"

    # System packages needed for building python-rtmidi
    local sys_pkgs=()
    local need_install=false

    case "$PKG_MANAGER" in
        apt)
            local apt_pkgs=(python3-dev python3-venv libasound2-dev librtmidi-dev)
            for pkg in "${apt_pkgs[@]}"; do
                if dpkg -l "$pkg" &>/dev/null 2>&1; then
                    ok "$pkg (installed)"
                else
                    sys_pkgs+=("$pkg")
                    need_install=true
                fi
            done
            # Check optional
            if ! command -v gdbus &>/dev/null; then
                sys_pkgs+=(libglib2.0-bin)
                need_install=true
            fi
            ;;
        dnf)
            local dnf_pkgs=(python3-devel alsa-lib-devel rtmidi-devel)
            for pkg in "${dnf_pkgs[@]}"; do
                if rpm -q "$pkg" &>/dev/null 2>&1; then
                    ok "$pkg (installed)"
                else
                    sys_pkgs+=("$pkg")
                    need_install=true
                fi
            done
            ;;
        pacman)
            local pac_pkgs=(python alsa-lib rtmidi)
            for pkg in "${pac_pkgs[@]}"; do
                if pacman -Qi "$pkg" &>/dev/null 2>&1; then
                    ok "$pkg (installed)"
                else
                    sys_pkgs+=("$pkg")
                    need_install=true
                fi
            done
            ;;
        zypper)
            local zyp_pkgs=(python3-devel alsa-devel librtmidi-devel)
            for pkg in "${zyp_pkgs[@]}"; do
                if rpm -q "$pkg" &>/dev/null 2>&1; then
                    ok "$pkg (installed)"
                else
                    sys_pkgs+=("$pkg")
                    need_install=true
                fi
            done
            ;;
    esac

    if $need_install && [[ ${#sys_pkgs[@]} -gt 0 ]]; then
        info "The following system packages are needed:"
        for pkg in "${sys_pkgs[@]}"; do
            printf "    - %s\n" "$pkg"
        done

        if ask_yn "Install them now? (requires sudo)"; then
            case "$PKG_MANAGER" in
                apt)    sudo apt-get update -qq && sudo apt-get install -y -qq "${sys_pkgs[@]}" ;;
                dnf)    sudo dnf install -y "${sys_pkgs[@]}" ;;
                pacman) sudo pacman -S --noconfirm "${sys_pkgs[@]}" ;;
                zypper) sudo zypper install -y "${sys_pkgs[@]}" ;;
            esac
            ok "System packages installed"
        else
            warn "Skipping system packages — Python package build may fail"
        fi
    else
        ok "System build dependencies satisfied"
    fi

    # Create or update Python virtual environment
    info "Setting up Python virtual environment..."
    if [[ ! -d "$VENV_DIR" ]]; then
        mkdir -p "$INSTALL_DIR"
        python3 -m venv "$VENV_DIR"
        ok "Created virtual environment at $VENV_DIR"
    else
        ok "Virtual environment exists at $VENV_DIR"
    fi

    info "Installing Python packages (mido, python-rtmidi)..."
    "$VENV_DIR/bin/pip" install --quiet --upgrade pip
    "$VENV_DIR/bin/pip" install --quiet mido python-rtmidi
    ok "Core Python packages installed"

    # Verify mido works
    if "$VENV_DIR/bin/python3" -c "import mido" 2>/dev/null; then
        ok "MIDI library verified"
    else
        fail "Failed to import mido — check the install log above"
        exit 1
    fi

    # Optional: check for common tools
    printf "\n"
    info "Checking optional tools:"
    if command -v gdbus &>/dev/null; then
        ok "gdbus (for GNOME D-Bus window control)"
    else
        warn "gdbus not found — raise-or-launch needs it for GNOME window activation"
    fi

    if command -v kitty &>/dev/null; then
        ok "kitty terminal (for named terminal slots)"
    elif [[ -z "$PKG_MANAGER" ]]; then
        info "kitty not found — install manually for terminal slot bindings"
    elif ask_yn "kitty terminal not found — install now? (needed for terminal slot bindings, requires sudo)"; then
        case "$PKG_MANAGER" in
            apt)    sudo apt-get install -y -qq kitty ;;
            dnf)    sudo dnf install -y kitty ;;
            pacman) sudo pacman -S --noconfirm kitty ;;
            zypper) sudo zypper install -y kitty ;;
        esac
        if command -v kitty &>/dev/null; then
            ok "kitty installed"
        else
            warn "kitty install did not complete — terminal slot bindings will not work"
        fi
    else
        info "Skipping kitty install — terminal slot bindings will not work"
    fi

    if command -v playerctl &>/dev/null; then
        ok "playerctl (for media control bindings)"
    else
        info "playerctl not found — media control bindings will be unavailable"
    fi
}

# === Install files ========================================================
install_files() {
    step "Step 3/6 — Installing Files"

    local runtime_files=(
        midi_ble_bridge.py
        midi_execute.py
        midi_configure.py
        midi_triggers_common.py
        kitty-slot
        raise-or-launch
    )

    mkdir -p "$INSTALL_DIR"

    for name in "${runtime_files[@]}"; do
        local src="$SOURCE_DIR/$name"
        if [[ ! -f "$src" ]]; then
            warn "Missing source file: $name (skipping)"
            continue
        fi
        cp -f "$src" "$INSTALL_DIR/$name"
        if [[ -x "$src" ]]; then
            chmod 755 "$INSTALL_DIR/$name"
        else
            chmod 644 "$INSTALL_DIR/$name"
        fi
    done
    ok "Runtime scripts installed to $INSTALL_DIR"

    # Shell helpers live in $INSTALL_DIR (a lib dir, not on PATH). MIDI
    # bindings invoke them by bare name, so symlink them into $BIN_DIR
    # which IS on the systemd user PATH. Force +x in case the repo copies
    # lost the executable bit.
    mkdir -p "$BIN_DIR"
    local helper_scripts=(raise-or-launch kitty-slot)
    for name in "${helper_scripts[@]}"; do
        if [[ -f "$INSTALL_DIR/$name" ]]; then
            chmod 755 "$INSTALL_DIR/$name"
            ln -sf "$INSTALL_DIR/$name" "$BIN_DIR/$name"
            ok "Linked $name -> $BIN_DIR/$name"
        fi
    done

    # GNOME Shell extension
    if [[ -d "$SOURCE_DIR/$EXTENSION_SRC" ]]; then
        mkdir -p "$EXTENSION_DST"
        cp -f "$SOURCE_DIR/$EXTENSION_SRC"/* "$EXTENSION_DST/"
        chmod 644 "$EXTENSION_DST"/*
        ok "GNOME Shell extension installed to $EXTENSION_DST"
        info "You may need to log out and back in (or run: gnome-extensions enable $EXTENSION_UUID)"
    else
        warn "GNOME extension source not found in repo — skipping"
    fi

    # Install pad-magic CLI wrapper
    mkdir -p "$BIN_DIR"
    write_cli_wrapper
    ok "CLI tool installed: $BIN_DIR/pad-magic"

    # Ensure ~/.local/bin is on PATH
    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        warn "$BIN_DIR is not on your PATH"
        info "Add this to your ~/.bashrc or ~/.profile:"
        printf "    export PATH=\"%s:\$PATH\"\n" "$BIN_DIR"
    fi
}

write_cli_wrapper() {
    cat > "$BIN_DIR/pad-magic" << CLIWRAPPER
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$INSTALL_DIR"
VENV_PYTHON="$VENV_DIR/bin/python3"
CONFIG_FILE="$CONFIG_FILE"

case "\${1:-help}" in
    configure)
        exec "\$VENV_PYTHON" "\$INSTALL_DIR/midi_configure.py"
        ;;
    status)
        echo "Pad Magic service status:"
        echo ""
        for svc in midi-execute midi-ble-bridge kitty-midi-backend; do
            unit="\${svc}.service"
            if systemctl --user cat "\$unit" &>/dev/null; then
                systemctl --user status "\$unit" --no-pager 2>/dev/null || true
                echo ""
            fi
        done
        ;;
    restart)
        systemctl --user restart midi-execute.service
        echo "Restarted midi-execute.service"
        ;;
    stop)
        systemctl --user stop midi-execute.service 2>/dev/null || true
        systemctl --user stop midi-ble-bridge.service 2>/dev/null || true
        systemctl --user stop kitty-midi-backend.service 2>/dev/null || true
        echo "Stopped all Pad Magic services."
        ;;
    start)
        systemctl --user start midi-execute.service
        echo "Started midi-execute.service"
        ;;
    logs)
        shift
        unit="\${1:-midi-execute}"
        journalctl --user -u "\${unit}.service" -f
        ;;
    uninstall)
        exec bash "$SOURCE_DIR/install.sh" --uninstall
        ;;
    help|--help|-h|"")
        cat << 'HELPEOF'
Pad Magic — MIDI controller to GNOME window focus

Usage: pad-magic <command>

Commands:
  configure    Open the interactive binding configurator
  status       Show service status
  start        Start all Pad Magic services
  stop         Stop all Pad Magic services
  restart      Restart the MIDI executor service
  logs [svc]   Follow logs (default: midi-execute, options: midi-ble-bridge, kitty-midi-backend)
  uninstall    Uninstall Pad Magic
  help         Show this help

Configuration file: $CONFIG_FILE
HELPEOF
        ;;
    *)
        echo "Unknown command: \$1" >&2
        echo "Run 'pad-magic help' for usage." >&2
        exit 1
        ;;
esac
CLIWRAPPER
    chmod 755 "$BIN_DIR/pad-magic"
}

# === MIDI device setup ====================================================
MIDI_PORT=""
USE_BLE=false

setup_midi() {
    step "Step 4/6 — MIDI Controller Setup"

    ask_choice "How is your MIDI controller connected?" \
        "USB (controller shows up as a standard MIDI device)" \
        "Bluetooth Low Energy (BLE MIDI)" \
        "Skip MIDI setup for now (configure later with: pad-magic configure)"

    case "$CHOICE" in
        1) setup_midi_usb ;;
        2) setup_midi_ble ;;
        3)
            info "Skipping MIDI setup. Run 'pad-magic configure' later."
            return
            ;;
    esac
}

setup_midi_usb() {
    printf "\n"
    info "Please connect your MIDI controller via USB now."
    press_enter

    local ports_json
    ports_json="$("$VENV_DIR/bin/python3" << 'PYEOF'
import json, mido
try:
    ports = list(mido.get_input_names())
except Exception:
    ports = []
print(json.dumps(ports))
PYEOF
)"

    local port_count
    port_count="$(echo "$ports_json" | "$VENV_DIR/bin/python3" -c "import json,sys; print(len(json.load(sys.stdin)))")"

    if [[ "$port_count" -eq 0 ]]; then
        warn "No MIDI input ports detected."
        if ask_yn "Retry?" "y"; then
            setup_midi_usb
            return
        fi
        info "Skipping MIDI setup."
        return
    fi

    info "Found MIDI input ports:"
    local port_names=()
    while IFS= read -r name; do
        port_names+=("$name")
    done < <(echo "$ports_json" | "$VENV_DIR/bin/python3" -c "
import json, sys
for p in json.load(sys.stdin):
    print(p)
")

    ask_choice "Which is your MIDI controller?" "${port_names[@]}"
    MIDI_PORT="${port_names[$((CHOICE-1))]}"

    # Canonicalize (strip ALSA client numbers)
    MIDI_PORT="$("$VENV_DIR/bin/python3" -c "
import re, sys
name = sys.argv[1]
print(re.sub(r' \d+:\d+$', '', name).strip())
" "$MIDI_PORT")"

    ok "Selected MIDI port: $MIDI_PORT"
}

start_ble_bridge_service() {
    if ! command -v systemctl &>/dev/null; then
        warn "systemctl not found — starting BLE bridge in the background instead"
        nohup "$VENV_DIR/bin/python3" "$INSTALL_DIR/midi_ble_bridge.py" run \
            >/tmp/pad-magic-bridge.log 2>&1 &
        BRIDGE_BG_PID=$!
    else
        mkdir -p "$SYSTEMD_DIR"
        cat > "$SYSTEMD_DIR/midi-ble-bridge.service" << SVCEOF
[Unit]
Description=Pad Magic — BLE MIDI bridge

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$VENV_DIR/bin/python3 $INSTALL_DIR/midi_ble_bridge.py run
Restart=always
RestartSec=2
Environment=PYTHONUNBUFFERED=1
Environment=MIDO_BACKEND=mido.backends.rtmidi

[Install]
WantedBy=default.target
SVCEOF
        systemctl --user daemon-reload
        systemctl --user enable midi-ble-bridge.service 2>/dev/null || true
        if systemctl --user restart midi-ble-bridge.service 2>/dev/null; then
            ok "Started midi-ble-bridge.service"
        else
            warn "Failed to start midi-ble-bridge.service"
            return 1
        fi
    fi

    info "Waiting for virtual MIDI port 'Pad Magic BLE' to appear..."
    local deadline=$((SECONDS + 20))
    local discovered
    while (( SECONDS < deadline )); do
        discovered="$("$VENV_DIR/bin/python3" -c "
import mido, re
suffix = re.compile(r' \d+:\d+$')
for p in mido.get_input_names():
    if 'Pad Magic BLE' in p:
        print(suffix.sub('', p).strip())
        break
" 2>/dev/null)"
        if [[ -n "$discovered" ]]; then
            MIDI_PORT_DISCOVERED="$discovered"
            ok "Virtual port ready: $MIDI_PORT_DISCOVERED"
            return 0
        fi
        sleep 0.5
    done
    warn "Virtual port did not appear in 20s — check 'systemctl --user status midi-ble-bridge.service'"
    return 1
}

setup_midi_ble() {
    info "Installing BLE dependencies..."
    "$VENV_DIR/bin/pip" install --quiet bleak dbus-fast
    ok "BLE packages installed"

    printf "\n"
    info "Make sure your BLE MIDI controller is powered on and in pairing range."
    press_enter

    info "Scanning for BLE devices (this takes a few seconds)..."

    local scan_output
    scan_output="$("$VENV_DIR/bin/python3" "$INSTALL_DIR/midi_ble_bridge.py" scan --timeout 8 2>&1)" || true
    printf "%s\n" "$scan_output"

    if [[ -z "$scan_output" || "$scan_output" == *"No BLE devices"* ]]; then
        warn "No BLE devices found."
        if ask_yn "Retry?" "y"; then
            setup_midi_ble
            return
        fi
        info "Skipping BLE setup."
        return
    fi

    printf "\n"
    local device_name
    read -rp "  Enter your BLE MIDI device name (as shown above): " device_name
    device_name="${device_name:-SMC-PAD}"

    "$VENV_DIR/bin/python3" "$INSTALL_DIR/midi_ble_bridge.py" init \
        --device-name "$device_name"
    ok "BLE bridge configured for: $device_name"

    start_ble_bridge_service || true

    USE_BLE=true
    MIDI_PORT="${MIDI_PORT_DISCOVERED:-Pad Magic Bridge:Pad Magic BLE}"
    ok "MIDI port set to virtual BLE port: $MIDI_PORT"
}

# === Interactive binding configuration ====================================
configure_bindings() {
    step "Step 5/6 — Configure Bindings"

    if [[ -z "$MIDI_PORT" ]]; then
        info "No MIDI port configured — skipping binding setup."
        info "Run 'pad-magic configure' to set up bindings later."
        return
    fi

    info "Let's set up your MIDI controller bindings!"
    info "You'll press controls on your pad and choose what each one does."
    printf "\n"

    # Initialize config
    local knob_ccs="[]"
    local button_ccs="[]"
    local bindings="{}"
    local cooldowns="{}"

    # Load existing config if present
    if [[ -f "$CONFIG_FILE" ]]; then
        if ask_yn "Existing configuration found. Start fresh?" "n"; then
            info "Starting with fresh configuration"
        else
            info "Keeping existing bindings (new ones will be added)"
            local existing
            existing="$("$VENV_DIR/bin/python3" -c "
import json, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
print(json.dumps({
    'knob_ccs': c.get('knob_ccs', []),
    'button_ccs': c.get('button_ccs', []),
    'bindings': c.get('bindings', {}),
    'cooldowns': c.get('cooldowns', {}),
}))
" "$CONFIG_FILE" 2>/dev/null)" || true
            if [[ -n "$existing" ]]; then
                knob_ccs="$(echo "$existing" | "$VENV_DIR/bin/python3" -c "import json,sys; print(json.dumps(json.load(sys.stdin)['knob_ccs']))")"
                button_ccs="$(echo "$existing" | "$VENV_DIR/bin/python3" -c "import json,sys; print(json.dumps(json.load(sys.stdin)['button_ccs']))")"
                bindings="$(echo "$existing" | "$VENV_DIR/bin/python3" -c "import json,sys; print(json.dumps(json.load(sys.stdin)['bindings']))")"
                cooldowns="$(echo "$existing" | "$VENV_DIR/bin/python3" -c "import json,sys; print(json.dumps(json.load(sys.stdin)['cooldowns']))")"
            fi
        fi
    fi

    while true; do
        printf "\n"
        info "Press or turn something on your MIDI controller..."
        info "(The script will detect what you did)"
        printf "\n"

        local capture_result
        capture_result="$(MIDI_PORT="$MIDI_PORT" KNOB_CCS="$knob_ccs" BUTTON_CCS="$button_ccs" \
            "$VENV_DIR/bin/python3" << 'CAPTURE_EOF'
import json, os, sys, time
sys.path.insert(0, os.environ.get("INSTALL_DIR", "."))

port_name = os.environ["MIDI_PORT"]
knob_ccs = set(json.loads(os.environ.get("KNOB_CCS", "[]")))
button_ccs = set(json.loads(os.environ.get("BUTTON_CCS", "[]")))

import mido

def capture():
    with mido.open_input(port_name) as port:
        pending_note = None
        pending_deadline = 0.0

        while True:
            msg = port.poll()
            if msg is None:
                if pending_note is not None and time.monotonic() >= pending_deadline:
                    return {
                        "id": f"note:{pending_note}", "kind": "pad_hit",
                        "description": f"Pad hit on note {pending_note}",
                        "knob_ccs": sorted(knob_ccs), "button_ccs": sorted(button_ccs),
                    }
                time.sleep(0.01)
                continue

            if pending_note is not None:
                if msg.type in ("note_off", "note_on"):
                    note = getattr(msg, "note", None)
                    if note == pending_note:
                        if msg.type == "note_off" or getattr(msg, "velocity", 0) == 0:
                            return {
                                "id": f"note:{pending_note}", "kind": "pad_hit",
                                "description": f"Pad hit on note {pending_note}",
                                "knob_ccs": sorted(knob_ccs), "button_ccs": sorted(button_ccs),
                            }

            if msg.type == "note_on" and getattr(msg, "velocity", 0) > 0:
                note = getattr(msg, "note", None)
                if note is not None:
                    if pending_note is None:
                        pending_note = note
                        pending_deadline = time.monotonic() + 0.45
                        continue
                    else:
                        return {
                            "id": f"note:{pending_note}", "kind": "pad_hit",
                            "description": f"Pad hit on note {pending_note}",
                            "knob_ccs": sorted(knob_ccs), "button_ccs": sorted(button_ccs),
                        }

            if msg.type == "aftertouch" and pending_note is not None:
                return {
                    "id": f"aftertouch:{pending_note}", "kind": "pad_pressured",
                    "description": f"Pressure on pad {pending_note}",
                    "knob_ccs": sorted(knob_ccs), "button_ccs": sorted(button_ccs),
                }

            if msg.type == "control_change":
                control = getattr(msg, "control", None)
                value = getattr(msg, "value", 0)
                if control is None:
                    continue

                if control in knob_ccs:
                    return {
                        "id": f"cc:{control}", "kind": "knob_moved",
                        "description": f"Knob {control} moved",
                        "knob_ccs": sorted(knob_ccs), "button_ccs": sorted(button_ccs),
                    }
                if control in button_ccs:
                    if value > 0:
                        return {
                            "id": f"cc:{control}", "kind": "button_pressed",
                            "description": f"Button {control} pressed",
                            "knob_ccs": sorted(knob_ccs), "button_ccs": sorted(button_ccs),
                        }
                    continue

                if value == 0:
                    continue

                # Auto-classify unknown CC
                seen = {value}
                deadline = time.monotonic() + 0.4
                while time.monotonic() < deadline:
                    m = port.poll()
                    if m is not None and m.type == "control_change" and getattr(m, "control", None) == control:
                        seen.add(getattr(m, "value", 0))
                    elif m is None:
                        time.sleep(0.01)

                if len(seen) >= 3:
                    kind = "knob_moved"
                    knob_ccs.add(control)
                    desc = f"Knob {control} moved (auto-detected)"
                else:
                    kind = "button_pressed"
                    button_ccs.add(control)
                    desc = f"Button {control} pressed (auto-detected)"

                return {
                    "id": f"cc:{control}", "kind": kind,
                    "description": desc,
                    "knob_ccs": sorted(knob_ccs), "button_ccs": sorted(button_ccs),
                }

try:
    result = capture()
    print(json.dumps(result))
except Exception as e:
    print(json.dumps({"error": str(e)}), file=sys.stderr)
    sys.exit(1)
CAPTURE_EOF
)" || true

        if [[ -z "$capture_result" ]]; then
            warn "Failed to capture MIDI event."
            if ask_yn "Try again?" "y"; then
                continue
            fi
            break
        fi

        local trigger_id kind description
        trigger_id="$(echo "$capture_result" | "$VENV_DIR/bin/python3" -c "import json,sys; print(json.load(sys.stdin)['id'])")"
        kind="$(echo "$capture_result" | "$VENV_DIR/bin/python3" -c "import json,sys; print(json.load(sys.stdin)['kind'])")"
        description="$(echo "$capture_result" | "$VENV_DIR/bin/python3" -c "import json,sys; print(json.load(sys.stdin)['description'])")"

        # Update CC sets from capture
        knob_ccs="$(echo "$capture_result" | "$VENV_DIR/bin/python3" -c "import json,sys; print(json.dumps(json.load(sys.stdin)['knob_ccs']))")"
        button_ccs="$(echo "$capture_result" | "$VENV_DIR/bin/python3" -c "import json,sys; print(json.dumps(json.load(sys.stdin)['button_ccs']))")"

        printf "\n"
        ok "Detected: $description"

        # Choose action
        printf "\n"
        info "What should this control do?"
        ask_choice "Action type:" \
            "Launch or focus an application" \
            "Open a named terminal slot (kitty)" \
            "Media playback control" \
            "Run a custom command" \
            "Open a URL"

        local command=""
        case "$CHOICE" in
            1)  # Application
                printf "\n"
                read -rp "  Application WM class (e.g. 'firefox', 'google-chrome', 'org.gnome.Nautilus'): " app_class
                read -rp "  Launch command (e.g. 'firefox', 'google-chrome', 'nautilus'): " app_cmd
                if [[ -n "$app_class" && -n "$app_cmd" ]]; then
                    command="raise-or-launch --wm-class '$app_class' -- $app_cmd"
                elif [[ -n "$app_cmd" ]]; then
                    command="$app_cmd"
                fi
                ;;
            2)  # Terminal slot
                read -rp "  Slot name (e.g. 'dev', 'logs', 'server'): " slot_name
                slot_name="${slot_name:-default}"
                command="kitty-slot $slot_name"
                ;;
            3)  # Media
                ask_choice "Media action:" \
                    "Play / Pause" \
                    "Next track" \
                    "Previous track" \
                    "Volume up" \
                    "Volume down" \
                    "Mute toggle"
                local media_cmds=( \
                    "playerctl play-pause" \
                    "playerctl next" \
                    "playerctl previous" \
                    "pactl set-sink-volume @DEFAULT_SINK@ +5%" \
                    "pactl set-sink-volume @DEFAULT_SINK@ -5%" \
                    "pactl set-sink-mute @DEFAULT_SINK@ toggle" \
                )
                command="${media_cmds[$((CHOICE-1))]}"
                ;;
            4)  # Custom
                printf "  Examples:\n"
                printf "    notify-send 'Hello from MIDI'\n"
                printf "    gnome-terminal\n"
                printf "    /path/to/my/script.sh\n"
                read -rp "  Command: " command
                ;;
            5)  # URL
                read -rp "  URL: " url
                command="xdg-open '$url'"
                ;;
        esac

        if [[ -z "$command" ]]; then
            warn "No command set — skipping this binding"
        else
            ok "Binding: $description → $command"
        fi

        # Choose cooldown
        local cooldown="0.00"
        if [[ "$kind" == "knob_moved" ]]; then
            cooldown="0.40"
        elif [[ "$kind" == "pad_pressured" ]]; then
            cooldown="0.50"
        fi

        printf "\n"
        ask_choice "Repeat behavior if triggered again quickly:" \
            "Allow free repeat (cooldown: ${cooldown}s)" \
            "One-shot action (cooldown: 1.0s)" \
            "Enter custom cooldown"

        case "$CHOICE" in
            2) cooldown="1.00" ;;
            3)
                read -rp "  Cooldown in seconds: " cooldown
                cooldown="${cooldown:-0.00}"
                ;;
        esac

        # Update bindings JSON
        bindings="$(TRIGGER_ID="$trigger_id" KIND="$kind" COMMAND="$command" \
            BINDINGS="$bindings" "$VENV_DIR/bin/python3" -c "
import json, os
bindings = json.loads(os.environ['BINDINGS'])
bindings[os.environ['TRIGGER_ID']] = {
    'kind': os.environ['KIND'],
    'command': os.environ['COMMAND'],
}
print(json.dumps(bindings))
")"
        cooldowns="$(TRIGGER_ID="$trigger_id" COOLDOWN="$cooldown" \
            COOLDOWNS="$cooldowns" "$VENV_DIR/bin/python3" -c "
import json, os
cooldowns = json.loads(os.environ['COOLDOWNS'])
cooldowns[os.environ['TRIGGER_ID']] = float(os.environ['COOLDOWN'])
print(json.dumps(cooldowns))
")"

        printf "\n"
        if ! ask_yn "Add another binding?" "y"; then
            break
        fi
    done

    # Save config
    MIDI_PORT_VAL="$MIDI_PORT" KNOB_CCS="$knob_ccs" BUTTON_CCS="$button_ccs" \
        BINDINGS="$bindings" COOLDOWNS="$cooldowns" \
        "$VENV_DIR/bin/python3" << 'SAVE_EOF'
import json, os

config = {
    "port": os.environ["MIDI_PORT_VAL"],
    "knob_ccs": json.loads(os.environ["KNOB_CCS"]),
    "button_ccs": json.loads(os.environ["BUTTON_CCS"]),
    "cooldowns": json.loads(os.environ["COOLDOWNS"]),
    "bindings": json.loads(os.environ["BINDINGS"]),
}

path = os.path.expanduser("~/.config/midi-triggers.json")
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(config, f, indent=2)
os.chmod(path, 0o600)
SAVE_EOF

    ok "Configuration saved to $CONFIG_FILE"
}

# === Service setup ========================================================
setup_services() {
    step "Step 6/6 — Service Setup"

    if ! command -v systemctl &>/dev/null; then
        warn "systemctl not found — skipping service installation"
        info "You can run the scripts manually:"
        info "  $VENV_DIR/bin/python3 $INSTALL_DIR/midi_execute.py"
        return
    fi

    mkdir -p "$SYSTEMD_DIR"

    # midi-execute.service (always installed)
    cat > "$SYSTEMD_DIR/midi-execute.service" << SVCEOF
[Unit]
Description=Pad Magic — MIDI trigger executor

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$VENV_DIR/bin/python3 $INSTALL_DIR/midi_execute.py
Restart=always
RestartSec=2
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=default.target
SVCEOF
    ok "Wrote midi-execute.service"

    local services_to_enable=(midi-execute.service)

    # BLE bridge service (if using BLE)
    if $USE_BLE; then
        if [[ ! -f "$SYSTEMD_DIR/midi-ble-bridge.service" ]]; then
            cat > "$SYSTEMD_DIR/midi-ble-bridge.service" << SVCEOF
[Unit]
Description=Pad Magic — BLE MIDI bridge

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$VENV_DIR/bin/python3 $INSTALL_DIR/midi_ble_bridge.py run
Restart=always
RestartSec=2
Environment=PYTHONUNBUFFERED=1
Environment=MIDO_BACKEND=mido.backends.rtmidi

[Install]
WantedBy=default.target
SVCEOF
            ok "Wrote midi-ble-bridge.service"
        else
            ok "midi-ble-bridge.service already installed (started during Step 4)"
        fi
        services_to_enable+=(midi-ble-bridge.service)
    fi

    # Kitty backend service (optional)
    if command -v kitty &>/dev/null; then
        printf "\n"
        if ask_yn "Enable the kitty terminal slot backend? (creates persistent terminal windows managed by your MIDI pad)" "n"; then
            cat > "$SYSTEMD_DIR/kitty-midi-backend.service" << SVCEOF
[Unit]
Description=Pad Magic — kitty terminal backend
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStartPre=/usr/bin/rm -f %t/kitty-midi.sock
ExecStart=/usr/bin/kitty -o allow_remote_control=yes --listen-on unix:%t/kitty-midi.sock --start-as=minimized --override remember_window_size=no --override initial_window_width=84c --override initial_window_height=25c --override confirm_os_window_close=0
Restart=always
RestartSec=2

[Install]
WantedBy=graphical-session.target
SVCEOF
            ok "Wrote kitty-midi-backend.service"
            services_to_enable+=(kitty-midi-backend.service)
        fi
    fi

    # Enable and start
    printf "\n"
    info "Enabling services..."
    systemctl --user daemon-reload
    for svc in "${services_to_enable[@]}"; do
        systemctl --user enable "$svc" 2>/dev/null || true
        ok "Enabled $svc"
    done

    if [[ -f "$CONFIG_FILE" ]]; then
        info "Starting services..."
        for svc in "${services_to_enable[@]}"; do
            systemctl --user restart "$svc" 2>/dev/null || true
            ok "Started $svc"
        done
    else
        info "No MIDI config yet — services are enabled but won't start until you run: pad-magic configure"
    fi
}

# === Verification =========================================================
verify_install() {
    printf "\n"
    printf "${BOLD}━━━ Installation Summary ━━━${NC}\n\n"

    local all_ok=true

    if [[ -d "$INSTALL_DIR" ]]; then
        ok "Runtime files:   $INSTALL_DIR"
    else
        fail "Runtime files:   NOT FOUND"
        all_ok=false
    fi

    if [[ -d "$EXTENSION_DST" ]]; then
        ok "GNOME extension: $EXTENSION_DST"
    else
        warn "GNOME extension: not installed"
    fi

    if [[ -f "$BIN_DIR/pad-magic" ]]; then
        ok "CLI tool:        $BIN_DIR/pad-magic"
    else
        fail "CLI tool:        NOT FOUND"
        all_ok=false
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        local binding_count
        binding_count="$("$VENV_DIR/bin/python3" -c "
import json, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
print(len(c.get('bindings', {})))
" "$CONFIG_FILE" 2>/dev/null || echo "0")"
        ok "Config file:     $CONFIG_FILE ($binding_count bindings)"
    else
        info "Config file:     not yet created (run: pad-magic configure)"
    fi

    if command -v systemctl &>/dev/null; then
        for svc in midi-execute midi-ble-bridge kitty-midi-backend; do
            local unit="${svc}.service"
            if [[ -f "$SYSTEMD_DIR/$unit" ]]; then
                if systemctl --user is-active "$unit" &>/dev/null; then
                    ok "Service:         $unit (running)"
                else
                    info "Service:         $unit (installed, not running)"
                fi
            fi
        done
    fi

    printf "\n"
    if $all_ok; then
        printf "${GREEN}${BOLD}Installation complete!${NC}\n\n"
    else
        printf "${YELLOW}${BOLD}Installation finished with warnings.${NC}\n\n"
    fi

    printf "  ${BOLD}Quick reference:${NC}\n"
    printf "    pad-magic configure   Reconfigure MIDI bindings\n"
    printf "    pad-magic status      Check service status\n"
    printf "    pad-magic restart     Restart after config changes\n"
    printf "    pad-magic logs        Follow live logs\n"
    printf "    pad-magic uninstall   Remove Pad Magic\n"
    printf "\n"

    if [[ -d "$EXTENSION_DST" ]]; then
        printf "  ${YELLOW}Note:${NC} If the GNOME extension isn't active, enable it:\n"
        printf "    gnome-extensions enable %s\n" "$EXTENSION_UUID"
        printf "    (or log out and back in)\n\n"
    fi
}

# === Main =================================================================
main() {
    # Handle flags
    for arg in "$@"; do
        case "$arg" in
            --uninstall|-u)
                do_uninstall
                ;;
            --help|-h)
                printf "Usage: %s [--uninstall | --help]\n" "$0"
                printf "\nRun without arguments for the interactive installer.\n"
                exit 0
                ;;
        esac
    done

    banner
    detect_system
    install_dependencies
    install_files
    setup_midi
    configure_bindings
    setup_services
    verify_install
}

main "$@"

