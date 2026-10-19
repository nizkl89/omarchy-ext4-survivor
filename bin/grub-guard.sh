#!/bin/bash

# omarchy:summary=Golden-guard for the boot pipeline: capture, verify, heal, restore
# omarchy:args=<--capture|--repair|--check|--restore|--explain-diff|--accept-current>
# omarchy:hidden=true

# grub-guard: keeps non-btrfs (ext4 + LVM + LUKS class) installs bootable
# through Omarchy updates.
#
# Layouts supported (auto-detected):
#   classic — /boot/vmlinuz-linux + initramfs; grub.cfg carries kernel cmdline
#   uki     — ESP:/EFI/Linux/omarchy_linux*.efi only; cmdline baked into each
#             UKI via limine-entry-tool from /etc/limine-entry-tool.d/*.conf
#             (+ /etc/kernel/cmdline only when no [default]+= drop-in exists)
#
# Policy: golden-guard. Upstream boot-config changes are ADOPTED when the
# critical unlock params survive; when they go missing the golden settings are
# restored automatically and the user is reminded (via the hook/wrapper) to
# review the change with the omarchy-boot-rescue AI skill.
#
# Machine-agnostic: expected unlock params are DERIVED per machine
# (golden store → /proc/cmdline → live lsblk stack walk). No hardcoded UUIDs.

set -uo pipefail

# ---- configuration -------------------------------------------------------

# Live system paths (the things updates rewrite)
HOOKS_CONF_LIVE="${OMARCHY_HOOKS_CONF_LIVE:-/etc/mkinitcpio.conf.d/omarchy_hooks.conf}"
DEFAULT_GRUB_LIVE="${OMARCHY_DEFAULT_GRUB_LIVE:-/etc/default/grub}"
KERNEL_CMDLINE_LIVE="${OMARCHY_KERNEL_CMDLINE_LIVE:-/etc/kernel/cmdline}"
GRUB_CFG_LIVE="${OMARCHY_GRUB_CFG_LIVE:-/boot/grub/grub.cfg}"
EFI_DIR_LIVE="${OMARCHY_EFI_DIR_LIVE:-/boot/efi}"
BOOT_DIR_LIVE="${OMARCHY_BOOT_DIR_LIVE:-/boot}"
ENTRY_TOOL_DIR="${OMARCHY_ENTRY_TOOL_DIR:-/etc/limine-entry-tool.d}"
MKINITCPIO_D_DIR="${OMARCHY_MKINITCPIO_D_DIR:-/etc/mkinitcpio.d}"
GRUBD_DIR="${OMARCHY_GRUBD_DIR:-/etc/grub.d}"

# Two-tier golden store: current/ = per-update baseline (diff reference),
# golden/ = last artifact-verified-bootable state (restore source).
GUARD_SYS_DIR="${OMARCHY_BOOT_GUARD_DIR:-/var/lib/omarchy-boot-guard}"
GUARD_SYS_CURRENT="${GUARD_SYS_DIR}/current"
GUARD_SYS_GOLDEN="${GUARD_SYS_DIR}/golden"
GUARD_REPO_DIR="${OMARCHY_BOOT_GUARD_REPO:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/backups}"

# Resolve the log path to the *invoking* user's home. `sudo bash grub-guard.sh`
# runs with HOME=/root, which would otherwise split manual repairs into
# /root/.local/state/omarchy/grub-guard.log and hide them from the user-facing
# log (and from the post-update hook's drift check).
if [[ -n ${OMARCHY_BOOT_GUARD_LOG:-} ]]; then
  LOG_FILE="$OMARCHY_BOOT_GUARD_LOG"
else
  log_home="$HOME"
  if (( EUID == 0 )) && [[ -n ${SUDO_USER:-} && ${SUDO_USER:-} != root ]]; then
    log_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [[ -n $log_home ]] || log_home="$HOME"
  fi
  LOG_FILE="$log_home/.local/state/omarchy/grub-guard.log"
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
# If a sudo-run created the directory/file, hand it back to the invoking user so
# later wrapper/hook runs (which run as that user) can keep appending.
if (( EUID == 0 )) && [[ -n ${SUDO_USER:-} && ${SUDO_USER:-} != root ]]; then
  chown "$SUDO_USER:" "$(dirname "$LOG_FILE")" 2>/dev/null || true
  [[ -f $LOG_FILE ]] && chown "$SUDO_USER:" "$LOG_FILE" 2>/dev/null || true
fi

log()  { printf '%s  [grub-guard] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '%s  [grub-guard] WARN %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }
die()  { printf '%s  [grub-guard] ERROR %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; exit 1; }

as_root() {
  if (( EUID == 0 )); then "$@"; else sudo "$@"; fi
}

# ---- core derivation ------------------------------------------------------

root_source() {
  findmnt -rno SOURCE / 2>/dev/null || true
}

# Walk the device stack under / to the LUKS layer; echo the two critical
# tokens for this machine:  cryptdevice=UUID=<luks-uuid>:<mapper>  root=<root>
# Works for LUKS-on-partition and LUKS-in-LVM / LVM-in-LUKS shapes.
derive_unlock_from_stack() {
  local root stack crypt_dm crypt_uuid
  root="$(root_source)"
  [[ -n $root ]] || return 1
  stack="$(as_root lsblk -srno TYPE,NAME,UUID "$root" 2>/dev/null || true)"
  [[ -n $stack ]] || return 1
  crypt_dm="$(awk '$1=="crypt"{print $2; exit}' <<<"$stack")"
  # The LUKS UUID sits on the row *behind* the crypt layer (parent device).
  crypt_uuid="$(awk 'f{print $3; exit} $1=="crypt"{f=1}' <<<"$stack")"
  [[ -n $crypt_dm && -n $crypt_uuid ]] || return 1
  printf 'cryptdevice=UUID=%s:%s root=%s' "$crypt_uuid" "$crypt_dm" "$root"
}

# Critical tokens from the best available source:
#   1. golden store (last verified-bootable capture)
#   2. /proc/cmdline (valid only while the current session boots fine)
#   3. live device-stack derivation
# Sets CRIT_CRYPT / CRIT_ROOT globals. Fallback chain keeps this per-machine —
# no literals in code.
critical_tokens() {
  local exp=""
  if as_root test -f "$GUARD_SYS_GOLDEN/kernel-cmdline" 2>/dev/null; then
    exp="$(as_root cat "$GUARD_SYS_GOLDEN/kernel-cmdline" 2>/dev/null || true)"
  fi
  if [[ $exp != *cryptdevice=* || $exp != *root=* ]]; then
    exp="$(cat /proc/cmdline 2>/dev/null || true)"
  fi
  if [[ $exp != *cryptdevice=* || $exp != *root=* ]]; then
    exp="$(derive_unlock_from_stack)" || return 1
  fi
  CRIT_CRYPT="$(grep -oE 'cryptdevice=[^ ]+' <<<"$exp" | head -1)"
  CRIT_ROOT="$(grep -oE 'root=[^ ]+' <<<"$exp" | head -1)"
  [[ -n $CRIT_CRYPT && -n $CRIT_ROOT ]]
}

source_has_unlock() {  # <file>
  as_root test -f "$1" 2>/dev/null || return 2
  as_root grep -qF "$CRIT_CRYPT" "$1" 2>/dev/null &&
    as_root grep -qF "$CRIT_ROOT" "$1" 2>/dev/null
}

# Every file that can feed the UKI/kernel cmdline on this layout.
cmdline_sources() {
  as_root test -f "$KERNEL_CMDLINE_LIVE" 2>/dev/null && echo "$KERNEL_CMDLINE_LIVE"
  as_root grep -l 'KERNEL_CMDLINE\[default\]+=' "$ENTRY_TOOL_DIR"/*.conf 2>/dev/null | sort -u
}

hooks_have_lvm2() {
  as_root grep -q 'HOOKS=.*lvm2' "$HOOKS_CONF_LIVE" 2>/dev/null
}

ukis_list() {  # full paths of current Omarchy UKIs
  as_root find "$EFI_DIR_LIVE/EFI/Linux" -maxdepth 1 -name 'omarchy_linux*.efi' -print 2>/dev/null | sort
}

ukis_current() {
  [[ -n $(ukis_list) ]]
}

boot_layout() {
  if as_root test -f "$BOOT_DIR_LIVE/vmlinuz-linux" 2>/dev/null; then
    echo classic
  elif ukis_current; then
    echo uki
  else
    echo unknown
  fi
}

grub_menu_has_omarchy() {
  as_root grep -qE 'menuentry .*(Linux|linux|Omarchy)' "$GRUB_CFG_LIVE" 2>/dev/null
}

# Embedded cmdline of a UKI, via the same technique upstream's upgrade script
# uses to inspect UKIs.
uki_embedded_cmdline() {  # <uki path>
  as_root objcopy -O binary --only-section=.cmdline "$1" /dev/stdout 2>/dev/null | tr -d '\0'
}

uki_has_unlock() {  # <uki path>
  local cmd
  cmd="$(uki_embedded_cmdline "$1")"
  [[ $cmd == *"$CRIT_CRYPT"* && $cmd == *"$CRIT_ROOT"* ]]
}

# All layout-aware issues, one per line. Empty output = healthy.
# Return 2 = cannot even derive expectations (caller decides how loud).
layout_issues() {
  local issue
  critical_tokens || { echo "cannot derive expected unlock params for this machine"; return 2; }

  hooks_have_lvm2 || echo "HOOKS missing the lvm2 hook in $HOOKS_CONF_LIVE"

  local src
  while IFS= read -r src; do
    [[ -n $src ]] || continue
    if source_has_unlock "$src"; then continue; fi
    case $? in
      2) echo "cmdline source unreadable: $src" ;;
      *) echo "cmdline source missing unlock params: $src" ;;
    esac
  done < <(cmdline_sources)

  case "$(boot_layout)" in
    classic)
      source_has_unlock "$GRUB_CFG_LIVE" || echo "grub.cfg missing unlock params"
      ;;
    uki)
      local uki bad=0
      while IFS= read -r uki; do
        [[ -n $uki ]] || continue
        uki_has_unlock "$uki" || { echo "UKI cmdline missing unlock params: $uki"; bad=1; }
      done < <(ukis_list)
      grub_menu_has_omarchy || { echo "grub.cfg has no Omarchy menu entries"; bad=1; }
      ;;
    *)
      echo "unknown boot layout: neither classic pair nor current UKIs"
      ;;
  esac
  return 0
}

# ---- healing ---------------------------------------------------------------

# Append the critical params to cmdline sources that lack them. Never rewrites
# unrelated content: upstream additions stay; only what's missing is added.
ensure_unlock_params() {
  local healed=0 src
  critical_tokens || { warn "cannot derive unlock params; nothing healed"; return 1; }

  while IFS= read -r src; do
    [[ -n $src ]] || continue
    if source_has_unlock "$src"; then continue; fi
    case $? in
      2) warn "cmdline source unreadable, skipping: $src"; continue ;;
    esac
    if [[ $src == *.conf ]]; then
      if as_root sh -c "printf '\n# Restored by grub-guard (unlock params lost in an update)\nKERNEL_CMDLINE[default]+=\" $CRIT_CRYPT $CRIT_ROOT\"\n' >> '$src'"; then
        log "healed cmdline source: $src"
        healed=$((healed + 1))
      else
        warn "failed to heal $src"
      fi
    else
      if as_root sh -c "printf '%s ' \"$CRIT_CRYPT $CRIT_ROOT\" >> '$src'"; then
        log "healed cmdline source: $src"
        healed=$((healed + 1))
      else
        warn "failed to heal $src"
      fi
    fi
  done < <(cmdline_sources)

  # A source file may not exist at all (e.g. /etc/kernel/cmdline removed).
  if ! as_root test -e "$KERNEL_CMDLINE_LIVE" 2>/dev/null; then
    if as_root sh -c "printf '%s\n' '$CRIT_CRYPT $CRIT_ROOT' > '$KERNEL_CMDLINE_LIVE'"; then
      log "recreated missing $KERNEL_CMDLINE_LIVE"
      healed=$((healed + 1))
    fi
  fi

  return 0
}

repair_hooks_conf() {
  if hooks_have_lvm2; then
    log "omarchy_hooks.conf already has the lvm2 hook"
    return 0
  fi
  warn "omarchy_hooks.conf lost the lvm2 hook; restoring"
  as_root bash -c "cat > '$HOOKS_CONF_LIVE' <<'EOF'
HOOKS=(base udev plymouth autodetect microcode modconf kms keyboard keymap consolefont block encrypt lvm2 filesystems fsck)
EOF"
  hooks_have_lvm2 && log "lvm2 restored" || { warn "still missing lvm2"; return 1; }
}

# ---- rebuilds ---------------------------------------------------------------

# Pick the rebuild tool that will actually succeed, and run it with failure
# detection + a build-scoped [lvm2] confirmation (a cumulative-log grep once
# false-positived off stale lines from earlier runs).
rebuild_boot_images() {
  local rebuild="${REBUILD_TOOL:-}"

  if [[ -z $rebuild ]]; then
    # limine-mkinitcpio owns UKI generation and is always shipped with Omarchy;
    # prefer it whenever present — presets restored from .pacsave may reference
    # plain kernels that no longer exist on UKI-only layouts (hybrid state).
    if command -v limine-mkinitcpio >/dev/null 2>&1; then
      rebuild=limine-mkinitcpio
    elif as_root sh -c "ls '$MKINITCPIO_D_DIR'/*.preset >/dev/null 2>&1"; then
      rebuild="mkinitcpio -P"
    else
      warn "no limine-mkinitcpio and no usable mkinitcpio presets; cannot rebuild boot images"
      REBUILD_TOOL_USED="none"
      return 1
    fi
  fi
  REBUILD_TOOL_USED="$rebuild"

  local log_start rc
  log_start="$(wc -l <"$LOG_FILE" 2>/dev/null || echo 0)"
  log "rebuilding boot images: $rebuild"
  as_root $rebuild </dev/null 2>&1 | tee -a "$LOG_FILE"
  rc="${PIPESTATUS[0]}"
  if (( rc != 0 )); then
    warn "rebuild tool '$rebuild' failed (exit $rc)"
    return 1
  fi

  # Confirm [lvm2] only against lines this build added — stale matches from
  # earlier runs must not count.
  if tail -n +"$((log_start + 1))" "$LOG_FILE" | grep -q "Running build hook: \[lvm2\]"; then
    log "confirmed hook [lvm2] in image build"
  else
    warn "could not confirm [lvm2] hook line in this build"
    return 1
  fi
  return 0
}

alternate_rebuild_tool() {  # <failed tool> — echo the other one, if usable
  case "$1" in
    limine-mkinitcpio)
      as_root sh -c "ls '$MKINITCPIO_D_DIR'/*.preset >/dev/null 2>&1" && echo "mkinitcpio -P"
      ;;
    mkinitcpio*)
      command -v limine-mkinitcpio >/dev/null 2>&1 && echo limine-mkinitcpio
      ;;
  esac
}

# Regenerate grub.cfg only when the result will still contain a Linux entry.
regenerate_grub() {
  local plain=0 bridge=0
  as_root sh -c "ls '$BOOT_DIR_LIVE'/vmlinuz-* >/dev/null 2>&1" && plain=1
  [[ -x "$GRUBD_DIR/12_omarchy_uki" ]] && bridge=1
  if (( ! plain )) && (( ! bridge )); then
    warn "skipping grub-mkconfig: would produce an empty Linux menu (no plain kernels, no 12_omarchy_uki bridge)"
    return 1
  fi
  log "regenerating grub.cfg from /etc/default/grub"
  as_root grub-mkconfig -o "$GRUB_CFG_LIVE" </dev/null 2>&1 | tee -a "$LOG_FILE"
}

prune_limine() {
  command -v efibootmgr &>/dev/null || return 0
  local bootmgr current_order grub_num first rest new_order
  bootmgr="$(as_root efibootmgr 2>/dev/null || true)"
  echo "$bootmgr" | grep -iq "limine" || { log "no Limine UEFI entry to prune"; return 0; }

  # Informational: the limine package ships a UEFI entry on these installs, so
  # this is expected on every run. Only act when GRUB is not already first.
  log "Limine UEFI entry present (expected); ensuring GRUB is first in BootOrder"
  grub_num=$(echo "$bootmgr" | grep -i "^Boot.*\* GRUB" | sed -E 's/^Boot([0-9A-F]{4}).*/\1/' | head -1)
  [[ -n $grub_num ]] || return 0

  current_order="$(echo "$bootmgr" | sed -nE 's/^BootOrder: //p' | tr -d '[:space:]')"
  if [[ -z $current_order ]]; then
    warn "could not read BootOrder; refusing to touch NVRAM"
    return 1
  fi
  first="${current_order%%,*}"
  if [[ $first == "$grub_num" ]]; then
    log "GRUB ($grub_num) already first in BootOrder: $current_order"
    return 0
  fi
  rest="$(printf '%s\n' "$current_order" | tr ',' '\n' | grep -vx "$grub_num" | paste -sd, -)"
  new_order="$grub_num${rest:+,$rest}"
  if [[ ! $new_order =~ ^[0-9A-Fa-f]{4}(,[0-9A-Fa-f]{4})*$ ]]; then
    warn "refusing to write malformed BootOrder '$new_order'"
    return 1
  fi
  log "setting BootOrder: $new_order"
  as_root efibootmgr -o "$new_order" </dev/null 2>&1 | tee -a "$LOG_FILE"
}

# ---- golden store ----------------------------------------------------------

store_files() {  # <dest-dir>: copy the live boot config set into a directory
  local dest="$1"
  as_root mkdir -p "$dest"
  # /etc/default/grub is stored as `default-grub`: that is the name the readers
  # in --restore and --explain-diff expect. Storing it under its basename
  # (`grub`) silently made those two skip the GRUB config entirely.
  if as_root test -f "$DEFAULT_GRUB_LIVE" 2>/dev/null; then
    as_root install -m 0644 "$DEFAULT_GRUB_LIVE" "$dest/default-grub" 2>/dev/null
  fi
  if as_root test -f "$HOOKS_CONF_LIVE" 2>/dev/null; then
    as_root install -m 0644 "$HOOKS_CONF_LIVE" "$dest/$(basename "$HOOKS_CONF_LIVE")" 2>/dev/null
  fi
  [[ -f $KERNEL_CMDLINE_LIVE ]] && as_root install -m 0644 "$KERNEL_CMDLINE_LIVE" "$dest/kernel-cmdline" 2>/dev/null
  # Replace any prior copy: `cp -a SRC DEST` nests SRC *inside* DEST when DEST
  # already exists — which silently created limine-entry-tool.d/limine-entry-tool.d
  # on every capture after the first, leaving the stale flat copy as the one
  # --restore and --explain-diff read.
  as_root rm -rf "$dest/limine-entry-tool.d"
  as_root sh -c "mkdir -p '$dest/limine-entry-tool.d' && cp -a '$ENTRY_TOOL_DIR/.' '$dest/limine-entry-tool.d/' 2>/dev/null" || true
  [[ -f /etc/default/limine ]] && as_root install -m 0644 /etc/default/limine "$dest/default-limine" 2>/dev/null
  as_root sh -c "efibootmgr > '$dest/efibootmgr.txt'" 2>/dev/null || true
  as_root sh -c "pacman -Q > '$dest/packages.txt'" 2>/dev/null || true
  as_root sh -c "date -u +%FT%TZ > '$dest/seed.timestamp'" 2>/dev/null
}

seed_current() {
  log "capturing current boot config"
  store_files "$GUARD_SYS_CURRENT"
  local date_bucket repo_dir
  date_bucket="$(date -u +%Y%m%d)"
  repo_dir="$GUARD_REPO_DIR/$date_bucket"
  mkdir -p "$repo_dir" 2>/dev/null || true
  as_root cp -a "$GUARD_SYS_CURRENT/." "$repo_dir/" 2>/dev/null || true
  if (( EUID == 0 )) && [[ -n ${SUDO_USER:-} ]]; then
    chown -R "$SUDO_USER:" "$repo_dir" 2>/dev/null || true
  fi
  log "current baseline captured (system: $GUARD_SYS_CURRENT, repo: $repo_dir)"
}

golden_present() {
  as_root test -d "$GUARD_SYS_GOLDEN" 2>/dev/null &&
    as_root sh -c "ls '$GUARD_SYS_GOLDEN'/* >/dev/null 2>&1"
}

# Promote the current capture to golden — only ever after layout+artifact
# verification has passed, or on explicit user acceptance.
promote_golden() {
  store_files "$GUARD_SYS_GOLDEN"
  local date_bucket repo_dir
  date_bucket="$(date -u +%Y%m%d)"
  repo_dir="$GUARD_REPO_DIR/$date_bucket"
  mkdir -p "$repo_dir" 2>/dev/null || true
  as_root cp -a "$GUARD_SYS_GOLDEN/." "$repo_dir/" 2>/dev/null || true
  if (( EUID == 0 )) && [[ -n ${SUDO_USER:-} ]]; then
    chown -R "$SUDO_USER:" "$repo_dir" 2>/dev/null || true
  fi
  log "golden state promoted (verified-bootable reference updated)"
}

# ---- verdict ----------------------------------------------------------------

verify() {  # prints issues via warn; returns 0 when healthy
  local issues
  issues="$(layout_issues)" || true
  [[ -z $issues ]] && return 0
  while IFS= read -r issue; do
    [[ -n $issue ]] && warn "$issue"
  done <<<"$issues"
  return 1
}

# ---- main actions ------------------------------------------------------------

action_repair() {
  local pass issues rebuild_ok=0 failed_tool="" alt
  log "repair starting"
  repair_hooks_conf || true
  ensure_unlock_params || true

  for pass in 1 2; do
    rebuild_ok=0
    if rebuild_boot_images; then
      rebuild_ok=1
    else
      failed_tool="${REBUILD_TOOL_USED:-unknown}"
      # Adaptive: on rebuild-tool failure in pass 1, switch to the alternate
      # tool for pass 2 instead of retrying the same failing one.
      if (( pass == 1 )); then
        alt="$(alternate_rebuild_tool "$failed_tool")"
        if [[ -n $alt ]]; then
          warn "pass 1 rebuild tool '$failed_tool' failed; switching to '$alt' for pass 2"
          REBUILD_TOOL="$alt"
        fi
      fi
    fi
    regenerate_grub || true
    prune_limine || true
    issues="$(layout_issues)" || true
    # A failed rebuild means the images may be stale relative to a newly
    # installed kernel even when the old artifacts still verify — fail closed.
    if [[ -z $issues ]] && (( rebuild_ok )); then break; fi
    (( pass == 1 )) || break
    warn "verification still failing after pass 1; healing sources and rebuilding once more"
    ensure_unlock_params || true
  done

  if [[ -z $issues ]] && (( rebuild_ok )); then
    promote_golden
    log "repair finished; boot config verified OK (golden refreshed)"
    return 0
  fi
  (( rebuild_ok )) || warn "boot image rebuild failed in both passes; images are stale or unverified"
  while IFS= read -r issue; do
    [[ -n $issue ]] && warn "$issue"
  done <<<"$issues"
  warn "repair FAILED after double pass; boot images may not unlock LUKS. Do NOT reboot; run this again or use the omarchy-boot-rescue AI skill."
  return 1
}

action_check() {  # read-only; 0 healthy, 1 issues
  verify
}

action_capture() {
  seed_current
  if verify; then
    log "baseline is healthy; use --accept-current to promote it to golden"
  else
    warn "baseline has issues; NOT promoted to golden (fail-closed)"
    return 1
  fi
}

action_accept_current() {
  if verify; then
    promote_golden
    log "current state accepted as golden"
    return 0
  fi
  warn "cannot accept current state: verification failed"
  return 1
}

action_restore() {
  log "restoring boot config from golden store"
  if ! golden_present; then
    warn "no golden state available; cannot restore"
    return 1
  fi
  for f in default-grub omarchy_hooks.conf kernel-cmdline default-limine; do
    local target=""
    case "$f" in
      default-grub) target="$DEFAULT_GRUB_LIVE" ;;
      omarchy_hooks.conf) target="$HOOKS_CONF_LIVE" ;;
      kernel-cmdline) target="$KERNEL_CMDLINE_LIVE" ;;
      default-limine) target="/etc/default/limine" ;;
    esac
    [[ -n $target ]] && as_root test -f "$GUARD_SYS_GOLDEN/$f" && \
      as_root install -m 0644 "$GUARD_SYS_GOLDEN/$f" "$target" 2>/dev/null || true
  done
  if as_root test -d "$GUARD_SYS_GOLDEN/limine-entry-tool.d"; then
    # Clear a nested copy left by older guard versions before replaying, so
    # /etc/limine-entry-tool.d never gains a limine-entry-tool.d/ subdirectory.
    as_root rm -rf "$ENTRY_TOOL_DIR/limine-entry-tool.d"
    as_root cp -a "$GUARD_SYS_GOLDEN/limine-entry-tool.d/." "$ENTRY_TOOL_DIR/" 2>/dev/null || true
  fi
  repair_hooks_conf || true
  ensure_unlock_params || true
  rebuild_boot_images || true
  regenerate_grub || true
  prune_limine || true
  verify && log "restore finished; boot config verified OK" && return 0
  warn "restore ran but verification found problems"
  return 1
}

action_explain_diff() {
  local out_file="$GUARD_SYS_DIR/boot-diff-$(date -u +%Y%m%d-%H%M%S).txt"
  as_root mkdir -p "$GUARD_SYS_DIR" 2>/dev/null || true
  {
    echo "# Boot config diff: pre-update baseline vs live (as of $(date -u +%FT%TZ))"
    echo "# Verdict: $(verify >/dev/null 2>&1 && echo 'bootable — changes are informational' || echo 'CRITICAL: unlock params broken — run --repair before rebooting')"
    echo ""
    for pair in \
      "$GUARD_SYS_CURRENT/default-grub:$DEFAULT_GRUB_LIVE" \
      "$GUARD_SYS_CURRENT/omarchy_hooks.conf:$HOOKS_CONF_LIVE" \
      "$GUARD_SYS_CURRENT/kernel-cmdline:$KERNEL_CMDLINE_LIVE" \
      "$GUARD_SYS_CURRENT/default-limine:/etc/default/limine"; do
      local old="${pair%%:*}" new="${pair##*:}"
      [[ -f $old && -f $new ]] || continue
      echo "## $(basename "$new")"
      diff -u "$old" "$new" 2>/dev/null | tail -n +3
      echo ""
    done
    # Entry-tool confs: compare per-file
    if as_root test -d "$GUARD_SYS_CURRENT/limine-entry-tool.d"; then
      while IFS= read -r live; do
        local name base
        base="$(basename "$live")"
        old="$GUARD_SYS_CURRENT/limine-entry-tool.d/$base"
        [[ -f $old ]] || { echo "## NEW entry-tool conf: $base"; as_root cat "$live"; echo; continue; }
        diff -q "$old" "$live" >/dev/null 2>&1 && continue
        echo "## limine-entry-tool.d/$base"
        diff -u "$old" "$live" 2>/dev/null | tail -n +3
        echo ""
      done < <(as_root find "$ENTRY_TOOL_DIR" -maxdepth 1 -name '*.conf' -print 2>/dev/null)
    fi
  } | tee "$out_file"
  chmod 0644 "$out_file" 2>/dev/null || true
  log "diff written: $out_file"
}

# ---- dispatch ----------------------------------------------------------------

case "${1:-}" in
  --capture)        action_capture ;;
  --repair)         action_repair ;;
  --check)          action_check ;;
  --restore)        action_restore ;;
  --explain-diff)   action_explain_diff ;;
  --accept-current) action_accept_current ;;
  *)
    echo "Usage: grub-guard.sh <--capture|--repair|--check|--restore|--explain-diff|--accept-current>" >&2
    exit 1
    ;;
esac