#!/bin/bash
# Hunt for a real fan tach/PWM byte in EC RAM.
#
# The CFSP stub reports fan speed 0 because the EC never implements the
# field DPTF expects — but the EC does drive the fan autonomously, so a
# genuine tach/PWM/level byte may exist somewhere in its 256-byte RAM,
# just never surfaced as a named ACPI field. This samples all 256 bytes
# once per second through three phases (idle → 4-core load → cooldown),
# alongside the package temperature, so offline analysis can find bytes
# that track the fan. Listen to the fan while it runs and note roughly
# when it audibly speeds up/down.
#
# Read-only: ec_sys is loaded without write support (its default).
# Usage: sudo ./4-ec-fan-hunt.sh
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }

modprobe ec_sys
io=/sys/kernel/debug/ec/ec0/io
[ -r "$io" ] || { echo "$io not readable — ec_sys/debugfs problem" >&2; exit 1; }

pkg=""
for z in /sys/class/thermal/thermal_zone*; do
    [ "$(cat "$z/type" 2>/dev/null)" = x86_pkg_temp ] && pkg="$z/temp" && break
done

out=ec-ram-samples.csv
echo "epoch,phase,pkg_mC,ec_hex" > "$out"

sample() {
    printf '%s,%s,%s,%s\n' "$(date +%s)" "$1" \
        "$(cat "$pkg" 2>/dev/null || echo -1)" \
        "$(od -An -tx1 -v "$io" | tr -d ' \n')" >> "$out"
}
phase() {
    echo "== phase: $1 (${2}s) — listen to the fan"
    local i
    for ((i = 0; i < $2; i++)); do sample "$1"; sleep 1; done
}

phase idle 60
echo "starting 4-core load (fan should spin up)..."
for i in 1 2 3 4; do sha256sum /dev/zero & done
phase load 90
kill %1 %2 %3 %4 2>/dev/null || true
wait 2>/dev/null || true
phase cooldown 45

chown --reference=. "$out" 2>/dev/null || true
echo "done -> acpi-fix/$out (~195 samples). Hand it over for correlation analysis."
