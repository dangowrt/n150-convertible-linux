#!/bin/bash
# Disassemble the dumped tables, verify the settled diagnosis, and build the
# stub SSDT. No root needed.
#
# Diagnosis (settled 2026-08-11 from full static+dynamic dump):
#   The DPTF code references an EC fan-speed field \_SB.PC00.LPCB.H_EC.CFSP
#   (SSDT1 "DptfTb" TFN1._FST; SSDT7 OSD1/OSD2) that no table ever defines —
#   the EC firmware simply never implements it. The kernel's
#   "Could not resolve symbol [\_SB.PC00.LPCB.HEC.CFSP]" is an ACPICA
#   error-printer rendering artifact: no HEC_ nameseg exists in any loaded
#   table (byte-verified); the dynamic tables are plain CPU PPM tables.
#   Fix: define CFSP = 0 under H_EC so _FST completes (fan speed reads 0;
#   the EC drives the fan autonomously — the bug only ever cost
#   observability). A HEC stub device is included as harmless insurance.
#
# Usage: ./2-build-fix.sh
set -euo pipefail
cd "$(dirname "$0")"
[ -f tables/DSDT.bin ] || { echo "tables/ missing — run: sudo ./1-dump-tables.sh" >&2; exit 1; }
command -v iasl >/dev/null || { echo "iasl not found — pacman -S acpica" >&2; exit 1; }

rm -rf work out
mkdir -p work out
cp tables/*.bin work/
cd work

echo "== Disassembling =="
for f in *.bin; do
    refs=$(ls *.bin | grep -v "^$f\$" | paste -sd,)
    iasl -e "$refs" -d "$f" >/dev/null 2>&1 || iasl -d "$f" >/dev/null 2>&1 || {
        echo "  WARN: could not disassemble $f"; continue; }
done
ls ./*.dsl >/dev/null 2>&1 || { echo "disassembly produced no .dsl files — check iasl output" >&2; exit 1; }

echo "== Findings =="
echo "CFSP reference sites (call sites + External declarations):"
grep -n 'CFSP' ./*.dsl | grep -vE '^\S+: *//' | sed 's/^/  /' || true
# A real definition would be Name (CFSP..., Method (CFSP..., or an EC
# field-list entry like "CFSP,   8,". If one exists, the diagnosis is wrong
# and the stub would collide — stop and re-investigate instead of building.
defs=$(grep -lE '(Name|Method) \(CFSP|^\s*CFSP,\s*[0-9]' ./*.dsl 2>/dev/null || true)
if [ -n "$defs" ]; then
    echo "UNEXPECTED: CFSP appears to be DEFINED in: $defs" >&2
    echo "That contradicts the settled diagnosis — do not install the stub;" >&2
    echo "re-examine the definition site(s) above first." >&2
    exit 1
fi
echo "CFSP defined nowhere (as expected) -> building stub"
if ls dyn-*.dsl >/dev/null 2>&1; then
    echo "(dynamic tables present: CPU PPM only — Cpu0Ist/Psd/Hwp, Ap* — no DPTF content)"
fi

cat > ../out/ssdt-hecstub.dsl <<'EOF'
/*
 * Fix for the firmware's dangling EC fan-speed reference. The DPTF code
 * (DptfTb SSDT: TFN1._FST; also OSD1/OSD2 in another SSDT) reads
 * \_SB.PC00.LPCB.H_EC.CFSP, a field the EC ASL never defines anywhere.
 * (The kernel error's "HEC.CFSP" spelling is an ACPICA error-printer
 * artifact for H_EC.CFSP — no HEC nameseg exists in any loaded table.)
 *
 * v4: CFSP is now a REAL field. Empirical EC RAM correlation (see
 * 4-ec-fan-hunt.sh, run 2026-08-12) located the fan tachometer as a
 * little-endian 16-bit word at EC RAM 0x8D/0x8E: ~430-490 idle, ramping
 * to ~1100 under 4-core load, decaying smoothly through cooldown, chasing
 * the EC's soft-ramp fan target at 0xA1/0xA2 (steps of 10). Unit unknown
 * (plausibly RPM or a scaled tach count) — monotone with actual speed.
 * Mapping CFSP onto it restores genuine fan telemetry to _FST, sensors
 * and hwmon, in addition to killing the error spam and read hangs.
 * ECF2 is the EC's EmbeddedControl OperationRegion from the DSDT (offset
 * 0, length 0xFF, declared at \_SB.PC00.LPCB.H_EC).
 */
DefinitionBlock ("", "SSDT", 2, "HECFIX", "HECSTUB", 0x00000004)
{
    External (\_SB.PC00.LPCB.H_EC, DeviceObj)
    External (\_SB.PC00.LPCB.H_EC.ECF2, OpRegionObj)
    Scope (\_SB.PC00.LPCB.H_EC)
    {
        Field (ECF2, ByteAcc, Lock, Preserve)
        {
            Offset (0x8D),
            CFSP, 16
        }
    }
}
EOF
( cd ../out && iasl ssdt-hecstub.dsl )

echo "== Packaging initrd override =="
cd ../out
rm -rf cpio && mkdir -p cpio/kernel/firmware/acpi
cp ./*.aml cpio/kernel/firmware/acpi/
( cd cpio && find kernel -type f -o -type d | cpio -H newc -o --quiet ) > acpi-override.img
echo
echo "Built: $(ls ./*.aml) + acpi-override.img"
echo "Next: sudo ./3-install.sh live    (test now via configfs, no reboot)"
echo "      sudo ./3-install.sh initrd  (persistent; needs a reboot)"
