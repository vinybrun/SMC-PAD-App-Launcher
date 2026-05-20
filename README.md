# SMC-PAD-App-Launcher

Bind MIDI pad hits, knob turns, and button presses to GNOME window focus and arbitrary shell actions. The project ships a daemon, an interactive configurator, an optional Bluetooth-LE-to-virtual-MIDI bridge, a small GNOME Shell extension for cross-Wayland window control, and a handful of helper scripts.

## What it does

```
MIDI hardware (USB or BLE)
     │
     ▼
midi_ble_bridge.py        (BLE devices only -> virtual ALSA MIDI port)
     │
     ▼
midi_execute.py           (daemon; reads ~/.config/midi-triggers.json,
                           dispatches each event to a shell command)
     │
     ▼
raise-or-launch / kitty-slot / your own scripts
     │
     ▼
GNOME Shell extension     (D-Bus; focuses / activates / lists windows)
```

`midi_configure.py` is the interactive companion you run once to record which physical pads, knobs, and buttons map to which commands.

## Components

| Path | Purpose |
| --- | --- |
| `midi_configure.py` | Interactive CLI. Listens to your MIDI device, lets you label each pad/knob/button, and writes `~/.config/midi-triggers.json`. |
| `midi_execute.py` | Long-running daemon. Reads the same JSON, listens on the configured MIDI input, runs the bound shell command for each event (with per-kind cooldowns). |
| `midi_triggers_common.py` | Shared event-normalisation helpers used by both Python tools (pad / button / knob / pressure classification, port-name canonicalisation). |
| `midi_ble_bridge.py` | Optional bridge for BLE MIDI devices: scans, connects, decodes the BLE MIDI packet format, and republishes events on a virtual ALSA port named `Pad Magic BLE`. Also has an `install` subcommand. See `BLE_BRIDGE.md`. |
| `raise-or-launch` | Bash helper. Activates a window matching `--title` / `--wm-class` / `--app-id` / etc., or runs the fallback command if no match is found. Uses the GNOME extension over D-Bus, falls back to `wmctrl` on X11. |
| `kitty-slot` | Bash helper. Manages a named `kitty` terminal "slot" — creates it on first call, focuses it on subsequent calls. |
| `gnome-shell/pad-magic-window-activator@pad-magic/extension.js` | GJS extension that exports the D-Bus API the bash helpers use. Required for window control on Wayland. |
| `gnome-shell/pad-magic-window-activator@pad-magic/metadata.json` | Extension metadata. Currently declares support for GNOME Shell 49 and 50. |
| `systemd/midi-ble-bridge.service` | User unit that runs `midi_ble_bridge.py run` as a service. |
| `systemd/kitty-midi-backend.service` | User unit that runs the kitty backend on demand. |
| `BLE_BRIDGE.md` | Detailed setup notes for the BLE bridge (scanning, init, install). |

## Requirements

- Linux with GNOME Shell **49 or 50** (the extension's declared `shell-version` range).
- Python 3.8+ (the code uses PEP 604 unions and `from __future__ import annotations`).
- A MIDI device, USB or BLE. The bindings are written for a Studio M-Tech-style pad controller but `midi_configure.py` learns the actual CCs/notes from your hardware, so other devices work too.
- `kitty` if you want to use `kitty-slot`.
- `wmctrl` only if you want the X11 fallback path in `raise-or-launch` / `kitty-slot`.

## Installation (end user)

### 1. Python dependencies

```bash
pip install mido python-rtmidi
# optional, only if you use the BLE bridge:
pip install bleak dbus-fast
```

`python-rtmidi` compiles against ALSA; install `libasound2-dev` (or your distro's equivalent) if pip needs to build from source.

### 2. GNOME Shell extension

```bash
mkdir -p ~/.local/share/gnome-shell/extensions
cp -r gnome-shell/pad-magic-window-activator@pad-magic \
      ~/.local/share/gnome-shell/extensions/
# Log out and back in (or restart the shell on X11), then:
gnome-extensions enable pad-magic-window-activator@pad-magic
```

The extension exports the D-Bus name `org.gnome.Shell.Extensions.PadMagicWindowActivator` on the session bus; without it, only the X11 `wmctrl` fallback works.

### 3. BLE bridge and systemd units

See `BLE_BRIDGE.md` for the full BLE-specific flow. The short version is:

```bash
python3 midi_ble_bridge.py scan
python3 midi_ble_bridge.py init --device-name "Your Device"
python3 midi_ble_bridge.py install
systemctl --user enable --now midi-ble-bridge.service
```

`install` copies the runtime files to `~/.local/lib/pad-magic` and writes the systemd user units, so the services keep working even if you move this checkout.

## Configuration

Two JSON files live under `~/.config/`:

- `~/.config/midi-triggers.json` — written by `midi_configure.py`, read by `midi_execute.py`. Each entry maps a normalised event id (`note:60`, `cc:38`, `aftertouch:60`, …) to a shell command and an optional per-event cooldown.
- `~/.config/midi-ble-bridge.json` — written by `midi_ble_bridge.py init`. Holds the BLE device name and the virtual-port name to expose.

Regenerate either at any time by re-running the corresponding tool; they preserve existing bindings on a best-effort basis.

## Usage

```bash
# One-time: bind your pads and knobs interactively.
python3 midi_configure.py

# Run the dispatcher daemon in the foreground (Ctrl-C to stop).
python3 midi_execute.py

# Focus Firefox if it's open, otherwise launch it.
./raise-or-launch --title "Firefox" -- firefox

# Show or create a kitty terminal called "dev".
./kitty-slot dev

# Or run things as user services:
systemctl --user start midi-ble-bridge.service
```

## GNOME Shell extension D-Bus API

Exposed on bus name `org.gnome.Shell.Extensions.PadMagicWindowActivator`, object path `/org/gnome/Shell/Extensions/PadMagicWindowActivator`, interface of the same name:

| Method | Signature | Notes |
| --- | --- | --- |
| `ActivateWindow` | `(s) -> b` | Activate the first window whose title matches the argument exactly. |
| `ActivateWindowMatching` | `(s) -> b` | Argument is a JSON object. Recognised fields: `title`, `titleContains`, `wmClass`, `wmClassInstance`, `appId`, `gtkApplicationId`, `sandboxedAppId`. Returns `true` if a match was activated. |
| `ListWindows` | `() -> s` | Returns a JSON array of all open windows with the metadata fields above. Useful for discovering match criteria. |
| `GetFocusedWindowTitle` | `() -> s` | Title of the currently focused window. |

You can poke it with `gdbus`:

```bash
gdbus call --session \
  --dest org.gnome.Shell.Extensions.PadMagicWindowActivator \
  --object-path /org/gnome/Shell/Extensions/PadMagicWindowActivator \
  --method org.gnome.Shell.Extensions.PadMagicWindowActivator.ListWindows
```

## Development

There are no tests or lint configs in-tree yet. The suggested toolchain is `ruff` + `mypy` for the Python sources and `shellcheck` for the bash helpers. If you are setting up a sandboxed / offline environment for an AI coding agent, see **`AGENTS.md`** for a single-shot apt + pip command that installs everything required to lint, type-check, and import the modules without a network connection or real MIDI hardware.

## License

GPLv3 — see `LICENSE`.
