# ACPI fix: DPTF reads an EC fan-speed field that doesn't exist

The DPTF fan object `TFN1._FST` (SSDT `DptfTb`) and the `OSD1`/`OSD2` methods
(another SSDT) read `\_SB.PC00.LPCB.H_EC.CFSP` — an EC fan-speed field that
**no table ever defines**: the vendor shipped Intel's reference DPTF thermal
stack wired to an EC interface their EC firmware never implements.
Consequences: permanent `AE_NOT_FOUND` kernel log spam, dead DPTF fan
telemetry, and fan sysfs/hwmon reads that return EIO or hang for minutes
(breaks `sensors`, btop, anything walking hwmon). Background:
the review in the repository root.

Note on the misleading kernel message: it prints
`Could not resolve symbol [\_SB.PC00.LPCB.HEC.CFSP]` — but no `HEC` nameseg
exists in any loaded table (byte-verified across the full static + dynamic
dump; the six dynamic tables are plain CPU PPM tables). The "HEC" spelling is
an ACPICA error-printer rendering artifact for `H_EC`. It cost this
investigation two wrong theories (a half-done `HEC`→`H_EC` rename; mixed
reference-code generations) before the dump settled it.

The fix is an SSDT defining `CFSP` under `H_EC`. **v4 (2026-08-12) maps it
onto the real fan tachometer**: an empirical EC RAM correlation run
(`4-ec-fan-hunt.sh` — 195 samples across idle/load/cooldown phases, strictly
read-only) located the tach as a little-endian 16-bit word at **EC RAM
0x8D/0x8E** (~430–490 idle → ~1100 under 4-core load, smooth decay in
cooldown), chasing the EC's soft-ramp fan *target* at **0xA1/0xA2** (steps
of 10). Other EC RAM finds: CPU temp copies at 0x70/0x71, slower
board/skin sensors at 0x62/0x72/0x73. So the fix now restores: no log spam,
no multi-minute hangs, working `sensors`/hwmon walks, **and genuine fan
telemetry** (unit unknown — plausibly RPM or a scaled tach count; monotone
with actual speed). Versions ≤3 reported a constant 0 instead.
**v4 reboot-verified 2026-08-12**: table upgraded at boot (`HECSTUB
00000004`), zero CFSP errors, `sensors` reports the live tach (449 at idle,
tracking the audible fan).

Preconditions (verified on this install 2026-08-11): kernel has
`CONFIG_ACPI_TABLE_UPGRADE=y`, `acpi_configfs` module available, Secure Boot
uses user-enrolled keys, lockdown `none`. Stub compiles clean with iasl
20251212; `2-build-fix.sh` re-verifies the diagnosis against a fresh dump and
refuses to build if it ever finds a real `CFSP` definition.

The raw ACPI table dumps from the reviewed unit (BIOS
`GLF-BI-8-S8_AN_G04R100-F70A-015-A`, static + dynamic) are in `tables/` for
reference and for diffing against other units or BIOS revisions; the EC RAM
samples behind the fan-tach discovery are in `ec-ram-samples.csv`.

## Steps

```
sudo ./1-dump-tables.sh     # dump DSDT + SSDTs incl. dynamic (root)
./2-build-fix.sh            # disassemble, verify diagnosis, compile stub + initrd image
sudo ./3-install.sh live    # load via configfs NOW, no reboot — test it
sudo ./3-install.sh uki     # persistent on THIS machine (mkinitcpio-built UKIs,
                            #   auto-discovered by systemd-boot, sbctl-signed):
                            #   installs an acpi_override mkinitcpio hook that
                            #   embeds /etc/acpi-override/*.aml into the early
                            #   cpio inside every UKI; survives kernel updates
sudo ./3-install.sh initrd  # persistent for setups with explicit bootloader
                            #   entries: image to ESP + prints the initrd line
sudo ./3-install.sh revert  # undo everything (incl. hook + HOOKS entry)
```


Version upgrades (e.g. v3 stub → v4 real-field) cannot be live-tested via
configfs: the boot-time table already owns the `CFSP` name and a second
definition collides. Rerun `uki` (overwrites the .aml, rebuilds + re-signs
the UKIs) and reboot.

## Verify (after `live`, and again after reboot with `uki`/`initrd`)

```
journalctl -kb | grep -i 'CFSP\|_FST'         # expect NOTHING
timeout 10 sensors                            # must not hang
grep . /sys/class/thermal/cooling_device*/cur_state 2>/dev/null   # no EIO/hang
dmesg | grep HECSTUB                          # shows table loaded from initrd
```

Note: `grep -c AE_NOT_FOUND` will still show 4 — those are two *unrelated,
pre-existing* load-time errors (×2 lines each): Intel's verbatim `xh_adl_N`
USB SSDT scopes into `\_SB.PC00.TXHC.RHUB.SS01/SS02`, the Type-C/USB4
subsystem that N-series silicon doesn't have. Harmless (scope skipped);
deliberately not stubbed. Status: **persistent install reboot-verified
2026-08-12** — table upgraded at 0.012 s, zero CFSP/`_FST` errors, fan
sysfs instant.
