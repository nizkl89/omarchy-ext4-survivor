#!/bin/bash

# fix-boot-bridge.sh — restore Arch to GRUB's menu on the UKI-only layout.
#
#   sudo bash fix-boot-bridge.sh
#
# The Limine stack migrated this machine to Unified Kernel Images and retired
# /etc/mkinitcpio.d presets, so `grub-mkconfig`'s 10_linux scans an empty
# /boot and generates zero Linux entries — next reboot would skip straight to
# Windows. This installs /etc/grub.d/12_omarchy_uki (chainloads
# ESP:/EFI/Linux/omarchy_linux*.efi) and regenerates grub.cfg, then verifies.
#
# Idempotent; backs up prior state once.

set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SRC/etc/grub.d-12-omarchy-uki"
DROPIN="/etc/grub.d/12_omarchy_uki"
GRUB_CFG="/boot/grub/grub.cfg"
DEFAULT_GRUB="/etc/default/grub"
ICON_SRC="$SRC/etc/grub-theme-icons"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }

(( EUID == 0 )) || { echo "Run with sudo: sudo bash $0" >&2; exit 1; }
[[ -f $TEMPLATE ]] || { echo "Missing $TEMPLATE" >&2; exit 1; }

if [[ $(findmnt -no FSTYPE / 2>/dev/null) == "btrfs" ]]; then
  say "btrfs root: the UKI bridge is unnecessary here. Nothing to do."
  exit 0
fi

say "Installing GRUB drop-in -> $DROPIN"

# Back up the previous drop-in OUTSIDE /etc/grub.d/: grub-mkconfig executes
# every file in that directory, so an executable backup would double-emit the
# entries (four duplicate menu items). Copies live in the guard store.
BACKUP_DIR="/var/lib/omarchy-boot-guard/dropin-backups"
mkdir -p "$BACKUP_DIR" 2>/dev/null || true
[[ -f $BACKUP_DIR/$(basename "$DROPIN").pre-bootguard ]] || \
  cp -a "$DROPIN" "$BACKUP_DIR/$(basename "$DROPIN").pre-bootguard" 2>/dev/null || true
install -m 0755 "$TEMPLATE" "$DROPIN"

# grub-mkconfig executes EVERY file in /etc/grub.d/*, backups included. Remove
# any executable leftovers from earlier runs (or package reinstalls) so entries
# are never emitted twice.
for stale in /etc/grub.d/*.pre-bootguard /etc/grub.d/47_omarchy_uki; do
  [[ -e $stale || -L $stale ]] || continue
  say "Removing stale drop-in/backup: $stale"
  cp -a "$stale" "$BACKUP_DIR/stale-$(basename "$stale")" 2>/dev/null || true
  rm -f "$stale"
done


# Default entry: point at Omarchy by menu id (robust against reordering) so a
# bare Enter boots Omarchy instead of whichever OS entry happens to be first.
if grep -q "^GRUB_DEFAULT=0$" "$DEFAULT_GRUB" 2>/dev/null; then
  say "Setting GRUB default to the Omarchy UKI entry"
  sed -i 's|^GRUB_DEFAULT=0$|GRUB_DEFAULT="omarchy_uki-omarchy_linux"|' "$DEFAULT_GRUB"
fi

say "Regenerating grub.cfg (now with Omarchy entries)"
grub-mkconfig -o "$GRUB_CFG" 2>&1 | tail -5

echo ""
if grep -q "omarchy_uki-" "$GRUB_CFG"; then
  say "verified: grub.cfg now chainloads $(grep -c 'chainloader /EFI/Linux/omarchy_linux' "$GRUB_CFG") Omarchy UKI(s)"
else
  warn "verification failed: no omarchy_uki entries in $GRUB_CFG"
  echo "Check manually:"
  echo "  ls -la $(findmnt -rno SOURCE /boot/efi | xargs -I{} sh -c 'true'; findmnt -no TARGET /boot/efi)/EFI/Linux/"
  exit 1
fi

say "done."
echo "Next reboot boots through GRUB -> 'Omarchy Linux (UKI)'. Windows entry untouched."
echo "Re-run 'omarchy update' to confirm the full wrapper flow is green end-to-end."