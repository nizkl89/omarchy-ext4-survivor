#!/bin/bash

# setup.sh — one-time (idempotent) installation of the Omarchy GRUB-safe
# boot-guard. Run with sudo:
#
#   sudo bash setup.sh
#
# What it wires up:
#   1. /usr/local/bin/omarchy  -> wrapper (stage-by-stage GRUB-safe update)
#   2. ~/.config/omarchy/hooks/post-update.d/00-grub-guard.sh -> native check hook
#   3. Seed the system golden boot store in /var/lib/omarchy-boot-guard/
#   4. Verify the pipeline with a --check run under root
#
# The only boot-adjacent file it may modify is /etc/default/grub, and only to
# remove a legacy duplicate `cryptdevice` from GRUB_CMDLINE_LINUX_DEFAULT (a
# backup is made first; every other parameter is preserved). Nothing else in
# your live boot configuration is touched.

set -euo pipefail

# ---- locations -----------------------------------------------------------

SRC="${SRC:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
WRAPPER_SRC="$SRC/bin/omarchy"
HOOK_SRC="$SRC/hooks/post-update.d/00-grub-guard.sh"
GUARD="$SRC/bin/grub-guard.sh"

# When run under sudo, $HOME is /root. The hook belongs to the real user who
# runs `omarchy update`, so resolve their account and home explicitly.
TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n $TARGET_HOME ]] || TARGET_HOME="/home/$TARGET_USER"

WRAPPER_LINK="/usr/local/bin/omarchy"
HOOK_LINK="$TARGET_HOME/.config/omarchy/hooks/post-update.d/00-grub-guard.sh"

GUARD_SYS_DIR="/var/lib/omarchy-boot-guard"

DEFAULT_GRUB_LIVE="/etc/default/grub"

# ---- helpers -------------------------------------------------------------

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }

require_root() {
  if (( EUID != 0 )); then
    echo "This script writes to /usr/local/bin and /var/lib; run it with sudo." >&2
    exit 1
  fi
}

# ---- 0. preflight --------------------------------------------------------

require_root

for f in "$WRAPPER_SRC" "$HOOK_SRC" "$GUARD"; do
  [[ -f $f ]] || { echo "Missing required file: $f" >&2; exit 1; }
done

# ---- 1. wrapper ----------------------------------------------------------

# Stable pointer: ~/.config/omarchy-ext4-survivor/repo -> this repo folder.
# Everything else (rc function, hook, skills, wrapper symlink) hangs off this
# one pointer, so moving/renaming the repo folder only requires relinking it.
POINTER_LINK="$TARGET_HOME/.config/omarchy-ext4-survivor/repo"

say "Maintaining stable pointer -> $POINTER_LINK"
mkdir -p "$(dirname "$POINTER_LINK")"
ln -sfn "$SRC" "$POINTER_LINK"

say "Installing wrapper -> $WRAPPER_LINK"
ln -sfn "$POINTER_LINK/bin/omarchy" "$WRAPPER_LINK"
chmod +x "$WRAPPER_SRC"

# ---- 2. native hook ------------------------------------------------------

say "Installing post-update hook for $TARGET_USER -> $HOOK_LINK"
mkdir -p "$(dirname "$HOOK_LINK")"
ln -sfn "$POINTER_LINK/hooks/post-update.d/00-grub-guard.sh" "$HOOK_LINK"
chmod +x "$HOOK_SRC"

# The hook dir was created by root under sudo; hand it back to the user so
# omarchy-hook (running as that user) can manage it.
if [[ -n ${SUDO_USER:-} ]]; then
  chown -R "$SUDO_USER:" "$(dirname "$HOOK_LINK")"
fi

# Earlier versions of this script installed the hook into $HOME, which under
# sudo meant /root. That copy is inert dead weight; remove it.
STRAY_ROOT_HOOK="/root/.config/omarchy/hooks/post-update.d/00-grub-guard.sh"
if (( EUID == 0 )) && [[ -e $STRAY_ROOT_HOOK || -L $STRAY_ROOT_HOOK ]]; then
  say "Removing stray root hook from an earlier run: $STRAY_ROOT_HOOK"
  rm -f "$STRAY_ROOT_HOOK"
fi

# ---- 3. golden store seeding ---------------------------------------------

# Dedupe a legacy duplicate `cryptdevice` in /etc/default/grub so the seeded
# golden baseline is the clean, working state. Back up before touching it.
say "Checking /etc/default/grub for duplicate cryptdevice"
if [[ $(grep -c 'cryptdevice=' "$DEFAULT_GRUB_LIVE" 2>/dev/null || true) -gt 1 ]]; then
  warn "duplicate cryptdevice found; backing up and removing it from GRUB_CMDLINE_LINUX_DEFAULT"
  [[ -f $DEFAULT_GRUB_LIVE.bak ]] || cp -a "$DEFAULT_GRUB_LIVE" "$DEFAULT_GRUB_LIVE.bak"
  # Strip ONLY the cryptdevice token from GRUB_CMDLINE_LINUX_DEFAULT, preserving
  # every other parameter this machine already has. Never rewrite the whole value
  # to a fixed string: the unlock params and the user's own kernel options differ
  # per machine. (The remaining cryptdevice in GRUB_CMDLINE_LINUX is left intact.)
  tmp_grub="$(mktemp)"
  awk '
    /^GRUB_CMDLINE_LINUX_DEFAULT=/ {
      line = $0
      sub(/^GRUB_CMDLINE_LINUX_DEFAULT="/, "", line)
      sub(/"$/, "", line)
      n = split(line, parts, " ")
      out = ""
      for (i = 1; i <= n; i++) {
        if (parts[i] ~ /^cryptdevice=/) continue
        out = (out == "" ? parts[i] : out " " parts[i])
      }
      print "GRUB_CMDLINE_LINUX_DEFAULT=\"" out "\""
      next
    }
    { print }
  ' "$DEFAULT_GRUB_LIVE" > "$tmp_grub" && cat "$tmp_grub" > "$DEFAULT_GRUB_LIVE"
  rm -f "$tmp_grub"
  grep -q 'cryptdevice=' "$DEFAULT_GRUB_LIVE" || {
    warn "dedupe removed all cryptdevice entries; restoring backup"
    cp -a "$DEFAULT_GRUB_LIVE.bak" "$DEFAULT_GRUB_LIVE"
    exit 1
  }
fi

say "Seeding system boot baseline -> $GUARD_SYS_DIR/current"
env OMARCHY_PATH="/usr/share/omarchy" bash "$GUARD" --capture || true


# ---- 4. skill ------------------------------------------------------------

say "Installing omarchy-boot-rescue skill symlinks"
for skill_dir in \
  "${TARGET_HOME}/.agents/skills" \
  "${TARGET_HOME}/.config/opencode/skills" \
  "${TARGET_HOME}/.claude/skills"; do
  mkdir -p "$skill_dir"
  ln -sfn "$POINTER_LINK/skills/omarchy-boot-rescue" "$skill_dir/omarchy-boot-rescue"
done
if [[ -n ${SUDO_USER:-} ]]; then
  chown -R "$SUDO_USER:" "${TARGET_HOME}/.agents/skills/omarchy-boot-rescue" \
                           "${TARGET_HOME}/.config/opencode/skills/omarchy-boot-rescue" \
                           "${TARGET_HOME}/.claude/skills/omarchy-boot-rescue" 2>/dev/null || true
fi

# ---- 5. verify + golden promotion ----------------------------------------

say "Running verification (--check)"
env OMARCHY_PATH="/usr/share/omarchy" bash "$GUARD" --check

say "Promoting verified state to golden (--accept-current)"
env OMARCHY_PATH="/usr/share/omarchy" bash "$GUARD" --accept-current

say "setup complete."
echo "Boot-guard is active. Future updates via 'omarchy update' are wrapped;"
echo "other update paths are covered by the native post-update hook."
echo "AI rescue skill 'omarchy-boot-rescue' is available to your assistants."
