# Manual Live-USB repair session

You know the drill by now: coffee, the ISO USB, the LUKS passphrase you could type
asleep (and probably have). This is the full ritual written out as a cheat sheet —
generic enough for any ext4+LVM+LUKS machine, specific enough to paste your way out of
an emergency shell. Incident-specific context lives in
[`migration-update-fix.md`](migration-update-fix.md); if `omarchy-ext4-survivor` is
installed on the mounted system, the automated path is just
`bash /path/to/omarchy-ext4-survivor/bin/grub-guard.sh --repair` inside the chroot.

> Adapt device names to your machine: this guide uses `/dev/nvme0n1p3` (LUKS),
> `/dev/mapper/volgroup0-lv_root` (root), `/dev/nvme0n1p2` (`/boot`),
> `/dev/nvme0n1p1` (`/boot/efi`).

## TL;DR flowchart

emergency shell → Live USB → unlock → mount → chroot → **hooks have `lvm2`?** →
**cmdline has `cryptdevice=`/`root=` in the file my boot mode reads?** → rebuild with
`limine-mkinitcpio` (UKI) or `mkinitcpio -P` (classic) → **verify the artifact** → reboot.

## 1. Boot the ISO

Boot an Arch Linux ISO (UEFI). You land at `root@archiso ~ #`.

## 2. Unlock and activate

```bash
lsblk -f                                       # confirm disk layout
cryptsetup luksOpen /dev/nvme0n1p3 cryptroot   # your LUKS passphrase
vgchange -ay                                   # activate the LVM volume group
ls /dev/mapper/                                # expect: cryptroot, volgroup0-lv_root, volgroup0-lv_home
```

## 3. Mount and chroot

```bash
mount /dev/mapper/volgroup0-lv_root /mnt
mount /dev/nvme0n1p2  /mnt/boot
mount /dev/nvme0n1p1  /mnt/boot/efi
for d in dev proc sys run; do mount --bind /$d /mnt/$d; done
arch-chroot /mnt
```

## 4. Diagnose: which boot mode is this machine in?

The fix differs by layout. Run all three checks:

```bash
ls /boot/vmlinuz-* 2>/dev/null && echo "CLASSIC: plain kernels present"
ls /boot/efi/EFI/Linux/omarchy_linux*.efi 2>/dev/null && echo "UKI: unified images present"
ls /etc/mkinitcpio.d/*.preset 2>/dev/null
```

- **Classic** — plain kernels + presets; GRUB loads them directly.
- **UKI** — only `omarchy_linux*.efi` on the ESP; presets may be gone or `.pacsave`.
- Both can exist (hybrid) — repair the UKIs; they are what actually boots.

## 5. Fix A — initramfs hooks (the `lvm2` hook)

```bash
grep lvm2 /etc/mkinitcpio.conf.d/omarchy_hooks.conf || cat > /etc/mkinitcpio.conf.d/omarchy_hooks.conf <<'EOF'
HOOKS=(base udev plymouth autodetect microcode modconf kms keyboard keymap consolefont block encrypt lvm2 filesystems fsck)
EOF
```

If `omarchy_hooks.conf` doesn't exist, check `HOOKS=` in `/etc/mkinitcpio.conf` directly.
Missing `lvm2` here is the #1 cause of emergency shells on this layout.

## 6. Fix B — kernel cmdline unlock params

The parameters must exist in the file that your boot mode actually reads.

**Derive them from your own disks (no guessing):**

```bash
root=$(findmnt -rno SOURCE /)
lsblk -srno TYPE,NAME,UUID "$root"
# the row with TYPE=crypt gives the mapper name; the row BEHIND it gives the LUKS UUID
# (cross-check: cryptsetup luksUUID /dev/nvme0n1p3)
```

**UKI mode** — `/etc/limine-entry-tool.d/*.conf` files with `KERNEL_CMDLINE[default]+="
…"` lines override everything else:

```bash
grep -rl 'KERNEL_CMDLINE' /etc/limine-entry-tool.d/ | xargs grep -L 'cryptdevice='
# any file listed is missing the unlock params; append:
echo 'KERNEL_CMDLINE[default]+=" cryptdevice=UUID=<luks-uuid>:<mapper> root=<root> rw"' \
  >> /etc/limine-entry-tool.d/omarchy-defaults.conf
```

**Classic mode** — `/etc/default/grub` `GRUB_CMDLINE_LINUX*` and/or `/etc/kernel/cmdline`:

```bash
grep cryptdevice /etc/default/grub /etc/kernel/cmdline
# missing? append: cryptdevice=UUID=<luks-uuid>:<mapper> root=<root>
```

## 7. Fix C — rebuild the boot images

```bash
ls /etc/mkinitcpio.d/*.preset >/dev/null 2>&1 && mkinitcpio -P || limine-mkinitcpio
```

- On UKI machines `mkinitcpio -P` errors with "No presets found" and offers to run
  `limine-mkinitcpio` — answer **Y**, or call `limine-mkinitcpio` directly.
- Watch for `Running build hook: [lvm2]` — if it never appears, Fix A wasn't applied.

## 8. Verify before you reboot

The cmdline is INSIDE the UKI binary on UKI machines — check the artifact, not the
config:

```bash
objcopy -O binary --only-section=.cmdline /boot/efi/EFI/Linux/omarchy_linux.efi /dev/stdout | tr -d '\0'
# must contain cryptdevice= and root=
```

Classic mode:

```bash
grep cryptdevice /boot/grub/grub.cfg | head -2
```

## 9. GRUB (only if its menu lost Linux)

On UKI machines a bare `grub-mkconfig` generates an empty Linux section (it scans
`/boot/vmlinuz-*`, which don't exist). Only regenerate if a chainloader bridge exists:

```bash
test -x /etc/grub.d/12_omarchy_uki && grub-mkconfig -o /boot/grub/grub.cfg
```

If the menu still lacks Linux and you need GRUB to chainload the UKIs, create
`/etc/grub.d/12_omarchy_uki` — see `fix-boot-bridge.sh` in this repo for the template.

## 10. Out

```bash
exit          # exit chroot
umount -R /mnt
reboot
```
