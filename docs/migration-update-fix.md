# Migration & Update Boot Repair Notes (ext4 + LVM + LUKS)

This documents real boot-crash incidents on a machine whose root filesystem is
**ext4 over an LVM volume group (`volgroup0-lv_root`) over LUKS (`/dev/nvme0n1p3`)**, and
the step-by-step Live-USB repairs that recovered each one.

For a layout-generic, copy-paste-friendly version of the Live-USB session itself, see
[`usb-rescue.md`](usb-rescue.md). The automated alternative is
`bin/grub-guard.sh --repair` from this repo.

> **Adapt to your machine.** Every value below that is specific to the machine this was
> written on is a placeholder or a clearly-marked example. Device names (`/dev/nvme0n1p2`,
> `/dev/nvme0n1p3`), the volume group / logical volume names (`volgroup0`, `volgroup0-lv_root`),
> and the mapper name (`cryptroot`) are this machine's — substitute your own. The LUKS UUID is
> shown as `<luks-uuid>`; read yours with `cryptsetup luksUUID <your-luks-partition>`.
> Derive the unlock pair for your machine with
> `lsblk -srno TYPE,NAME,UUID "$(findmnt -rno SOURCE /)"`.

## Why this machine is prone to boot failure after Omarchy updates

The Omarchy update/upgrade pipeline is built around **Limine / UKI / btrfs**, and it rewrites
boot artifacts and the initramfs hook configuration to a state that this particular disk
layout cannot boot with. Two failures recur:

- The initramfs hook list (`/etc/mkinitcpio.conf.d/omarchy_hooks.conf`) loses the **`lvm2`**
  hook, so the initramfs cannot assemble `volgroup0-lv_root`.
- Limine/UKI machinery re-runs even though **GRUB is the active bootloader**, and
  `omarchy-settings` rewrites the hook config that GRUB depends on.

The result each time is an emergency shell (or a broken GRUB boot) because the kernel cannot
reach its root filesystem. The repairs below restore the correct hook list, kernel cmdline,
and GRUB configuration from a Live USB.

Backup baseline for this machine:

- Root LV: `/dev/mapper/volgroup0-lv_root` (ext4, `/`)
- Boot partition: `/dev/nvme0n1p2` (ext4, `/boot`)
- EFI partition: `/dev/nvme0n1p1` (vfat, `/boot/efi`)
- LUKS container: `/dev/nvme0n1p3` (cryptdevice)
- LUKS UUID: `<luks-uuid>`

---

## Incident 1 — Omarchy 3.8 → 4.0 upgrade, system booted into emergency shell

### Symptom
After running `omarchy upgrade to quattro` (3.8 → 4.0), the machine rebooted and dropped to
an **emergency shell** — it could not mount boot / the root volume.

### Root cause
Two things collided in the before-4.0.0 upgrade path:

1. The upgrade's Snapper configuration stage (`configure_snapper_policy` →
   `install/config/snapper.sh`) unconditionally wrote an `FSTYPE="btrfs"` Snapper root config
   on every filesystem. On an **ext4** root this fails (`/sbin/chsnap` is not installed /
   Snapper's ext4 backend throws `ProgramNotInstalledException`), aborting the upgrade midway.
2. The rebuilt initramfs carried the stock hook list with **no `lvm2` hook**:
   `… block encrypt filesystems fsck btrfs-overlayfs` — no `lvm2`. Without it, the initramfs
   can't assemble `volgroup0-lv_root`, so the kernel cannot mount its root → emergency shell.

### Step-by-step fix (Live USB UEFI)

```bash
# 1. Boot from the Arch Linux Live USB (BIOS → Boot Override → UEFI: your USB stick).
#    You should land at:  root@archiso ~ #

# 2. Unlock the disk and start LVM
lsblk -f
cryptsetup luksOpen /dev/nvme0n1p3 cryptroot          # enter LUKS passphrase
vgchange -ay                                          # activate the LVM volume group
ls /dev/mapper/                                     # expect: cryptroot volgroup0-lv_root volgroup0-lv_home

# 3. Mount the system
mount /dev/mapper/volgroup0-lv_root /mnt
mount /dev/nvme0n1p2 /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot/efi

mount --bind /dev  /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys  /mnt/sys
mount --bind /run  /mnt/run

ls /mnt
ls /mnt/boot

# 4. Enter the installed system
arch-chroot /mnt

# 5. Repair the initramfs hooks (the critical part)
#    Omarchy upgrades strip `lvm2`; force it back in.
cat > /etc/mkinitcpio.conf.d/omarchy_hooks.conf << 'EOF'
HOOKS=(base udev plymouth autodetect microcode modconf kms keyboard keymap consolefont block encrypt lvm2 filesystems fsck)
EOF
cat /etc/mkinitcpio.conf.d/omarchy_hooks.conf

# 6. Set the correct boot kernel parameters (cryptdevice)
mkdir -p /etc/kernel
cat > /etc/kernel/cmdline << 'EOF'
cryptdevice=UUID=<luks-uuid>:cryptroot root=/dev/mapper/volgroup0-lv_root rw quiet splash loglevel=3
EOF
cat /etc/kernel/cmdline
#   if unsure of the UUID:
#     cryptsetup luksUUID /dev/nvme0n1p3

# 7. Ensure lvm2 & mkinitcpio are present, and free /boot space
pacman -S --needed lvm2 mkinitcpio
df -h /boot
# if /boot is full, remove the timeshift snapshots that bloat it (common):
rm -rf /boot/timeshift

# 8. Rebuild the initramfs (answer "Y" when asked to run limine-mkinitcpio)
mkinitcpio -P
#   Verify it prints:   Running build hook: [lvm2]

# 9. Unmount and reboot
exit           # exit chroot
umount -R /mnt
reboot
```

---

## Incident 2 — Omarchy 4 update breaks GRUB boot

**Goal**
`omarchy update` in Omarchy 4 re-ran the Limine/EFI pipeline and `omarchy-settings` rewrote
`omarchy_hooks.conf` (dropping `lvm2` again). The active bootloader was **GRUB**, not Limine,
so GRUB could not assemble the root volume and the boot failed.

### Step-by-step fix (revert to GRUB)

The machine was already using GRUB; the fix rejoins GRUB and writes the `cryptdevice`
parameter into both `/etc/default/grub` and the regenerated `grub.cfg`.

```bash
# 1. Unlock LUKS + LVM (as above)
cryptsetup luksOpen /dev/nvme0n1p3 cryptroot
vgchange -ay

# 2. Mount
mount /dev/mapper/volgroup0-lv_root /mnt
mount /dev/nvme0n1p2 /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot/efi

mount --bind /dev  /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys  /mnt/sys
mount --bind /run  /mnt/run

# 3. chroot
arch-chroot /mnt
```

Inside the chroot:

```bash
# 4. Reinstall / ensure GRUB + efibootmgr
pacman -S grub efibootmgr

# 5. Install GRUB into the EFI
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck

# 6. Regenerate GRUB config
grub-mkconfig -o /boot/grub/grub.cfg

# 7. Verify the cryptdevice param made it into grub.cfg
grep -E 'cryptdevice|root=' /boot/grub/grub.cfg | head -5
#   Want to see:   cryptdevice=UUID=40… :cryptroot
#                 root=/dev/mapper/volgroup0-lv_root

# 8. If not present, ensure /etc/default/grub has it, then regenerate
grep GRUB_CMDLINE_LINUX /etc/default/grub
## backup + fix
cp /etc/default/grub /etc/default/grub.bak
sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX="cryptdevice=UUID=<luks-uuid>:cryptroot root=/dev/mapper/volgroup0-lv_root"|' /etc/default/grub
grep GRUB_CMDLINE_LINUX /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg
grep -E 'cryptdevice|root=' /boot/grub/grub.cfg | head -10

# 9. Unmount and reboot
exit
umount -R /mnt
reboot
```

After reboot, in BIOS set the boot option `#1` to the **GRUB** entry (or the
"UEFI OS" / Windows Boot Manager entry above the GRUB line), so the machine boots straight
through GRUB rather than Limine.

---

## Incident 3 — Omarchy update migrated the boot layout to UKI-only (silent GRUB emptying)

### Symptom
A successful `omarchy update` (wrapped) finished with the guard's verify warning:
`grub.cfg missing cryptdevice/root`, `vmlinuz-linux missing`. Root cause inspection showed
`/boot` had **no vmlinuz/initramfs at all** and `/etc/mkinitcpio.d/` presets existed only as
`*.pacsave`.

### Root cause
The Limine stack, across kernel updates + migrations, converted this install to
**UKI-only artifact management**: kernels now live exclusively as
`ESP:/EFI/Linux/omarchy_linux*.efi` (kernel+initramfs+cmdline baked into one EFI binary).
Two consequences collided:

1. Stock `grub-mkconfig` (`10_linux`) scans only `/boot/vmlinuz-*`; with those gone it
   generates an **empty Linux section**. Running our repair's unconditional
   `grub-mkconfig` therefore produced a grub.cfg whose only OS entries were Windows +
   UEFI firmware — regenerating would have bricked the next Linux boot.
2. Plain `mkinitcpio -P` is a no-op here ("No presets found") and its interactive
   "run limine-mkinitcpio now? [Y/n]" follow-up can block a non-interactive hook run.

### Fix applied (this repo)
- `/etc/grub.d/12_omarchy_uki` (installed by `fix-boot-bridge.sh`): a drop-in that
  chainloads the ESP's `omarchy_linux*.efi` binaries — Arch returns to GRUB's menu as
  "Omarchy Linux (UKI)", first among OS entries so GRUB_DEFAULT=0 still boots Arch;
  Windows entry untouched.
- `grub-guard.sh` became **layout-aware**: verify passes on either the classic pair or a
  current UKI set; rebuild auto-selects `limine-mkinitcpio` when presets are absent
  (with `</dev/null` so prompts can't block); `grub-mkconfig` runs only when it will not
  produce an empty menu (plain kernels exist OR the bridge drop-in is installed);
  BootOrder edits move GRUB first while preserving all other entries (an earlier version
  collapsed BootOrder to GRUB alone, orphaning Windows from the order).

### Lesson recorded for the guard design
Never regenerate or validate against assumptions of *one* boot layout — detect which
layout owns the artifacts (classic pair vs UKI-only) and use the tool that owns it.

---

## Incident 4 — UKI built without the LUKS cmdline (unlock params lost in upstream config)

### Symptom
Reboot after a successful (guarded) update: GRUB chainloaded the UKI fine, TPM/SMBIOS
"Volume full" warnings appeared (benign Measured Boot noise — never a boot blocker), then
**emergency shell**. From the emergency shell: `cat /proc/cmdline` showed
`initramfs_async=0 quiet splash loglevel=0 …` — **no `cryptdevice=`, no `root=`**.

### Root cause
The cmdline that ends up inside a UKI is resolved by `limine-entry-tool` from
`/etc/limine-entry-tool.d/*.conf` `KERNEL_CMDLINE[default]+=` lines. Once such a drop-in
exists, **`/etc/kernel/cmdline` and `/proc/cmdline` are ignored** for UKI builds (documented
in upstream's own code). The packaged `/etc/limine-entry-tool.d/omarchy-defaults.conf`
(owned by `omarchy-settings`) carries only quiet/splash params — our unlock params lived in
`/etc/kernel/cmdline`, which was no longer consulted. Every "verified" UKI rebuild was
therefore unbootable on LUKS: earlier guard checks validated the *source text*, never the
**artifact itself**.

### Recovery (executed, Live USB)
```bash
# chroot, then: append unlock params as an entry-tool drop-in line
cp /etc/limine-entry-tool.d/omarchy-defaults.conf /etc/limine-entry-tool.d/omarchy-defaults.conf.bak
cat >> /etc/limine-entry-tool.d/omarchy-defaults.conf <<'EOF'
KERNEL_CMDLINE[default]+=" cryptdevice=UUID=<luks-uuid>:cryptroot root=<root-device> rw"
EOF
limine-mkinitcpio            # answer Y to the limine-mkinitcpio prompt from mkinitcpio -P
# verify the artifact, not the source:
objcopy -O binary --only-section=.cmdline /boot/efi/EFI/Linux/omarchy_linux.efi /dev/stdout | tr -d '\0'
```

### Guard adjustments after this incident (policy: golden-guard + remind)
- **Artifact-truth verification**: `grub-guard` now extracts each UKI's embedded cmdline
  and requires the machine's derived unlock pair; text-file checks alone no longer pass.
- **`ensure_unlock_params()`**: scans every active cmdline source
  (`/etc/kernel/cmdline` + all entry-tool drop-ins) and *appends* missing critical params —
  upstream content is preserved (merge, never clobber).
- **Pre-reboot reminder**: the native hook and wrapper now warn (terminal + desktop
  notification) "DO NOT reboot yet" whenever verification fails or upstream changed boot
  settings, pointing at the `omarchy-boot-rescue` AI skill.
- **Machine-agnostic**: expected params are derived (golden store → `/proc/cmdline` →
  `lsblk -srno` stack walk). No UUID literals in code; works for other ext4+LVM+LUKS users.
- **Policy**: upstream boot changes that keep the critical params are adopted + reported;
  changes that lose them are auto-restored from golden and flagged for review.

---

## Prevention notes

To avoid repeating these repairs:

- **Keep the `lvm2` hook** in `/etc/mkinitcpio.conf.d/omarchy_hooks.conf`. A future
  Omarchy/settings update may rewrite it again — verify after every update.
- Consider running through **GRUB as the only bootloader**: the machine was originally
  using GRUB; Limine is only present because Omarchy installs it. Removing the Limine
  stack (or neutralizing it with a stub that satisfies Omarchy's dependency) stops it
  from re-taking the boot path.
- Watch **`/boot` capacity**; a full `/boot` breaks initramfs rebuilds. `limine/UKI`
  artifacts and `/boot/timeshift` are common space hogs to clear.
- After any Omarchy/Kernel update, confirm the rebuilt initramfs still says
  **`Running build hook: [lvm2]`**, and that `grep cryptdevice|root=` shows the correct
  values for this disk.

## Current-state on-disk config

For reference, the live values after these repairs:

- `/etc/mkinitcpio.conf.d/omarchy_hooks.conf`:
  ```
  HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt lvm2 filesystems fsck)
  ```
- `/etc/kernel/cmdline`:
  ```
  cryptdevice=UUID=<luks-uuid>:cryptroot root=/dev/mapper/volgroup0-lv_root rw quiet splash loglevel=3
  ```
- `/etc/default/grub` `GRUB_CMDLINE_LINUX`:
  `cryptdevice=UUID=<luks-uuid>:cryptroot root=/dev/mapper/volgroup0-lv_root`
- Bootloader order: GRUB is `Boot0000`; Limine still present as `Boot0005`.

---

This document was written from two real incidents: a 3.8 → 4.0 upgrade boot loop and a
post-Omarchy-4-update boot repository failure, both recovered via the Live USB steps above.