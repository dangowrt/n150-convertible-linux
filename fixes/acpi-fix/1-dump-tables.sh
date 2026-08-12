#!/bin/bash
# Dump DSDT + all SSDTs (root needed: /sys/firmware/acpi/tables is 0400).
# Usage: sudo ./1-dump-tables.sh
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }

mkdir -p tables
for t in /sys/firmware/acpi/tables/DSDT /sys/firmware/acpi/tables/SSDT*; do
    [ -f "$t" ] && cp "$t" "tables/$(basename "$t").bin"
done
# Dynamically loaded tables (e.g. DPTF GDDV data-vault tables loaded by the
# INT3400 driver) live in a subdirectory and are where this firmware's
# dangling HEC.CFSP reference actually is.
for t in /sys/firmware/acpi/tables/dynamic/*; do
    [ -f "$t" ] && cp "$t" "tables/dyn-$(basename "$t").bin"
done
# hand the files back to the repo owner
chown -R --reference=. tables
chmod 644 tables/*.bin
echo "Dumped:"
ls -la tables/
echo
echo "Next (no root needed): ./2-build-fix.sh"
