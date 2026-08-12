#!/bin/bash
# Install/test the ACPI fix built by 2-build-fix.sh. Root required.
#
#   sudo ./3-install.sh live    - load the stub shim via configfs right now
#                                 (no reboot; gone at next boot; only valid
#                                 for the stub — a patched table cannot
#                                 replace its original at runtime)
#   sudo ./3-install.sh uki     - persistent for mkinitcpio-built UKIs (this
#                                 machine): installs the acpi_override
#                                 mkinitcpio hook, copies the tables to
#                                 /etc/acpi-override/, adds the hook to
#                                 HOOKS, rebuilds all presets (sbctl
#                                 post-hook re-signs automatically)
#   sudo ./3-install.sh initrd  - persistent for explicit bootloader entries:
#                                 copy acpi-override.img to the ESP and print
#                                 the exact bootloader change to make
#   sudo ./3-install.sh revert  - unload the live shim / remove hook + image
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0 ${1:-}" >&2; exit 1; }
cmd="${1:-}"

case "$cmd" in
live)
    [ -f out/ssdt-hecstub.aml ] || { echo "no stub built (build chose the patched-SSDT route, which needs 'initrd')" >&2; exit 1; }
    modprobe acpi_configfs
    mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
    mkdir -p /sys/kernel/config/acpi/table/hecfix
    cat out/ssdt-hecstub.aml > /sys/kernel/config/acpi/table/hecfix/aml
    echo "Loaded. Verifying:"
    dmesg | tail -5
    echo "-- fan read test (used to hang for minutes / EIO):"
    for cd in /sys/class/thermal/cooling_device*; do
        if grep -q '^Fan$' "$cd/type" 2>/dev/null; then
            timeout 10 cat "$cd/cur_state" >/dev/null 2>&1 \
                && echo "  $cd: OK" || echo "  $cd: still hangs/errors"
        fi
    done
    echo "-- watch for new AE_NOT_FOUND spam: journalctl -kf | grep -i acpi"
    ;;
uki)
    ls out/*.aml >/dev/null 2>&1 || { echo "run ./2-build-fix.sh first" >&2; exit 1; }
    install -Dm644 mkinitcpio-install-hook /etc/initcpio/install/acpi_override
    install -dm755 /etc/acpi-override
    install -m644 out/*.aml /etc/acpi-override/
    echo "Installed: /etc/initcpio/install/acpi_override + /etc/acpi-override/$(ls out/*.aml | xargs -n1 basename | paste -sd' ')"
    if ! grep -qE '^HOOKS=.*\bacpi_override\b' /etc/mkinitcpio.conf; then
        cp -n /etc/mkinitcpio.conf /etc/mkinitcpio.conf.bak-acpi-override
        sed -i '/^HOOKS=/s/\bmicrocode\b/microcode acpi_override/' /etc/mkinitcpio.conf
        grep -qE '^HOOKS=.*\bacpi_override\b' /etc/mkinitcpio.conf || \
            sed -i '/^HOOKS=/s/)$/ acpi_override)/' /etc/mkinitcpio.conf
        grep -qE '^HOOKS=.*\bacpi_override\b' /etc/mkinitcpio.conf || {
            echo "could not add acpi_override to HOOKS in /etc/mkinitcpio.conf — add it manually" >&2
            exit 1; }
    fi
    grep '^HOOKS=' /etc/mkinitcpio.conf
    echo "Rebuilding all presets (UKIs; sbctl post-hook signs them)..."
    mkinitcpio -P
    echo
    echo "Done. Verify after the next reboot:"
    echo "    dmesg | grep -i 'ACPI:.*table found in initrd\\|HECSTUB'"
    echo "    journalctl -kb | grep -c AE_NOT_FOUND   # expect 0"
    ;;
initrd)
    [ -f out/acpi-override.img ] || { echo "run ./2-build-fix.sh first" >&2; exit 1; }
    esp=$(bootctl -p 2>/dev/null || true)
    if [ -n "$esp" ] && [ -d "$esp/loader/entries" ]; then
        cp out/acpi-override.img "$esp/acpi-override.img"
        echo "Copied to $esp/acpi-override.img"
        echo "systemd-boot detected. Add this line to each entry in"
        echo "$esp/loader/entries/*.conf, BEFORE the existing initrd line(s):"
        echo
        echo "    initrd  /acpi-override.img"
        echo
        ls "$esp/loader/entries/"
    elif [ -d /boot/grub ]; then
        cp out/acpi-override.img /boot/acpi-override.img
        echo "GRUB detected. In /etc/default/grub set (then grub-mkconfig -o /boot/grub/grub.cfg):"
        echo '    GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi-override.img"'
    else
        echo "Could not identify bootloader (UKI image?). The override must be"
        echo "prepended as an extra initrd before the main initramfs. For a UKI,"
        echo "add it to the .initrd section order in the ukify/mkinitcpio preset."
        cp out/acpi-override.img /boot/acpi-override.img 2>/dev/null \
            && echo "Copied to /boot/acpi-override.img anyway."
    fi
    echo
    echo "Kernel has CONFIG_ACPI_TABLE_UPGRADE=y (verified); lockdown is off,"
    echo "so the override takes effect on the next reboot. Verify after boot:"
    echo "    dmesg | grep -i 'ACPI.*override\\|hecfix\\|HECSTUB'"
    echo "    journalctl -kb | grep -c 'AE_NOT_FOUND'   # should be 0"
    ;;
revert)
    rmdir /sys/kernel/config/acpi/table/hecfix 2>/dev/null && echo "live shim unloaded" || true
    rm -vf /etc/initcpio/install/acpi_override
    rm -rvf /etc/acpi-override
    if grep -qE '^HOOKS=.*\bacpi_override\b' /etc/mkinitcpio.conf 2>/dev/null; then
        sed -i '/^HOOKS=/s/ \?\bacpi_override\b//' /etc/mkinitcpio.conf
        echo "removed acpi_override from HOOKS — rebuilding presets..."
        mkinitcpio -P
    fi
    for p in "$(bootctl -p 2>/dev/null)/acpi-override.img" /boot/acpi-override.img; do
        [ -f "$p" ] && rm -v "$p"
    done
    echo "If you added an 'initrd /acpi-override.img' line to a bootloader entry, remove it."
    ;;
*)
    grep '^#   sudo' "$0" | sed 's/^#   //'
    exit 1
    ;;
esac
