#!/bin/bash

# Native Omarchy post-update hook: boot-guard check + pre-reboot reminder.
#
# Runs after a successful `omarchy update` even when it bypasses the
# /usr/local/bin wrapper. If boot verification fails or upstream changed the
# boot configuration, the user is reminded BEFORE the updater's reboot prompt:
#   - terminal: prominent warning + what to do
#   - desktop: notification (omarchy-notification-send, notify-send fallback)
# Non-blocking: always exits 0 so the update flow continues.

# Self-locating: resolve through the symlink so this hook works no matter
# where the repo lives.
SELF_DIR="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
GUARD="$SELF_DIR/../bin/grub-guard.sh"
REPO_DIR="$(cd -- "$SELF_DIR/../.." && pwd)"
SKILL_HINT="AI assist: open your assistant in $REPO_DIR (skill: omarchy-boot-rescue)"

notify() {  # best-effort desktop notification
  omarchy-notification-send -i dialog-warning "Boot-guard" "$1" 2>/dev/null ||
    notify-send -u critical -a "grub-guard" "Boot-guard" "$1" 2>/dev/null ||
    true
}

[[ -x $GUARD ]] || exit 0

out="$(bash "$GUARD" --check 2>&1)"
rc=$?

if (( rc == 0 )); then
  # Informational: surface upstream boot-config changes the guard healed or
  # adopted this run (drift note comes through the guard log).
  if grep -q "healed cmdline source" "$HOME/.local/state/omarchy/grub-guard.log" 2>/dev/null && \
     [[ $(find "$HOME/.local/state/omarchy/grub-guard.log" -newermt '-10 minutes' 2>/dev/null) ]]; then
    echo "  \033[33m[boot-guard] upstream boot settings changed; working params were auto-restored.\033[0m"
    echo "  \033[33mReview with AI before your next reboot: $SKILL_HINT\033[0m"
    notify "Boot settings changed by update — auto-restored. Review with AI (skill: omarchy-boot-rescue)."
  fi
  exit 0
fi

# Verification failed — this is the pre-reboot blocker moment.
echo ""
echo -e "\033[1;41m\033[97m BOOT-GUARD WARNING \033[0m"
echo -e "\033[1;33m Boot images may not unlock LUKS after this update. DO NOT REBOOT yet.\033[0m"
echo -e "\033[0m$out\033[0m"
echo -e "\033[1;36m Auto-fix:   sudo bash $GUARD --repair\033[0m"
echo -e "\033[1;36m Diff:       sudo bash $GUARD --explain-diff\033[0m"
echo -e "\033[1;36m $SKILL_HINT\033[0m"
echo ""
notify "Boot-guard: update may have broken boot. DO NOT reboot yet. Run: sudo $GUARD --repair"
exit 0