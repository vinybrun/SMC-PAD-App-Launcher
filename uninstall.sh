#!/usr/bin/env bash
#
# Pad Magic Uninstaller
# Cleanly removes the Pad Magic MIDI controller suite.
#
set -euo pipefail

INSTALL_DIR="${HOME}/.local/lib/pad-magic"
BIN_DIR="${HOME}/.local/bin"
SYSTEMD_DIR="${HOME}/.config/systemd/user"
GNOME_EXT_DIR="${HOME}/.local/share/gnome-shell/extensions"
EXTENSION_UUID="pad-magic-window-activator@pad-magic"

# Colours
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

ok_msg()   { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
info_msg() { printf "  ${DIM}%s${NC}\n" "$*"; }

printf "\n${BOLD}${CYAN}  Pad Magic — Uninstaller${NC}\n\n"

printf "  This will remove:\n"
printf "    • Systemd services  ${DIM}(pad-magic-*)${NC}\n"
printf "    • GNOME extension   ${DIM}(%s)${NC}\n" "$EXTENSION_UUID"
printf "    • Installed files   ${DIM}(%s)${NC}\n" "$INSTALL_DIR"
printf "    • CLI wrapper       ${DIM}(%s/pad-magic)${NC}\n" "$BIN_DIR"
printf "\n"

printf "  Are you sure you want to uninstall Pad Magic? ${DIM}[y/N]${NC} "
read -r confirm
confirm="${confirm,,}"
if [[ "$confirm" != "y" && "$confirm" != "yes" ]]; then
    echo "  Cancelled."
    exit 0
fi

echo

# ── Stop and remove systemd services ──────────────────────────────

if command -v systemctl >/dev/null 2>&1; then
    for svc in pad-magic-execute pad-magic-ble-bridge pad-magic-kitty-backend; do
        unit="${svc}.service"
        if [[ -f "$SYSTEMD_DIR/$unit" ]]; then
            systemctl --user stop "$unit" 2>/dev/null || true
            systemctl --user disable "$unit" 2>/dev/null || true
            rm -f "$SYSTEMD_DIR/$unit"
            ok_msg "Removed $unit"
        fi
    done
    systemctl --user daemon-reload 2>/dev/null || true
fi

# ── Disable GNOME extension ──────────────────────────────────────

if command -v gnome-extensions >/dev/null 2>&1; then
    gnome-extensions disable "$EXTENSION_UUID" 2>/dev/null || true
fi

if [[ -d "$GNOME_EXT_DIR/$EXTENSION_UUID" ]]; then
    rm -rf "$GNOME_EXT_DIR/$EXTENSION_UUID"
    ok_msg "Removed GNOME extension"
fi

# ── Remove installed files ────────────────────────────────────────

if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    ok_msg "Removed $INSTALL_DIR"
fi

# ── Remove CLI wrapper ────────────────────────────────────────────

if [[ -f "$BIN_DIR/pad-magic" ]]; then
    rm -f "$BIN_DIR/pad-magic"
    ok_msg "Removed $BIN_DIR/pad-magic"
fi

# ── Configuration files ──────────────────────────────────────────

echo
printf "  ${BOLD}Configuration files were kept:${NC}\n"
[[ -f "$HOME/.config/midi-triggers.json" ]]    && printf "    %s\n" "$HOME/.config/midi-triggers.json"
[[ -f "$HOME/.config/midi-ble-bridge.json" ]]  && printf "    %s\n" "$HOME/.config/midi-ble-bridge.json"
echo
printf "  Remove configuration files too? ${DIM}[y/N]${NC} "
read -r rm_config
rm_config="${rm_config,,}"
if [[ "$rm_config" == "y" || "$rm_config" == "yes" ]]; then
    rm -f "$HOME/.config/midi-triggers.json"
    rm -f "$HOME/.config/midi-ble-bridge.json"
    ok_msg "Configuration files removed"
else
    info_msg "Configuration files preserved for potential reinstall."
fi

printf "\n  ${GREEN}${BOLD}Pad Magic has been uninstalled.${NC}\n\n"
