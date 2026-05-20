#!/usr/bin/env python3

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import time
import mido

from midi_triggers_common import (
    ActivePadState,
    NormalizedEvent,
    cc_sets_from_config,
    choose_port_interactively,
    default_cooldown_for_kind,
    describe_event,
    describe_trigger,
    normalize_message,
)


CONFIG_PATH = Path.home() / ".config" / "midi-triggers.json"
SERVICE_NAME = "midi-execute.service"


def empty_config(port: str = "") -> dict:
    return {
        "port": port,
        "knob_ccs": [],
        "button_ccs": [],
        "cooldowns": {},
        "bindings": {},
    }


def normalize_config(config: dict) -> tuple[dict, bool]:
    if "bindings" in config:
        result = {
            "port": config.get("port", ""),
            "knob_ccs": sorted(set(config.get("knob_ccs", []))),
            "button_ccs": sorted(set(config.get("button_ccs", []))),
            "cooldowns": {
                str(trigger_id): float(value)
                for trigger_id, value in config.get("cooldowns", {}).items()
            },
            "bindings": {
                str(trigger_id): {
                    "kind": binding.get("kind", ""),
                    "command": binding.get("command", ""),
                }
                for trigger_id, binding in config.get("bindings", {}).items()
            },
        }
        if not result["knob_ccs"] and not result["button_ccs"]:
            knob, button = cc_sets_from_config(result)
            result["knob_ccs"] = sorted(knob)
            result["button_ccs"] = sorted(button)
        return result, False

    return empty_config(port=config.get("port", "")), "commands" in config


def load_config() -> dict:
    if CONFIG_PATH.exists():
        with CONFIG_PATH.open("r", encoding="utf-8") as f:
            config, migrated = normalize_config(json.load(f))
        if migrated:
            print("Existing config used the old broad-trigger format.")
            print("Starting from the same port with empty per-control bindings.")
        return config

    return empty_config()


def save_config(config: dict) -> None:
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with CONFIG_PATH.open("w", encoding="utf-8") as f:
        json.dump(config, f, indent=2)
    os.chmod(CONFIG_PATH, 0o600)


def restart_execute_service() -> tuple[bool, str]:
    try:
        result = subprocess.run(
            ["systemctl", "--user", "restart", SERVICE_NAME],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        return False, "systemctl not found; saved config without restarting the service."

    if result.returncode == 0:
        return True, f"Restarted {SERVICE_NAME}."

    details = (result.stderr or result.stdout).strip()
    if details:
        return False, f"Saved config, but could not restart {SERVICE_NAME}: {details}"
    return False, f"Saved config, but could not restart {SERVICE_NAME}."


def sorted_binding_ids(config: dict) -> list[str]:
    return sorted(
        config["bindings"],
        key=lambda trigger_id: (
            config["bindings"][trigger_id].get("kind", ""),
            describe_trigger(trigger_id, config["bindings"][trigger_id].get("kind", "")),
            trigger_id,
        ),
    )


def print_bindings(config: dict) -> None:
    bindings = sorted_binding_ids(config)
    if not bindings:
        print("  (none)")
        return

    for trigger_id in bindings:
        binding = config["bindings"][trigger_id]
        kind = binding["kind"]
        label = describe_trigger(trigger_id, kind)
        cooldown = float(config["cooldowns"].get(trigger_id, default_cooldown_for_kind(kind)))
        command = binding.get("command") or "(not set)"
        print(
            f"  {label} [{kind}] id={trigger_id} cooldown={cooldown:.2f}s command={command}"
        )


def recommended_one_shot_cooldown(kind: str) -> float:
    return {
        "pad_hit": 1.0,
        "button_pressed": 1.0,
        "knob_moved": 0.8,
        "pad_pressured": 0.8,
    }.get(kind, 1.0)


def choose_cooldown_for_binding(kind: str, existing: float | None = None) -> float:
    repeat_ready = default_cooldown_for_kind(kind)
    one_shot = recommended_one_shot_cooldown(kind)

    print("\nHow should this action behave if you trigger it again right away?")
    print(f"  1. Let it repeat freely ({repeat_ready:.2f}s cooldown)")
    print(f"  2. Treat it like a one-shot action ({one_shot:.2f}s cooldown)")
    print("  3. Enter a custom cooldown")
    if existing is not None:
        print(f"Press Enter to keep the current cooldown ({existing:.2f}s)")

    while True:
        choice = input("Cooldown choice: ").strip().lower()

        if choice == "" and existing is not None:
            return existing
        if choice == "1":
            return repeat_ready
        if choice == "2":
            return one_shot
        if choice == "3":
            raw = input("Custom cooldown in seconds: ").strip()
            try:
                return float(raw)
            except ValueError:
                print("Invalid number.")
                continue

        print("Choose 1, 2, or 3.")


def select_binding_id(config: dict, prompt: str) -> str | None:
    bindings = sorted_binding_ids(config)
    if not bindings:
        print("No bindings configured yet.")
        return None

    print()
    for idx, trigger_id in enumerate(bindings, start=1):
        binding = config["bindings"][trigger_id]
        label = describe_trigger(trigger_id, binding["kind"])
        command = binding.get("command") or "(not set)"
        print(f"  {idx}. {label} [{binding['kind']}] ({trigger_id}) - {command}")

    raw = input(prompt).strip()
    try:
        idx = int(raw)
    except ValueError:
        print("Invalid selection.")
        return None

    if not 1 <= idx <= len(bindings):
        print("Invalid selection.")
        return None

    return bindings[idx - 1]


def select_binding_ids(config: dict, prompt: str) -> list[str] | None:
    bindings = sorted_binding_ids(config)
    if not bindings:
        print("No bindings configured yet.")
        return None

    print()
    for idx, trigger_id in enumerate(bindings, start=1):
        binding = config["bindings"][trigger_id]
        label = describe_trigger(trigger_id, binding["kind"])
        command = binding.get("command") or "(not set)"
        print(f"  {idx}. {label} [{binding['kind']}] ({trigger_id}) - {command}")

    raw = input(prompt).strip()
    if not raw:
        print("Invalid selection.")
        return None

    selected_ids: list[str] = []
    seen_ids: set[str] = set()
    for part in raw.split(","):
        item = part.strip()
        try:
            idx = int(item)
        except ValueError:
            print("Invalid selection.")
            return None

        if not 1 <= idx <= len(bindings):
            print("Invalid selection.")
            return None

        trigger_id = bindings[idx - 1]
        if trigger_id not in seen_ids:
            selected_ids.append(trigger_id)
            seen_ids.add(trigger_id)

    return selected_ids


def auto_classify_cc(
    port, control: int, first_value: int, timeout: float = 0.4,
) -> str:
    """Collect CC events briefly and decide if a control is a knob or button."""
    seen_values = {first_value}
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        msg = port.poll()
        if msg is not None:
            if (
                msg.type == "control_change"
                and getattr(msg, "control", None) == control
            ):
                seen_values.add(getattr(msg, "value", 0))
        else:
            time.sleep(0.01)
    return "knob_moved" if len(seen_values) >= 3 else "button_pressed"


def capture_one_trigger(
    port_name: str,
    knob_ccs: set[int],
    button_ccs: set[int],
) -> tuple[str, str]:
    """Capture one MIDI gesture.  Unknown CCs are auto-classified and the
    caller's *knob_ccs* / *button_ccs* sets are updated in-place."""
    print("\nWaiting for one supported gesture...")
    print("Do one of these:")
    print("- move a knob")
    print("- hit a pad")
    print("- press and add pressure to a held pad")
    print("- press a button")
    print()

    state = ActivePadState()
    with mido.open_input(port_name) as port:
        pending_pad_hit = None
        pending_deadline = 0.0

        while True:
            msg = port.poll()
            if msg is None:
                if pending_pad_hit is not None and time.monotonic() >= pending_deadline:
                    print(f"Detected: {describe_event(pending_pad_hit)}")
                    print(f"Raw MIDI:  {pending_pad_hit.raw}")
                    return pending_pad_hit.id, pending_pad_hit.kind
                time.sleep(0.01)
                continue

            if pending_pad_hit is not None:
                is_same_note_release = (
                    msg.type in {"note_off", "note_on"}
                    and getattr(msg, "note", None) == pending_pad_hit.note
                    and (msg.type == "note_off" or getattr(msg, "velocity", 0) == 0)
                )
                if is_same_note_release:
                    print(f"Detected: {describe_event(pending_pad_hit)}")
                    print(f"Raw MIDI:  {pending_pad_hit.raw}")
                    return pending_pad_hit.id, pending_pad_hit.kind

            event = normalize_message(
                msg, state,
                knob_ccs=frozenset(knob_ccs),
                button_ccs=frozenset(button_ccs),
            )

            # Handle CC that isn't classified yet
            if event is None and msg.type == "control_change":
                control = getattr(msg, "control", None)
                value = getattr(msg, "value", 0)
                if control is not None and value > 0:
                    kind = auto_classify_cc(port, control, value)
                    if kind == "knob_moved":
                        knob_ccs.add(control)
                    else:
                        button_ccs.add(control)
                    event = NormalizedEvent(
                        kind=kind,
                        id=f"cc:{control}",
                        raw=str(msg),
                        control=control,
                    )
                    label = "knob" if kind == "knob_moved" else "button"
                    print(f"Auto-detected CC {control} as {label}")

            if event is None:
                continue

            if pending_pad_hit is not None and event.kind == "pad_pressured":
                print(f"Detected: {describe_event(event)}")
                print(f"Raw MIDI:  {event.raw}")
                return event.id, event.kind

            if pending_pad_hit is None and event.kind == "pad_hit":
                pending_pad_hit = event
                pending_deadline = time.monotonic() + 0.45
                continue

            print(f"Detected: {describe_event(event)}")
            print(f"Raw MIDI:  {event.raw}")
            return event.id, event.kind

    raise RuntimeError("Input stream ended unexpectedly.")


def find_desktop_apps() -> list[dict]:
    """Scan .desktop files and return a list of launchable applications."""
    import glob

    dirs = [
        "/usr/share/applications",
        "/usr/local/share/applications",
        os.path.expanduser("~/.local/share/applications"),
        "/var/lib/flatpak/exports/share/applications",
        os.path.expanduser("~/.local/share/flatpak/exports/share/applications"),
    ]
    apps: list[dict] = []
    seen: set[str] = set()

    for d in dirs:
        for path in sorted(glob.glob(os.path.join(d, "*.desktop"))):
            try:
                name = ""
                exec_cmd = ""
                wm_class = ""
                no_display = False
                with open(path, encoding="utf-8", errors="replace") as f:
                    in_entry = False
                    for line in f:
                        line = line.strip()
                        if line == "[Desktop Entry]":
                            in_entry = True
                            continue
                        if line.startswith("[") and line.endswith("]"):
                            in_entry = False
                            continue
                        if not in_entry:
                            continue
                        if line.startswith("Name=") and not name:
                            name = line.split("=", 1)[1].strip()
                        elif line.startswith("Exec="):
                            exec_cmd = line.split("=", 1)[1].strip()
                        elif line.startswith("StartupWMClass="):
                            wm_class = line.split("=", 1)[1].strip()
                        elif line.startswith("NoDisplay=true"):
                            no_display = True
                if no_display or not name or not exec_cmd:
                    continue
                key = name.lower()
                if key in seen:
                    continue
                seen.add(key)
                # Strip field codes like %U %f etc.
                launch = " ".join(
                    tok for tok in exec_cmd.split() if not tok.startswith("%")
                )
                apps.append({
                    "name": name,
                    "exec": launch,
                    "wm_class": wm_class,
                })
            except OSError:
                continue

    apps.sort(key=lambda a: a["name"].lower())
    return apps


def choose_action_command(trigger_label: str, existing_command: str = "") -> str:
    """Present action templates and return the shell command string."""
    print(f"\nWhat should '{trigger_label}' do?")
    print("  1. Launch or focus an application")
    print("  2. Open a named terminal slot (kitty)")
    print("  3. Media playback control")
    print("  4. Run a custom command")
    print("  5. Open a URL")
    if existing_command:
        print(f"  Press Enter to keep: {existing_command}")

    while True:
        choice = input("Action type [1-5]: ").strip()
        if choice == "" and existing_command:
            return existing_command

        if choice == "1":
            return _choose_app_command()
        if choice == "2":
            return _choose_terminal_slot()
        if choice == "3":
            return _choose_media_command()
        if choice == "4":
            return _choose_custom_command()
        if choice == "5":
            return _choose_url_command()
        print("Choose 1-5.")


def _choose_app_command() -> str:
    apps = find_desktop_apps()
    if apps:
        print("\nInstalled applications (showing first 20):")
        shown = apps[:20]
        for idx, app in enumerate(shown, start=1):
            print(f"  {idx:2}. {app['name']}")
        print(f"  {len(shown) + 1:2}. Search by name...")
        print(f"  {len(shown) + 2:2}. Enter manually")

        raw = input("Choose: ").strip()
        try:
            idx = int(raw)
            if 1 <= idx <= len(shown):
                app = shown[idx - 1]
                wm = app["wm_class"] or app["name"]
                return f"raise-or-launch --wm-class '{wm}' -- {app['exec']}"
            if idx == len(shown) + 1:
                query = input("Search: ").strip().lower()
                matches = [a for a in apps if query in a["name"].lower()]
                if not matches:
                    print("No matches.")
                else:
                    for i, app in enumerate(matches[:15], start=1):
                        print(f"  {i}. {app['name']}")
                    raw2 = input("Choose: ").strip()
                    try:
                        idx2 = int(raw2)
                        if 1 <= idx2 <= min(15, len(matches)):
                            app = matches[idx2 - 1]
                            wm = app["wm_class"] or app["name"]
                            return f"raise-or-launch --wm-class '{wm}' -- {app['exec']}"
                    except ValueError:
                        pass
        except ValueError:
            pass

    print("Enter the WM class (or app name) and launch command.")
    wm_class = input("WM class: ").strip()
    launch = input("Launch command: ").strip()
    if wm_class and launch:
        return f"raise-or-launch --wm-class '{wm_class}' -- {launch}"
    if launch:
        return launch
    return ""


def _choose_terminal_slot() -> str:
    name = input("Terminal slot name (e.g. 'dev', 'logs', 'ssh-prod'): ").strip()
    if not name:
        name = "default"
    return f"kitty-slot {name}"


def _choose_media_command() -> str:
    print("  1. Play / Pause")
    print("  2. Next track")
    print("  3. Previous track")
    print("  4. Volume up")
    print("  5. Volume down")
    print("  6. Mute toggle")
    while True:
        choice = input("Media action [1-6]: ").strip()
        cmds = {
            "1": "playerctl play-pause",
            "2": "playerctl next",
            "3": "playerctl previous",
            "4": "pactl set-sink-volume @DEFAULT_SINK@ +5%",
            "5": "pactl set-sink-volume @DEFAULT_SINK@ -5%",
            "6": "pactl set-sink-mute @DEFAULT_SINK@ toggle",
        }
        if choice in cmds:
            return cmds[choice]
        print("Choose 1-6.")


def _choose_custom_command() -> str:
    print("Enter any shell command:")
    print("  Examples: notify-send 'Hello'  |  gnome-terminal  |  xdg-open https://example.com")
    return input("Command: ").strip()


def _choose_url_command() -> str:
    url = input("URL to open: ").strip()
    if url:
        return f"xdg-open '{url}'"
    return ""


def main() -> None:
    config = load_config()
    knob_ccs: set[int] = set(config.get("knob_ccs", []))
    button_ccs: set[int] = set(config.get("button_ccs", []))

    if config.get("port"):
        print(f"Current MIDI port: {config['port']}")
    else:
        config["port"] = choose_port_interactively()
        print(f"Current MIDI port: {config['port']}")

    while True:
        print(f"\nMIDI port in use: {config['port']}")
        print("\nCurrent bindings:")
        print_bindings(config)

        print("\nOptions:")
        print("  1. Learn new binding")
        print("  2. List bindings")
        print("  3. Edit command for existing binding")
        print("  4. Remove binding")
        print("  5. Edit cooldown for existing binding")
        print("  6. Change MIDI port")
        print("  7. Save and quit")
        print("  8. Quit without saving")

        choice = input("Select: ").strip()

        if choice == "1":
            trigger_id, kind = capture_one_trigger(config["port"], knob_ccs, button_ccs)
            label = describe_trigger(trigger_id, kind)
            existing = config["bindings"].get(trigger_id)
            existing_cmd = ""
            if existing and existing.get("command"):
                existing_cmd = existing["command"]
            cmd = choose_action_command(label, existing_command=existing_cmd)
            existing_cooldown = None
            if existing is not None:
                existing_cooldown = float(
                    config["cooldowns"].get(
                        trigger_id,
                        default_cooldown_for_kind(existing.get("kind", kind)),
                    )
                )
            cooldown = choose_cooldown_for_binding(kind, existing=existing_cooldown)
            config["bindings"][trigger_id] = {
                "kind": kind,
                "command": cmd,
            }
            config["cooldowns"][trigger_id] = cooldown
            print(f"Saved in memory: {label} -> {cmd}")
            print(f"Cooldown set to {cooldown:.2f}s")

        elif choice == "2":
            print("\nCurrent bindings:")
            print_bindings(config)

        elif choice == "3":
            trigger_id = select_binding_id(config, "Which binding number? ")
            if trigger_id is None:
                continue

            binding = config["bindings"][trigger_id]
            label = describe_trigger(trigger_id, binding["kind"])
            print(f"Current command for {label}: {binding['command'] or '(not set)'}")
            cmd = input("New command: ").strip()
            binding["command"] = cmd
            print(f"Updated {label}")

        elif choice == "4":
            trigger_ids = select_binding_ids(
                config,
                "Remove which binding number(s)? Use commas to remove multiple: ",
            )
            if trigger_ids is None:
                continue

            for trigger_id in trigger_ids:
                binding = config["bindings"].pop(trigger_id)
                config["cooldowns"].pop(trigger_id, None)
                print(f"Removed {describe_trigger(trigger_id, binding['kind'])}")

        elif choice == "5":
            trigger_id = select_binding_id(config, "Edit cooldown for which binding number? ")
            if trigger_id is None:
                continue

            binding = config["bindings"][trigger_id]
            label = describe_trigger(trigger_id, binding["kind"])
            current = float(
                config["cooldowns"].get(trigger_id, default_cooldown_for_kind(binding["kind"]))
            )
            print(f"Current cooldown for {label}: {current:.2f}s")
            raw = input("New cooldown in seconds (example 0.40): ").strip()
            try:
                config["cooldowns"][trigger_id] = float(raw)
                print(f"Updated {label} cooldown to {raw}")
            except ValueError:
                print("Invalid number.")

        elif choice == "6":
            config["port"] = choose_port_interactively()
            print(f"Now using MIDI port: {config['port']}")

        elif choice == "7":
            config["knob_ccs"] = sorted(knob_ccs)
            config["button_ccs"] = sorted(button_ccs)
            save_config(config)
            print(f"\nSaved config to: {CONFIG_PATH}")
            _, message = restart_execute_service()
            print(message)
            return

        elif choice == "8":
            print("Leaving without saving.")
            return

        else:
            print("Invalid option.")


if __name__ == "__main__":
    main()

