---
name: omarchy-boot-rescue
description: Diagnose and repair Omarchy 4 boot failures on non-btrfs (ext4+LVM+LUKS) machines. Knows the UKI boot pipeline, how it differs from pre-quattro Omarchy 3, the failure classes from real incidents (chsnap abort, lvm2 hook loss, UKI cmdline loss, empty GRUB menu, BootOrder collapse), and the grub-guard tooling for capture/verify/heal/restore. Use when an Omarchy machine drops to emergency shell after an update, when GRUB loses its Linux entry, when boot hangs at TPM/plymouth/LUKS prompts, or before/after boot-critical updates.
---

# Omarchy Boot Rescue (ext4 + LVM + LUKS class)

Help the user diagnose and repair Omarchy 4 boot problems. This skill encodes the
boot architecture, the failure classes observed in real incidents, the golden-guard
tooling, and the safety rails. Default goal: restore bootability while ADOPTING
whatever upstream changed — never silently clobber new upstream settings; surface
them for review.

## 1. How Omarchy 4 boots (quattro / package-backed)

```
UEFI firmware
  └─ NVRAM entry (BootOrder) → GRUB (grubx64.efi)          [bootloader + menu]
       └─ grub.cfg → chainloader /EFI/Linux/omarchy_linux*.efi
            └─ UKI = kernel + initramfs + cmdline (all baked into one EFI binary)
                 └─ kernel + initramfs: LUKS unlock (encrypt) → LVM (lvm2) → root FS
```

- The UKIs live on the ESP: `/boot/efi/EFI/Linux/omarchy_linux.efi` (+ `-lts`).
- `limine-mkinitcpio` builds them: initramfs via mkinitcpio (hooks from
  `/etc/mkinitcpio.conf.d/*.conf`, notably `omarchy_hooks.conf`), cmdline resolved by
  `limine-entry-tool --get-cmdline`.
- **Cmdline source-of-truth rules** (critical): `limine-entry-tool` merges
  `KERNEL_CMDLINE[default]+=` lines from `/etc/limine-entry-tool.d/*.conf`. If any such
  drop-in exists, `/etc/kernel/cmdline` and `/proc/cmdline` are **ignored** for the UKI
  build (upstream comment in `omarchy-upgrade-to-quattro` documents this).
- GRUB on these machines is menu + chainloader + NVRAM manager. `10_linux` scans
  `/boot/vmlinuz-*` — empty on UKI-only layouts, so `grub.cfg` needs a chainloader
  drop-in (`/etc/grub.d/12_omarchy_uki`) or the menu silently loses Linux.
- Snapper/Limine-snapshot integration is **btrfs-only**. On ext4 it must stay off
  (ext4 create-config needs `/sbin/chsnap`, which is not packaged anywhere).

## 2. Differences from Omarchy 3 (pre-quattro)

| Aspect | Omarchy 3 | Omarchy 4 (quattro) |
|---|---|---|
| Layout | git clone in `~/.local/share/omarchy` | pacman packages; `/usr/share/omarchy` + `~/.local/share/omarchy` (root-owned, package-synced) |
| Shell | waybar/quickshell-git mix | quickshell (packaged 0.3.1+) via uwsm + Hyprland |
| Boot artifacts | classic vmlinuz + initramfs + presets | **UKIs only** (presets retired to `.pacsave`, plain pair removed from /boot) |
| Kernel cmdline | `/etc/kernel/cmdline` + GRUB_CMDLINE_* | `/etc/limine-entry-tool.d/*.conf` `KERNEL_CMDLINE[default]+=` (entry-tool merge; see rule above) |
| Snapshots | snapper+limine (btrfs) | same, btrfs-only; ext4 → Timeshift/guard instead |
| Updates | git pull + pacman | `omarchy update` (wrapper/hook-guarded on rescue installs) |

## 3. Triage by symptom → incident playbook

Symptom: **emergency shell after update**
1. Check `/proc/cmdline` (if reachable): does it contain `cryptdevice=` and `root=`?
   - Missing → cmdline lost in UKI build → Fix: append unlock params to
     `/etc/limine-entry-tool.d/omarchy-defaults.conf` as
     `KERNEL_CMDLINE[default]+= " cryptdevice=UUID=<luks-uuid>:<mapper> root=<root> rw"`,
     then `limine-mkinitcpio` (answer Y), verify with
     `objcopy -O binary --only-section=.cmdline <uki> /dev/stdout | tr -d '\0'`.
     (Incident 4.)
   - Present but still emergency shell → check hooks: initramfs missing `lvm2`
     → restore `HOOKS=(... block encrypt lvm2 filesystems fsck)` in
     `/etc/mkinitcpio.conf.d/omarchy_hooks.conf`, rebuild. (Incident 1.)
2. Derive params without hardcoding:
   `root=$(findmnt -rno SOURCE /)`; stack=`lsblk -srno TYPE,NAME,UUID $root`; crypt row
   gives mapper name; the row behind it gives the LUKS UUID. LUKS UUID must match
   `cryptsetup luksUUID <part>` (same value as the `part` row's UUID on LUKS-on-part).

Symptom: **GRUB menu has no Linux entry / boots Windows**
- `10_linux` scans `/boot/vmlinuz-*` → empty on UKI-only → regenerated grub.cfg loses
  Arch (Incident 3). Fix: install `/etc/grub.d/12_omarchy_uki` chainloader bridge
  (`fix-boot-bridge.sh`) and regenerate. Never run bare `grub-mkconfig` on UKI-only
  layouts without the bridge — guard precondition prevents this.

Symptom: **update aborts at "Creating config failed (/sbin/chsnap not installed)"**
- Snapper ext4 backend needs chsnap (not packaged). Fix: filesystem-gated snapper.sh
  (`fix-update-blockers.sh`) + `NoUpgrade = usr/share/omarchy/install/config/snapper.sh`
  in pacman.conf until upstream PR #7403 merges. (Incident 1 blocker.)

Symptom: **TPM/SMBIOS "Volume full" / "Failed to measure" warnings at boot**
- Benign Measured Boot noise, not fatal. Do NOT try to add `systemd.tpm2_measure=0`
  via GRUB edit on UKI chainload entries — params are baked into the UKI. To change
  them, edit the cmdline sources and rebuild (Incident 4 sidebar).

Symptom: **Windows gone from firmware picker**
- BootOrder collapsed (old guard bug or grub-install). Preserve-all reorder:
  `efibootmgr -o 0000,0003,0005` (adapt numbers from `efibootmgr` listing; GRUB first,
  keep all others). Windows also remains reachable via GRUB's os-prober menu entry.

Symptom: **`.pacnew` appeared in `/etc/limine-entry-tool.d/` after an update**
- `omarchy-defaults.conf` is package-owned, but on this layout the machine-specific
  `cryptdevice=`/`root=` line lives **inside that same file**. An upstream change therefore
  arrives as `omarchy-defaults.conf.pacnew`, and naively moving it over the live file
  **deletes the unlock params** — the next UKI rebuild then boots to an emergency shell. The
  guard's `ensure_unlock_params` heals it, but don't rely on that. **Hand-merge, never `mv`**:
  keep the `cryptdevice=…:… root=…` line, fold in upstream's new `KERNEL_CMDLINE[default]+=`
  additions, then `grub-guard --repair` (rebuild + artifact verify) and `--accept-current`.
  Run `pacdiff` / `find /etc -name '*.pacnew'` after every update.
- Real example: upstream added `systemd.tty.term.console=dumb` (works around a ~1-in-10
  black-screen hang at "Starting Switch Root" under Plymouth) — merge that in *alongside* the
  retained cryptdevice line, not instead of it.

Symptom: **invisible hang at wrapper stage 4**
- gum confirm rendered without a foreground tty. The wrapper now gates on `[[ -t 0 ]]`;
  kill stale PIDs and rerun `grub-guard --repair` if needed.

## 4. Guardrails (things NOT to do)

- Never run bare `mkinitcpio -P` on UKI-only layouts: no presets → no-op + blocking
  interactive follow-up. Use `limine-mkinitcpio` (always with `</dev/null`).
- Never trust `/etc/kernel/cmdline` alone in UKI mode — verify the **artifact**:
  `objcopy -O binary --only-section=.cmdline <uki> /dev/stdout | tr -d '\0'` must
  contain `cryptdevice=` and `root=`.
- Never `efibootmgr -o <single-num>` (collapses BootOrder); always preserve all
  entries; sanity-gate values against `^[0-9A-Fa-f]{4}(,[0-9A-Fa-f]{4})*$`.
- Never let `grub-mkconfig` run on UKI-only machines without the chainloader bridge.
- Never clobber upstream boot-config additions when healing — merge/append only the
  missing critical params; surface the rest for review.
- Never `mv` a `.pacnew` over `/etc/limine-entry-tool.d/omarchy-defaults.conf` (or any
  cmdline source) — it would drop this machine's `cryptdevice`/`root`. Hand-merge.
- `lsblk` dependency walks need `-s` (plain lsblk hides parent layers).
- Never leave executable files (including backups) in `/etc/grub.d/` — `grub-mkconfig`
  executes every file there; a `.pre-bootguard`-style backup will double-emit every menu
  entry. Back up to the guard store instead.
- Theme icons must be 8-bit TrueColorAlpha PNGs (`PNG32:`); 16-bit grayscale PNGs fail
  GRUB's loader and entries silently fall back to generic icons.

## 5. Tooling map (this repo)

| Command | Purpose |
|---|---|
| `bin/grub-guard.sh --capture` | snapshot current boot config into `current/` (per-update diff baseline) |
| `bin/grub-guard.sh --repair` | heal cmdline sources + hooks → rebuild (limine-aware) → regenerate (preconditioned) → BootOrder → double-pass artifact verify; on success promotes golden |
| `bin/grub-guard.sh --check` | read-only verify; exit 1 with issue lines when broken |
| `bin/grub-guard.sh --restore` | replay golden (configs + entry-tool confs) + rebuild + verify |
| `bin/grub-guard.sh --explain-diff` | unified diff of boot configs (pre-update vs live) + verdict; written to `$GUARD_DIR/boot-diff-*.txt` |
| `bin/grub-guard.sh --accept-current` | after human/AI review: promote verified current state to golden |
| `fix-update-blockers.sh` | gated snapper.sh + NoUpgrade (chsnap abort fix) |
| `fix-boot-bridge.sh` | 12_omarchy_uki chainloader bridge install + regen |
| `setup.sh` | full wiring (wrapper, hook, skill, store) |

State/paths: system store `/var/lib/omarchy-boot-guard/{current,golden}`; repo mirrors
`backups/<date>/`; logs `~/.local/state/omarchy/{grub-guard.log,update-wrapper.log}`.

Golden store contents: `default-grub`, `omarchy_hooks.conf`, `kernel-cmdline`,
`default-limine`, `limine-entry-tool.d/`, `efibootmgr.txt`, `packages.txt`,
`seed.timestamp`.

## 6. Recovery recipes (Live USB, condensed)

Full versions: `docs/migration-update-fix.md` (Incidents 1–4).

```bash
cryptsetup luksOpen /dev/nvme0n1p3 cryptroot   # adapt device
vgchange -ay
mount /dev/mapper/volgroup0-lv_root /mnt
mount /dev/nvme0n1p2 /mnt/boot && mount /dev/nvme0n1p1 /mnt/boot/efi
mount --bind /dev /mnt/dev; mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys;   mount --bind /run  /mnt/run
arch-chroot /mnt
# preferred: use the guard
bash <repo>/bin/grub-guard.sh --repair
# or manual: fix omarchy_hooks.conf (lvm2), omarchy-defaults.conf (cryptdevice),
# then limine-mkinitcpio, then grub-mkconfig (bridge present), exit+reboot
```

## 7. Reviewing upstream boot changes (the reminder flow)

When the guard reports "upstream changed boot settings; working params auto-restored":
1. Read `grub-guard --explain-diff` output — classified verdict on top.
2. Ask: does the change make sense for this layout (e.g., new security params)?
3. If adopting: edit the relevant source (`/etc/limine-entry-tool.d/*.conf`,
   `omarchy_hooks.conf`), ensure critical params remain, `--repair`, then
   `--accept-current` to re-bless golden.
4. If upstream's new param set conflicts with this layout class: keep golden params,
   note it upstream (link incident docs), revisit after upstream fix.

Machine specifics (LUKS UUID, volume names) live in the golden store per machine —
this skill and the guard code contain none.
