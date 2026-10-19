# omarchy-ext4-survivor
### or: how I stopped rebooting into emergency shells and learned to love my update pipeline

> I run [Omarchy](https://omarchy.org) on a machine whose boot layout predates Omarchy's
> ISO. Four broken boots, three Live-USB rescues, one mysterious binary called `chsnap`
> that doesn't exist anywhere — and the guard I ended up building so it never happens again.

If you installed Omarchy the normal way (the ISO, btrfs, the works), you can stop reading.
Stock Omarchy already takes care of you. This is a story about the other path.

## Contents

1. [The setup, or: how I got here](#the-setup-or-how-i-got-here)
2. [Act I: the upgrade that half-happened](#act-i-the-upgrade-that-half-happened)
3. [Act II: the trilogy](#act-ii-the-trilogy)
4. [Act III: the UKI plot twist](#act-iii-the-uki-plot-twist)
5. [Enter: the bouncer](#enter-the-bouncer)
6. [What a run looks like now](#what-a-run-looks-like-now)
7. [For anyone else on this path](#for-anyone-else-on-this-path)
8. [The cheat sheet](#the-cheat-sheet)
9. [Thanks](#thanks)

## The setup, or... How I got here

Last year I did the thing you're told never to do: I hand-installed Arch Linux. Laid it
out exactly how I wanted — **LUKS** encryption on the NVMe, **LVM** on top of that
(`volgroup0`, because naming things is hard), **ext4** filesystems, **GRUB** as the
bootloader so I could dual-boot Windows, classic `vmlinuz` boot. It was mine, it was
stable, and I understood every layer of it.

Then I discovered Omarchy — **very early, before there was an official ISO**, before
btrfs became the house filesystem, before "quattro" was a word anyone used. Installing
it on top of my hand-rolled Arch felt clever at the time. And it was! It ran great for
a year.

Here's the honest part: Omarchy 4 is new. It's mid-transformation from 3.8, and its
update pipeline is written around the ISO layout it ships today. My machine joined
before any of that existed, so the pipeline was never built with my boot layout in
mind — which means the boot-critical pieces are mine to maintain. That's not a complaint;
it's the deal you sign up for when you hop on early. But "the deal you signed up for"
still means the update sometimes rewrites a boot config back to btrfs-shaped, and the
machine — a perfectly valid Arch install that two valid configurations *both* claim to
own — disagrees at the worst possible moment: right before the reboot.

This is a story about that disagreement. Eventually it got fun. Genuinely.

## Act I: The upgrade that half-happened

The Omarchy 4 upgrade opens with a warning that it's a one-way street. What it doesn't
mention is that the street might dead-end halfway.

Mine did. The upgrade walked through its checklist and died at a step called *snapshot
retention*, trying to create a btrfs Snapper config on my ext4 root. The error:

```
Creating config failed (/sbin/chsnap not installed).
```

Reader, I looked. `chsnap` is not in the repos. It's not in the AUR. It's not on my
disk. As far as I can tell it barely exists on the internet. The upgrade wanted a binary
I cannot obtain, for a filesystem I do not have. (To be clear: on a btrfs machine this
step is exactly right. Mine just isn't one.)

Fine. I did the responsible thing: modified the upgrade script to skip that stage, and
finished the migration by hand. I went to bed feeling victorious.

I woke up to an emergency shell.

## Act II: The Trilogy

Turns out the migration had also rebuilt my initramfs **without the `lvm2` hook** — which
makes sense for a btrfs root; you don't need LVM when your root is a subvolume. My root
is an LVM logical volume sitting on LUKS. No `lvm2` hook in the initramfs means the
kernel wakes up, can't assemble its volume group, and asks the emergency shell what
exactly it's supposed to do now.

Live USB. Unlock LUKS. Activate LVM. Mount everything. Chroot. Add `lvm2` back to the
hooks. Rebuild. Reboot. Fixed.

Fixed until the next routine `omarchy update`, which re-did the whole thing: pulled in
Omarchy's own Limine boot stack as dependencies, rewrote my boot configuration again,
stripped the hook again. Emergency shell. Live USB. Same twenty commands, now from
muscle memory.

At this point I had a choice: keep doing this forever, or automate myself out of it.

## Act III: The UKI plot twist

Automating it taught me more about how Omarchy 4 boots than I ever wanted to know —
and just in time, because the updates kept finding *new* ways to surprise me.

The good news: Omarchy 4 ships its kernels as **UKIs** — Unified Kernel Images, where
the kernel, the initramfs, and the kernel command line are all baked into a single
`.efi` file. Neat technology. The bad news: the file that supplies the *command line*
quietly changed. My LUKS unlock parameters lived in `/etc/kernel/cmdline`, which the
build tool stopped reading the moment a different config file existed. The UKIs got
rebuilt — successfully! Verified! — without `cryptdevice=` in them at all. The kernel
came up, couldn't unlock its own disk, emergency shell.

The same night, I also discovered that `/boot` had been emptied of plain kernels, the
mkinitcpio presets had retired themselves to `.pacsave` files, and a freshly regenerated
GRUB config contained **zero Linux entries** — GRUB's generator scans for kernel files
that no longer exist. Also, the TPM kept yelling "SMBIOS Volume full" during boot, which
turned out to be completely harmless and took me an embarrassing amount of time to
confirm.

None of this was malice or sloppiness — it's a young, fast-moving distro transforming
from 3.8 into something new, and the new boot pipeline maintains *its* layout faithfully.
My machine just isn't that layout yet. But "everyone's failures are reasonable" is cold
comfort at 00:47 with an emergency shell and a kernel that can't find its own root.

## Enter: The bouncer

So I built a bouncer for my bootloader.

**`omarchy update` still works. It's just wrapped now.** Four stages:

```
[stage 1/4] snapshot my boot config        ← fail-closed: no snapshot, no update
[stage 2/4] the real update                ← streams live, exactly like vanilla
[stage 3/4] repair pass                    ← always runs, success or failure
[stage 4/4] summary                        ← reboot only offered if boot verifies
```

The repair pass is the golden guard. It knows my layout, it knows which files own the
kernel cmdline in whichever boot mode I'm in, and after every update it:

- puts the `lvm2` hook back if a rebuild stripped it,
- heals the LUKS unlock parameters if they went missing — by *appending* them, never
  clobbering whatever new thing the update brought in,
- rebuilds boot images with the tool that actually works (`limine-mkinitcpio` for UKIs,
  plain `mkinitcpio -P` only where presets are real), detecting failures instead of
  trusting them,
- and — the one I'm proudest of — **checks the artifact, not the config**: it extracts
  the cmdline embedded inside the built UKI binary and verifies the LUKS parameters are
  physically in there. Because I once shipped "verified" boot images that couldn't boot,
  and I refuse to let that happen silently again.

If something can't be fixed, the guard goes loud: terminal warning, desktop
notification, *DO NOT REBOOT YET*, and a pointer to the fix — or to your AI assistant,
which ships with a skill (`omarchy-boot-rescue`) that knows this entire architecture,
all the incidents, and the recovery playbook.

And when the update *improves* something — adds a security param, reworks the pipeline —
the guard adopts it (as long as the machine still boots), diffs it for me, and asks me
to review. The bouncer checks IDs; it doesn't choose my guests.

## What a run looks like now

```
[stage 1/4] prepare boot config snapshot
[stage 2/4] omarchy update                ← live output, obscured sudo, nothing spooky
[stage 3/4] grub-guard repair (always runs)
[stage 4/4] Update completed successfully. Boot config verified.
             Reboot to finish applying updates?
```

Yes → reboots into the new kernel. No → reboots later. Either way, it boots.

It's been through several real update cycles now, including one where the pipeline
tried to regenerate an empty GRUB menu and another where a "verified" rebuild had no
unlock parameters — both caught, both repaired in-band, zero Live USBs since. The
guard's incident log has gotten longer than this README; the full write-ups live in
[`docs/migration-update-fix.md`](docs/migration-update-fix.md) if you enjoy
autopsies.

## For anyone else on this path

This is a personal fix, generalized exactly one notch: to the class of machines that
look like mine — **manually-installed Arch, early Omarchy opt-in, ext4 + LVM over LUKS,
GRUB, non-btrfs**. That's a narrow club, and odds are you're not in it. But if you are,
the setup is:

```bash
git clone https://github.com/nizkl89/omarchy-ext4-survivor.git
cd omarchy-ext4-survivor
sudo bash setup.sh     # read it first; it's short and idempotent
```

No hardcoded UUIDs or volume names — the guard derives everything from your own disks
at runtime. And if you're reading this mid-emergency, skip straight to
[`docs/usb-rescue.md`](docs/usb-rescue.md): the Live-USB ritual, written the way I wish
someone had handed it to me at 1 AM.

## The cheat sheet

```bash
bin/grub-guard.sh --check          # read-only verify
bin/grub-guard.sh --repair         # heal + rebuild + verify
bin/grub-guard.sh --explain-diff   # what did the update change in my boot config?
bin/grub-guard.sh --accept-current # reviewed it; bless it as the new baseline
bin/grub-guard.sh --restore        # last resort: replay golden + rebuild
```

The [`omarchy-boot-rescue`](skills/omarchy-boot-rescue/SKILL.md) skill teaches your AI
assistant the whole architecture: how Omarchy 4 boots, how it differs from v3, the
failure playbook from every incident, and the guardrails (never trust a config file
when you can verify the artifact).

## Thanks

To the Omarchy folks for a genuinely fun distro that I *chose to join early* — early
means the rough edges are mine to polish too, and one of my fixes went back upstream as
[PR #7403](https://github.com/basecamp/omarchy/pull/7403). See also
[issue #6683](https://github.com/basecamp/omarchy/issues/6683) and
[PR #6730](https://github.com/basecamp/omarchy/pull/6730). And to whoever decided
emergency shells should have a full VM behind them: that prompt has seen things.

## License

[MIT](LICENSE) — do whatever you want. The Snapper fix derives from
[basecamp/omarchy](https://github.com/basecamp/omarchy) (also MIT); attribution noted
in the file.
