#!/bin/bash

# fix-update-blockers.sh — stop Omarchy's pending migration from aborting every
# `omarchy update` on this ext4 root, and keep the patch intact across package
# upgrades.
#
#   sudo bash fix-update-blockers.sh
#
# 1. Install the filesystem-gated snapper.sh (btrfs keeps Snapper+Limine;
#    anything else normalizes to "off" and exits 0) into
#    /usr/share/omarchy/install/config/snapper.sh — with a one-time backup.
#    This is what migration 1781984677 runs; on ext4 it currently dies on
#    "/sbin/chsnap not installed".
# 2. Add NoUpgrade for that file to /etc/pacman.conf [options] so the next
#    omarchy/omarchy-settings upgrade cannot ship back the unconditional
#    version. Remove the line once upstream PR #7403 merges.
#
# Idempotent: safe to re-run.

set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GATED="$SRC/etc/install-config-snapper.sh"
LIVE="/usr/share/omarchy/install/config/snapper.sh"
PACMAN_CONF="/etc/pacman.conf"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }

(( EUID == 0 )) || { echo "Run with sudo: sudo bash $0" >&2; exit 1; }
[[ -f $GATED ]] || { echo "Missing $GATED" >&2; exit 1; }

if [[ $(findmnt -no FSTYPE / 2>/dev/null || true) == "btrfs" ]]; then
  say "This root is btrfs; the chsnap blocker does not apply here. Nothing to do."
  exit 0
fi

# ---- 1. gated snapper.sh --------------------------------------------------

if [[ ! -f ${LIVE}.pre-bootguard ]]; then
  cp -a "$LIVE" "${LIVE}.pre-bootguard"
  say "Backed up original to ${LIVE}.pre-bootguard"
fi

say "Installing filesystem-gated snapper.sh -> $LIVE"
install -m 0644 "$GATED" "$LIVE"

# Confirm behavior: must exit 0 on this filesystem.
if OMARCHY_PATH=/usr/share/omarchy bash -euo pipefail "$LIVE" >/dev/null 2>&1; then
  say "gated snapper.sh exits 0 on this $(findmnt -no FSTYPE /) root"
else
  warn "patched snapper.sh still fails here; NOT removing blocker"
  exit 1
fi

# ---- 2. NoUpgrade guard ---------------------------------------------------

NOLINE="NoUpgrade = usr/share/omarchy/install/config/snapper.sh"
if grep -qxF "$NOLINE" "$PACMAN_CONF"; then
  say "pacman.conf already has the NoUpgrade entry"
else
  if [[ ! -f ${PACMAN_CONF}.pre-bootguard ]]; then
    cp -a "$PACMAN_CONF" "${PACMAN_CONF}.pre-bootguard"
    say "Backed up pacman.conf to ${PACMAN_CONF}.pre-bootguard"
  fi
  # Append inside [options]: after the last existing option line before the
  # next repo section is fragile; instead insert right after '[options]'.
  awk -v line="$NOLINE" '
    !done && /^\[options\]/ { print; print ""; print "# Boot-guard: keep the FS-gated snapper.sh across omarchy upgrades"; print line; done=1; next }
    { print }
  ' "${PACMAN_CONF}.pre-bootguard" > "${PACMAN_CONF}.tmp"
  install -m 0644 "${PACMAN_CONF}.tmp" "$PACMAN_CONF"
  rm -f "${PACMAN_CONF}.tmp"
  say "Added NoUpgrade entry to pacman.conf"
fi

grep -qxF "$NOLINE" "$PACMAN_CONF" || { warn "NoUpgrade insertion failed"; exit 1; }

# ---- summary --------------------------------------------------------------

say "done."
echo "Next steps:"
echo "  1. omarchy migrate          # 1781984677 now passes; other pending migrations run too"
echo "  2. omarchy update           # should complete green through the wrapper stages"
echo ""
echo "Remove the NoUpgrade line from $PACMAN_CONF once basecamp/omarchy PR #7403 lands."