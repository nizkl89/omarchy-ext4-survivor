# Boot Guard — GRUB-safe updates for ext4 + LVM + LUKS

One wrapper + one hook that keep this machine bootable through `omarchy update`,
even when Omarchy's Limine/UKI/btrfs-oriented pipeline rewrites the initramfs hook
list (dropping `lvm2`) or boot artifacts GRUB depends on.

## Files

| Path | Purpose |
|---|---|
| `bin/grub-guard.sh` | Core logic: `--capture`, `--repair`, `--check`, `--restore` |
| `bin/omarchy` | Update wrapper (installed to `/usr/local/bin/omarchy`); 4 stages |
| `hooks/post-update.d/00-grub-guard.sh` | Native Omarchy post-update hook → `grub-guard --check` |
| `backups/<date>/` | repo golden boot config (git-tracked) |
| `/var/lib/omarchy-boot-guard/` | system golden boot config (root) |

## How it works

### Wrapper (`omarchy` in `/usr/local/bin`)

Runs in 4 stages whenever you type `omarchy update` (or anything that resolves to `/usr/local/bin/omarchy`):

1. `grub-guard --capture` — validate current boot config and seed the golden store. **Aborts the update if no known-good baseline can be produced.**
2. `omarchy-update -y` — the real updater, unattended, with full tty passthrough (live output stream, obscured sudo prompts). A `gum` stub is prepended to PATH for the updater's duration so that every `gum confirm` auto-declines — this is what defers the built-in reboot prompt until after stage 3 without starving stdin. Expect a second obscured sudo prompt inside the updater: it re-execs into a fresh pty with its own ticket context.
3. `grub-guard --repair` — always runs, success or failure: re-add `lvm2`, rebuild initramfs, regenerate GRUB, prune Limine.
4. Summary + exit code of the update. Reboot is offered **only** on success, after repair has verified boot config.

Every stage writes a line to `~/.local/state/omarchy/update-wrapper.log` and prints to the terminal.

### Native hook

`omarchy-hook post-update` runs `00-grub-guard.sh` (read-only `--check`) after a *successful*
update even if that update bypassed the `/usr/local/bin` wrapper (menu/system-tray update
paths). It never rebuilds anything — it just verifies and alerts.

### grub-guard commands (manual)

```bash
grub-guard --capture    # (re)seed golden boot config (system + repo)
grub-guard --repair     # re-add lvm2, mkinitcpio -P, grub-mkconfig, prune Limine
grub-guard --check      # read-only verify
grub-guard --restore    # replay golden config + repair (from chroot/emergency)
```

## Known-good seed baseline

Golden baseline criteria are **boot-layout dependent** (`layout_issues()`):

- **classic** — `/etc/default/grub` + `grub.cfg` both carry `cryptdevice=`/`root=`, and
  `/boot/vmlinuz-linux` + `/boot/initramfs-linux.img` exist.
- **uki** (this machine's current layout) — the entry-tool cmdline sources
  (`/etc/limine-entry-tool.d/*.conf`, or `/etc/kernel/cmdline` when no drop-in exists)
  carry `cryptdevice=`/`root=`, ESP holds current
  `omarchy_linux*.efi` (each verified at the **artifact** level), **and** `grub.cfg`
  contains the `omarchy_uki-` chainloader
  entries (guards against re-blessing a regenerated empty menu).

Capture refuses any state that fails these checks (fail-closed), so a wrapper update can
never start without a known-good baseline.

Then seed:

```bash
sudo env OMARCHY_PATH= bash <repo>/bin/grub-guard.sh --capture
```

(Do not seed until the duplicate is gone — the golden baseline must be the clean state you
want to restore to.)

## Recovery from a broken update (ISO / emergency shell)

If an update still breaks boot the recovery path is:

```bash
# from the running/broken system or a chroot:
<repo>/bin/grub-guard.sh --restore
```

`--restore` replays the golden `default-grub`, `omarchy_hooks.conf`, and `kernel-cmdline`,
then runs `repair_hooks_conf` + initramfs rebuild (`limine-mkinitcpio`, or `mkinitcpio -P`
when presets exist) + a preconditioned `grub-mkconfig`.

From a Live USB, the same recipe as `docs/migration-update-fix.md` applies.

## Installation (once, with sudo)

```bash
# 1. wrapper into /usr/local/bin (PATH already resolves it before /usr/bin)
sudo ln -s <repo>/bin/omarchy /usr/local/bin/omarchy

# 2. native hook for non-wrapper update paths (already created in ~/.config/omarchy/hooks/post-update.d/)

# 3. dedupe cryptdevice (above), then seed golden store
sudo bash <repo>/bin/grub-guard.sh --capture
```

### BootOrder safety history

Two `prune_limine` defects were found and fixed after they briefly degraded the machine's
UEFI boot order:

1. **Order collapse** — an early build called `efibootmgr -o <GRUB-num>` outright, dropping
   every other NVRAM entry (Windows survived only via GRUB's own menu). Restore command used:
   `sudo efibootmgr -o 0000,0003,0005` (GRUB → Windows → Limine; adjust numbers to your
   `efibootmgr` listing).
2. **Malformed write attempt** — when GRUB already led BootOrder, the rebuild assembled a
   bare trailing comma (`"0000,"`); firmware rejected it (fail-safe held), but the guard now
   sanity-gates before writing: refuses to touch NVRAM unless the value matches
   `^[0-9A-Fa-f]{4}(,[0-9A-Fa-f]{4})*$`, no-ops when GRUB is already first, and always
   preserves all other entries.

Current behavior matrix (sandbox-verified): GRUB-first → no-op; GRUB mid-list → reorder with
full preservation; unreadable/malformed BootOrder → refuse without writing.

### GRUB theme icons (minegrub)

Format matters: theme icons must be **8-bit TrueColorAlpha** PNGs (`PNG32:` in
ImageMagick) — 16-bit grayscale PNGs fail GRUB's loader and entries fall back to
generic icons. Generated with ImageMagick: compose the 801×96 transparent canvas
(logo left, title + tagline right in JetBrains Mono), then
`magick composed.png PNG32:omarchy.png`.

The minegrub theme renders each menu entry with an 801×96 PNG from
`icons/<class>.png`, where `<class>` is the entry's first `--class`. The bridge emits
`--class arch` first, so both UKI entries pick up the theme's own `arch.png` (Arch
logo + baked description — the same one the stock theme shows for Arch installs).
Custom icons: drop any 801×96 8-bit RGBA PNG into the theme's `icons/` dir and put
its class first in the bridge (`omarchy.png` wordmark alternates live in
`etc/grub-theme-icons/`). Note: icon PNGs must be 8-bit TrueColorAlpha — 16-bit
grayscale fails GRUB's loader and entries fall back to generic icons.

### Hybrid boot state (presets restored + UKI-only artifacts)

After a Live-USB recovery that ran `pacman -S linux linux-lts` (or restored presets from
`.pacsave`), the machine can end up in a hybrid state: `/etc/mkinitcpio.d/*.preset` exist
again but reference plain `/boot/vmlinuz-*` files that UKI-only kernel packages never
install. The guard handles this: `limine-mkinitcpio` is preferred whenever present (it
owns UKI generation), `mkinitcpio -P` is only a fallback, rebuild failures are detected
(exit status + build-scoped `[lvm2]` confirmation — stale log lines from earlier runs
cannot false-positive anymore), and pass 2 switches to the alternate tool if pass 1's
tool failed. Optional cleanup to silence the harmless preset errors:
`sudo rm /etc/mkinitcpio.d/*.preset`.

### Move-safe pointer

All installed links hang off a single stable pointer: `~/.config/omarchy-ext4-survivor/repo` -> the repo folder. The rc-file function, hook, skills, and wrapper symlink all resolve through it, so moving or renaming the repo folder only requires relinking that one pointer (or re-running `setup.sh`, which maintains it).

## Notes

- The wrapper's stage 2 passes `-y` by design; interactive package-conflict questions fall
  back to Omarchy's unattended conflict handler (safe).
- The wrapper always offers a final reboot after a successful repair; on failure it does
  not reboot, so you can review the log.