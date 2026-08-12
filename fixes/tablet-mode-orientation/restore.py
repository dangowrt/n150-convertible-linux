#!/usr/bin/env python3
"""Enforce the correct laptop-mode display orientation for mutter.

Background: this convertible has an EDID-less DSI panel that is natively
portrait (1280x800 exposed as landscape via the kernel's
`panel_orientation=right_side_up`). In *laptop* mode the screen must be
landscape (mutter transform 0) at integer scale 1.0 (fractional scaling melts
this panel -- see the project notes). In *tablet* mode mutter auto-rotates from
the accelerometer and we leave it alone.

mutter does not reliably bring the user session up in the correct orientation
(it can get stuck portrait, transform 1), and once stuck nothing self-corrects.

An earlier version of this helper "snapshotted" whatever orientation was live
and replayed it. That was a feedback trap: if the session was ever portrait, the
snapshot captured portrait and the service then re-applied portrait forever.
Instead we now enforce a FIXED known-good laptop config (transform 0, scale 1.0)
and only touch mutter when the current state actually differs (no flicker).

It also drives GNOME's on-screen keyboard (OSK) per mode, so a logged-in user
session behaves like the GDM greeter: OSK available in tablet mode, suppressed in
laptop mode (so it does not pop up over the hardware keyboard). GNOME's built-in
tablet-mode auto-detection (seat.touch_mode + last-input-was-touch) is unreliable
in a user session because the last input is usually the keyboard/touchpad, so we
toggle the a11y `screen-keyboard-enabled` gsetting explicitly instead.

Subcommands:
    laptop     Enforce landscape (transform 0 / scale 1.0) on every gnome-shell
               and turn the OSK off for user sessions. Idempotent.
    tablet     Turn the OSK on for user sessions (orientation left to mutter's
               accelerometer auto-rotation). Idempotent.
    enforce    Just the orientation enforcement (no OSK change).

mutter is reached over its per-process D-Bus session bus, which differs between
the GDM greeter (a temporary dbus-run-session bus) and the user session, so we
discover the bus from each gnome-shell's /proc/<pid>/environ.
"""

import glob
import json
import os
import pwd
import subprocess
import sys

DEST = "org.gnome.Mutter.DisplayConfig"
PATH = "/org/gnome/Mutter/DisplayConfig"
IFACE = "org.gnome.Mutter.DisplayConfig"

LAPTOP_TRANSFORM = 0      # landscape (panel_orientation already accounts for 90deg)
LAPTOP_SCALE = 1.0        # integer scale; fractional scaling breaks this DSI panel

OSK_SCHEMA = "org.gnome.desktop.a11y.applications"
OSK_KEY = "screen-keyboard-enabled"


def gnome_shells():
    """Yield (user, bus_address) for every running gnome-shell process."""
    seen = set()
    for comm in glob.glob("/proc/[0-9]*/comm"):
        try:
            if open(comm).read().strip() != "gnome-shell":
                continue
        except OSError:
            continue
        pid = comm.split("/")[2]
        try:
            raw = open("/proc/%s/environ" % pid, "rb").read()
            uid = os.stat("/proc/%s" % pid).st_uid
        except OSError:
            continue
        bus = None
        for entry in raw.split(b"\0"):
            if entry.startswith(b"DBUS_SESSION_BUS_ADDRESS="):
                bus = entry.split(b"=", 1)[1].decode()
                break
        if not bus:
            continue
        try:
            user = pwd.getpwuid(uid).pw_name
        except KeyError:
            continue
        key = (user, bus)
        if key in seen:
            continue
        seen.add(key)
        yield user, bus


def busctl(user, bus, *args):
    return subprocess.run(
        ["sudo", "-u", user, "busctl", "--address=" + bus, "--json=short", *args],
        capture_output=True, text=True,
    )


def get_state(user, bus):
    r = busctl(user, bus, "call", DEST, PATH, IFACE, "GetCurrentState")
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)["data"]
    except (ValueError, KeyError):
        return None


def landscape_payload(state):
    """Build ApplyMonitorsConfig args for landscape transform 0 / scale 1.0.

    Returns (serial, logical_monitors) using each builtin connector's current
    mode, or None if no connector has a current mode (display off).
    """
    serial, monitors, _logicals = state[0], state[1], state[2]
    current_mode = {}
    for mon in monitors:
        connector = mon[0][0]
        for mode in mon[1]:
            flags = mode[6]
            cur = flags.get("is-current")
            if cur and cur.get("data"):
                current_mode[connector] = mode[0]
    # Single builtin panel on this device: take the first connector with a mode.
    for connector, mode_id in current_mode.items():
        lm = [[0, 0, LAPTOP_SCALE, LAPTOP_TRANSFORM, True, [(connector, mode_id)]]]
        return serial, lm
    return None


def already_landscape(state):
    logicals = state[2]
    if not logicals:
        return False
    scale, transform = logicals[0][2], logicals[0][3]
    return transform == LAPTOP_TRANSFORM and abs(scale - LAPTOP_SCALE) < 0.01


def apply_payload(user, bus, serial, lm):
    """Call ApplyMonitorsConfig (method 1 = temporary -> no "Keep changes?" dialog)."""
    sig = "uua(iiduba(ssa{sv}))a{sv}"
    args = [str(serial), "1", str(len(lm))]
    for x, y, scale, transform, primary, clist in lm:
        args += [
            str(x), str(y), repr(float(scale)),
            str(transform), "true" if primary else "false",
            str(len(clist)),
        ]
        for connector, mode_id in clist:
            args += [connector, mode_id, "0"]  # trailing 0 = empty a{sv}
    args += ["0"]  # empty top-level properties a{sv}
    r = busctl(user, bus, "call", DEST, PATH, IFACE, "ApplyMonitorsConfig", sig, *args)
    return r.returncode == 0, r.stderr.strip()


def cmd_enforce(_state_dir=None):
    for user, bus in gnome_shells():
        state = get_state(user, bus)
        if not state:
            continue
        if already_landscape(state):
            continue
        payload = landscape_payload(state)
        if not payload:
            continue
        serial, lm = payload
        ok, err = apply_payload(user, bus, serial, lm)
        if not ok:
            sys.stderr.write("enforce failed for %s: %s\n" % (user, err))


def set_osk(enabled):
    """Toggle GNOME's on-screen keyboard for real user sessions (not the greeter).

    The GDM greeter manages its own OSK; we only drive logged-in user sessions.
    Idempotent: read the current value first and skip if it already matches, to
    avoid pointless dconf writes/change-signals on every poll.
    """
    want = "true" if enabled else "false"
    for user, bus in gnome_shells():
        if user == "gdm":
            continue
        base = ["sudo", "-u", user, "env", "DBUS_SESSION_BUS_ADDRESS=" + bus, "gsettings"]
        cur = subprocess.run(base + ["get", OSK_SCHEMA, OSK_KEY],
                             capture_output=True, text=True)
        if cur.returncode == 0 and cur.stdout.strip() == want:
            continue
        subprocess.run(base + ["set", OSK_SCHEMA, OSK_KEY, want],
                       capture_output=True, text=True)


def cmd_laptop(_=None):
    cmd_enforce()
    set_osk(False)


def cmd_tablet(_=None):
    set_osk(True)


def main():
    actions = {"laptop": cmd_laptop, "tablet": cmd_tablet, "enforce": cmd_enforce}
    if len(sys.argv) < 2 or sys.argv[1] not in actions:
        sys.stderr.write("usage: restore.py {laptop|tablet|enforce}\n")
        return 2
    actions[sys.argv[1]]()
    return 0


if __name__ == "__main__":
    sys.exit(main())
