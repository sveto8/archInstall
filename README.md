----------

NOTE - This is a hobby project created primarily for my personal needs. 

----------


# Arch Linux: LUKS2 + Btrfs + Snapper + DE + apps install scripts

Dialog (ncurses) scripts that take a PC from an Arch ISO to an **encrypted, snapshotted
desktop with my applications**. Every script asks all its questions first, shows one
summary, and only then runs unattended with live output and a log file.

| Step | Script | Run as | What it does |
|---|---|---|---|
| 0 | `archInstall.sh` | root, Arch ISO | Wipes one disk and sets up ESP + `/boot` + LUKS2 with Btrfs (`@`, `@home`, `@snapshots`). Installs the base system, GRUB, user, locale/keymap, zram; optional Wake-on-LAN, Wi-Fi carry-over and a desktop. |
| 1 | `setupAfterInstall.sh` | root, first boot | Snapper + snap-pac + grub-btrfs, GRUB and Plymouth themes, os-prober for dual boot, and **bootable read-write snapshots** with matching kernels (pick one in GRUB after a bad update). |
| 1.5 | `installDE.sh` | root | GNOME, KDE Plasma or XFCE (full/minimal) with GPU drivers, PipeWire, Bluetooth, dark theme, icon and cursor themes. |
| 2 | `installApps.sh` | normal user | Builds `yay`, installs a base app set, then per-package checklists: optional (LACT, CoolerControl, sudo fingerprint, office suites), work, VPN (NetworkManager plugins + Check Point client), printer/scanner, office/fonts, multimedia, system maintenance (firmware, NTFS, SSD TRIM, optional `ufw` firewall) and a free-text box. Services, PAM, mDNS and firewall ports are touched only for what you picked. |
| - | `arch-manager.sh`, `lib.sh` | - | Optional menu that downloads and runs the scripts; shared dialog helpers (sourced, never run). |

**Quick start** (on the Arch ISO, network up):

```bash
curl -O https://raw.githubusercontent.com/sveto8/archInstall/main/arch-manager.sh
chmod +x arch-manager.sh && ./arch-manager.sh
```

**Order:** 0 → reboot → 1 and 1.5 (either order) → 2. Layout: `/efi` (FAT32), `/boot` (ext4),
LUKS2 → Btrfs; only `/` is snapshotted, `/home` is not.

**Safety:** nothing on disk changes before the typed `WIPE` (script 0) or the summary
confirmation (others). Edited system files get a backup, scripts can be re-run, and long
texts or lists scroll instead of being cut off. Hobby project, tested only on my own
machines (AMD desktop, Intel laptop) -- try it in a VM first.

---

## Detailed documentation

Contents: [Getting the scripts](#getting-the-scripts-onto-the-arch-iso) ·
[1. archInstall](#1-archinstallsh--from-the-arch-iso) ·
[2. setupAfterInstall](#2-setupafterinstallsh--after-first-boot-as-root) ·
[3. installDE](#3-installdesh--on-the-installed-system-as-root) ·
[4. installApps](#4-installappssh--at-the-desktop-as-your-regular-user) ·
[arch-manager](#arch-managersh--optional-dialog-menu) ·
[Booting a snapshot](#booting-a-snapshot-after-a-bad-update) ·
[Themes](#grub-themes) · [lib.sh](#libsh--shared-helpers) · [Notes](#notes)

Four scripts that together take a machine from an Arch ISO boot to a
fully configured, encrypted, snapshotted Arch install with GRUB (+
theme), grub-btrfs, Snapper, a Plymouth boot theme, a desktop
environment, and a personal application set — plus a menu-driven
manager that downloads and runs them for you, and a small shared
library (`lib.sh`).

**Every script uses a `dialog` (ncurses) UI**: menus, checklists,
password boxes and yes/no questions instead of typed prompts, with live
output of the long-running steps shown in a dialog box (and saved to a
log file). Keys: arrows to move, `SPACE` toggles a checkbox, `ENTER`
confirms, `ESC`/Cancel aborts (nothing is changed on cancel).

```
archInstall.sh        Phase 0   — run from the Arch ISO live environment
                                  (optionally installs the desktop right away)
setupAfterInstall.sh  Phase 1   — run on the new system, after first boot
installDE.sh           Phase 1.5 — installs a desktop environment (also called
                                  by archInstall.sh, non-interactively)
installApps.sh         Phase 2   — run as your regular user, once at the desktop
arch-manager.sh        optional  — dialog menu that downloads + runs the four above
lib.sh                 shared    — dialog/log helpers sourced by all of the above
```

`setupAfterInstall.sh` and `installDE.sh` can be run in either order —
neither depends on the other. `lib.sh` is **sourced**, never run
directly; every script downloads it automatically if it isn't next to
it.

## Resulting layout

```
/efi         unencrypted ESP (FAT32)
/boot        unencrypted (ext4)

LUKS2
 └── Btrfs
      ├── @             -> /
      ├── @home        -> /home
      └── @snapshots   -> /.snapshots
```

`/home` is intentionally **not** managed by Snapper — only `/` is snapshotted.

## Getting the scripts onto the Arch ISO

The live environment has network access (`iwctl` for Wi-Fi, wired usually
works out of the box via dhcpcd). Download the raw file directly — not
the GitHub web page URL (`github.com/.../blob/...`), which returns HTML,
not the script:

```bash
curl -O https://raw.githubusercontent.com/sveto8/archInstall/main/arch-manager.sh
chmod +x arch-manager.sh
./arch-manager.sh
```

**Important:** everything is downloaded from the `main` branch of the repo,
so **all files — including the new `lib.sh` — must be pushed to GitHub**
first. A missing file shows up as `HTTP 404` in the error message
(`000` = no network / DNS problem). If you want to run without GitHub (or
test local changes), put `arch-manager.sh`, `lib.sh` and the four scripts
**in the same folder**: the manager always prefers local copies (next to
itself, in `scripts/`, or in `/archInstall/scripts`) over downloading, and
every script finds `lib.sh` next to itself.

The manager fetches `lib.sh` and the four phase scripts by itself (the
first run of any script downloads a missing `lib.sh`; `dialog` is
installed automatically if it's missing — on the live ISO that needs the
network, which you need anyway).

Rule of thumb: `github.com` → `raw.githubusercontent.com`, drop `/blob/`,
keep `branch/path` as-is.

**Using a fork or another branch:** the repository URL is defined once and
can be overridden from the environment — no script has to be edited:

```bash
ARCH_REPO_URL=https://raw.githubusercontent.com/<user>/<repo>/<branch> ./arch-manager.sh
```

`arch-manager.sh`, `lib.sh` (`REPO_RAW_URL`) and every script's `lib.sh`
bootstrap honour `ARCH_REPO_URL`; the theme archives, icon/cursor archives
and the theme listing all derive from it too.

If the repo is private, add an auth header with a
[personal access token](https://github.com/settings/tokens) (never paste
real tokens into chat, logs, or commit them — treat a leaked token as
compromised and revoke it immediately):

```bash
curl -H "Authorization: token <GITHUB_PAT>" \
     -O https://raw.githubusercontent.com/sveto8/archInstall/main/arch-manager.sh
```

If the repo is public (recommended for this use case — nothing in these
scripts is sensitive), no auth header is needed.

## Order of operations

### 1. `archInstall.sh` — from the Arch ISO

Wipes and partitions the target disk, sets up LUKS2 + Btrfs, and
installs a bootable base system, optionally with a desktop environment.

**All questions come first, then one summary and the typed `WIPE`
confirmation — after that it runs unattended** (live output in a dialog
box, log saved to `/root/archInstall.log` and copied to the new system's
`/root/`). Nothing on disk changes before the `WIPE` confirmation.

Questions, in this order:

1. **Disk** — a menu of the disks found (size, model, a note if it has
   mounted partitions). The disk the live USB booted from and `zram`
   devices are never offered. If leftover mounts from an interrupted run
   exist, it offers to unmount them and close `cryptroot`
2. **Hostname, timezone, console keymap(s), language, regional formats**
   — input boxes pre-filled with the defaults from the config block
   (`blackbox`, `Europe/Zagreb`, `us`) and validated (hostname syntax, the
   timezone must exist in `/usr/share/zoneinfo`, every keymap must be in
   `localectl list-keymaps`), so the same script gives each machine
   (laptop, desktop) its own name. Several keymaps can be given
   (`us,croat`): you then pick the **primary** one (`KEYMAP=` /
   `rd.vconsole.keymap=`), the other becomes the toggle layout
   (`KEYMAP_TOGGLE=`). Two menus follow: the **system language** (`LANG`:
   English or Croatian) and, independently, the **regional formats**
   (dates, numbers, currency, measurements, paper: `LC_TIME`,
   `LC_NUMERIC`, `LC_MONETARY`, `LC_MEASUREMENT`, `LC_PAPER` in
   `/etc/locale.conf`; also handed to `installDE.sh` for GNOME/KDE). The
   formats menu offers "same as the language" plus Croatian, English US and
   German; a locale is never listed twice, whichever language you chose
3. **User, superuser, password — one after another:** username (empty =
   skip; validated: lowercase, digits, `_`/`-`, not `root`), *"should this
   user be a superuser (wheel + sudo)?"* (default Yes), then the password
   (asked twice in a password box)
   - with a sudo user, the **root account is locked** (`passwd -l`) —
     a fresh Arch root account otherwise has an *empty* password
   - without one, you set a root password instead, so something can
     still log in with admin rights
4. **LUKS passphrase** — asked twice; it is passed to `cryptsetup` via
   stdin (`--key-file=-`, `--batch-mode`), so there are no interactive
   cryptsetup prompts in the middle of the install. **Keymap caveat:** you
   type it now with the live ISO's layout (normally US) but at every boot
   with the primary keymap chosen above; if that is not `us`, the dialog
   warns you — use only characters that sit on the same key in both
   layouts (avoid `Y`/`Z` and symbols)
5. **Hardware clock** — `UTC` (Linux default) or `local` (pick this if you
   dual-boot Windows, which assumes the RTC is local time)
6. **Wake-on-LAN** (default No) — if yes, the wired interface is
   auto-detected from `/sys/class/net` (Wi-Fi excluded; a menu if there
   are several) and, when `ethtool` is available on the ISO, whether it
   reports magic-packet (`g`) support is noted (informational only)
7. **Wi-Fi carry-over** — if the live ISO has saved networks
   (`/var/lib/iwd/*.psk`, i.e. you connected with `iwctl`), asks (default
   Yes) whether to copy them to the new system. A connection made on the
   live ISO lives only in its RAM, so without this the installed system
   boots with NetworkManager but no saved network and no internet for
   the next scripts. They are written as NetworkManager profiles
   (`/etc/NetworkManager/system-connections/wifi-N-<ssid>.nmconnection`,
   mode 600, WPA/WPA2-PSK, autoconnect). Not carried over: open
   networks, 802.1X/enterprise and SSIDs containing `;`; WPA3-only
   networks are written as WPA-PSK and won't connect — use `nmtui` after
   reboot for those
8. **Desktop environment** — *None (default)*, GNOME, KDE Plasma or XFCE,
   then full or minimal. Only offered when a regular user is being
   created (the desktop is configured for that user)
9. **Summary** (scrollable) → type **`WIPE`** (all caps) to continue

Then, unattended:

1. Partitions the disk: ESP → `/efi`, ext4 → `/boot`, LUKS2 → Btrfs
   (partition names follow the device name: a name ending in a digit gets
   a `p` — `nvme0n1p1`, `mmcblk0p1` — otherwise none — `sda1`, `vda1`);
   stale signatures of a previous install are wiped from the new
   partitions as well
2. Creates the `@`, `@home`, `@snapshots` subvolumes and mounts them
   (`compress=zstd:3`, `noatime`, `space_cache=v2`; the `ssd` option is
   added only when `/sys/block/<disk>/queue/rotational` says the disk is
   non-rotational). `genfstab`'s numeric `subvolid=` pins are removed from
   `/etc/fstab` (only `subvol=/<name>` stays) — with a `subvolid` in the
   `/` entry, a snapshot booted from grub-btrfs would be overlaid by the
   original `@` and the root subvolume the kernel command line selects would be ignored
3. Ranks pacman mirrors with `reflector` (non-fatal if it fails — the
   disk is already formatted, so it just falls back to the default
   mirrorlist). If `reflector` is missing on the ISO it is installed with
   `pacman -Sy`: a stale package database makes a plain `-S` fail with 404s
4. `pacstrap`s the base system: `base base-devel linux linux-firmware
   btrfs-progs cryptsetup grub efibootmgr sudo networkmanager
   wpa_supplicant vim git zram-generator dialog`, plus the microcode
   package for your CPU and `ethtool` if WOL was chosen
5. Writes the Wi-Fi profiles (if chosen), creates the user, sets the
   passwords with `chpasswd` (stdin — nothing interactive, nothing on a
   command line), locks root if applicable. The `wheel` rule goes into
   `/etc/sudoers.d/10-wheel` (validated with `visudo -c`; if validation
   fails the install **aborts**, because root is locked and the system
   would otherwise be unusable)
6. Chroot configuration: hostname, timezone, locales (every entry of the
   `LOCALES` array in the config block — default `en_US.UTF-8` +
   `hr_HR.UTF-8`; `LOCALE` is the primary one and is always generated),
   keymap, hardware-clock mode (a missing RTC in a VM is a warning, not an
   error), `/etc/hosts`, enables
   NetworkManager, `pacman.conf` tweaks (`VerbosePkgLists`, `ILoveCandy`),
   `systemd-timesyncd` (NTP; the *hardware clock* dialog
   only chooses UTC vs local for the RTC and is independent of NTP), zram swap,
   a templated `wol@.service`
   (`ethtool -s %i wol g`, re-applied on **every** boot because most NIC
   drivers reset it) enabled for the detected interface, a minimal
   systemd + `sd-encrypt` `mkinitcpio.conf`, GRUB install + config (the
   GRUB `--target` follows the firmware: `x86_64-efi`, or `i386-efi` on
   32-bit UEFI). On SSD/NVMe disks `rd.luks.options=discard` is added to
   the kernel command line (`LUKS_ALLOW_DISCARDS="yes"` in the config
   block): TRIM only passes through dm-crypt when discards are allowed,
   otherwise `fstrim.timer` would silently do nothing on the encrypted
   root. Trade-off: it reveals which blocks are unused (not their
   content) — set it to `"no"` for the strictest setting
7. **Optional desktop:** runs `installDE.sh` *inside the new system*
   (`arch-chroot`) non-interactively. This step is **non-fatal** — if it
   fails (mirror/AUR hiccup), the base system is already complete and the
   closing dialog tells you to run `installDE.sh` after reboot. The
   display manager and `graphical.target` links are verified afterwards
   (a fresh chroot can report success without creating them)
8. Copies `arch-manager.sh`, `lib.sh` and all scripts to `/archInstall/`
   on the new system (`/archInstall/scripts/` for the phase scripts;
   missing ones are fetched from the repo)
9. Writes `/root/arch-install-state.conf` (user, hostname, desktop, keymap,
   language, formats, timezone, time; `%q`-quoted shell assignments) on the new
   system, which `arch-manager.sh` shows in its status block
10. Closing dialog with the next steps and *"Unmount everything and reboot
   now?"* (default Yes)

On a system that is not the live ISO it asks (default No) before doing
anything, since it wipes a whole disk.

### 2. `setupAfterInstall.sh` — after first boot, as root

Run this on the newly installed system. It does **not** touch
partitioning, formatting, or LUKS — it assumes `archInstall.sh` (or an
equivalent manual install) already produced the layout above.

Questions (GRUB theme, Plymouth theme, one scrollable summary +
confirmation) come first as dialogs; everything after the confirmation
runs unattended with live output in a dialog box (log:
`/root/setupAfterInstall.log`), and a final dialog offers a reboot
(default No). Warnings from the layout checks are collected and shown in
the summary instead of scrolling past. Warnings raised *during* the run
(a theme that failed to download, LUKS discards not enabled, a missing
timer, ...) are collected as well and listed in the closing dialog (the first
six; the rest are in the log) — the run itself happens in a subshell, so
they are passed back through a small temporary file (`WARN_FILE`, see
`lib.sh`).

1. Verifies the expected layout (Btrfs root, `/efi`, `/boot`,
   `/.snapshots` mounted, fstab entry for `/.snapshots` present)
2. Detects the LUKS2 backing device (via `cryptsetup status`, with an
   `lsblk` fallback) and CPU vendor for microcode
3. Menu: which GRUB boot menu theme to install (default none). The menu
   is **built from the archives that actually exist** in the repo's
   `grub-themes/` folder (GitHub contents API; falls back to the built-in
   list `Xenlism-Arch`, `arch-linux`, `poly-dark` when offline or
   rate-limited). The archive is extracted to a scratch directory,
   `theme.txt` is located inside it and the theme is installed as
   `/boot/grub/themes/<name>/` — it doesn't matter what the archive's own
   top-level folder is called. `GRUB_THEME` is pointed at it in
   `/etc/default/grub` (skipped, without failing the script, if the
   download or the theme is unusable)
4. Menu: which Plymouth boot splash theme to install (default none) —
   built the same way from `plymouth-themes/` (fallback list: `cuts_alt`,
   `hud_3`, `linux-penguin`, `metal_ball`). Choosing **none** really means
   no splash: the `plymouth` package, the `plymouth` initramfs hook and the
   `splash` kernel option are only added when a theme was chosen
   Then a menu **"Other operating systems"** (only if `ENABLE_OS_PROBER=yes`,
   the default):
   - **internal** *(default)* — only Windows/Linux installs on **internal**
     disks. Filesystems on removable (`RM=1`) or USB-attached
     (`TRAN=usb`) disks and optical drives — USB sticks with installers,
     external/USB HDDs — are put on GRUB's `GRUB_OS_PROBER_SKIP_LIST`
     (`<fs UUID>@<device>` entries written to `/etc/default/grub`, so
     later automatic `grub-mkconfig` runs honour it too), and the search
     for the Windows ESP never looks at those disks either
   - **all** — everything os-prober finds, as before
   - **off** — no other OSes in the GRUB menu (`GRUB_DISABLE_OS_PROBER=true`)
5. Shows a scrollable summary and asks for confirmation
6. Backs up `/etc/fstab`, `/etc/mkinitcpio.conf`, `/etc/default/grub`,
   `/etc/snapper/configs/root` to `/root/btrfs-setup-backups/<timestamp>/`.
   Then any numeric `subvolid=` pins left in `/etc/fstab` are removed (see
   `archInstall.sh`; matters for booting snapshots from grub-btrfs and for
   rollbacks). From here on, every `/etc/default/grub` option the script touches
   (`GRUB_TIMEOUT`, `GRUB_DEFAULT`, `GRUB_SAVEDEFAULT`,
   `GRUB_DISABLE_OS_PROBER`, `GRUB_OS_PROBER_SKIP_LIST`, `GRUB_THEME`,
   `GRUB_CMDLINE_LINUX_DEFAULT`)
   goes through a helper that finds the existing line — commented out or
   not — and edits it in place, rather than appending a new value to the
   bottom of the file (which would leave a stale duplicate, commented or
   otherwise, above the one GRUB actually reads)
7. Installs: `btrfs-progs`, `cryptsetup`, `snapper`, `snap-pac`, `grub`,
   `grub-btrfs`, `inotify-tools`, `btrfs-assistant`, `git`, `curl`,
   `efibootmgr`, the microcode package, and `plymouth` (only if a Plymouth
   theme was chosen)
8. Sets up the Snapper config for `/` (creates it against the existing
   `@snapshots` subvolume rather than letting Snapper create its own),
   with number + timeline retention policy and space-based cleanup
   (Btrfs quota/qgroups — can be disabled via `ENABLE_BTRFS_QUOTA=no`)
9. Enables `snapper-cleanup.timer`, `snapper-timeline.timer`,
   `snapper-boot.timer`, `fstrim.timer`. If the LUKS mapping does not
   allow discards (no `rd.luks.options=discard`), a warning explains that
   `fstrim` cannot TRIM the encrypted root
10. Installs the selected Plymouth theme (if any): the archive is
    extracted to a scratch directory, the `.plymouth` file is located
    inside it, the theme is installed under the name of that file
    (`/usr/share/plymouth/themes/<name>/<name>.plymouth`, which is what
    `plymouth-set-default-theme` requires) and set as default — a failed
    download or a missing `.plymouth` file doesn't fail the script, it
    just leaves Plymouth on its default theme. (An older version searched
    *all* installed themes for "any `.plymouth` file" and could rename a
    stock theme by mistake; that fallback is gone.)
11. Rewrites `mkinitcpio.conf` HOOKS to the systemd + `sd-encrypt` set
    (+ `plymouth` when a theme was chosen) inside a marked
    `# >>> arch-setup HOOKS` block — a re-run replaces the block instead of
    stacking comments — and rebuilds the initramfs. Right after that it installs
    the snapshot boot tooling and archives the freshly built kernel +
    initramfs (see [Booting a snapshot after a bad update](#booting-a-snapshot-after-a-bad-update))
12. Rewrites the GRUB kernel cmdline (`rd.luks.name=`, `root=`,
    `rootflags=subvol=…`, `quiet`, `splash` only with Plymouth, …). The
    mapper name and the root subvolume are **read from the running system**
    (`cryptsetup status`, `findmnt`), not assumed to be `cryptroot` / `@`,
    and duplicate options (e.g. the `quiet` already set by
    `archInstall.sh`) are removed. Then reinstalls GRUB under a
    named UEFI boot entry (`GRUB_BOOTLOADER_ID="Arch Linux"` by
    default, shown in your firmware's boot menu), enables `os-prober`
    in the mode you chose (`ENABLE_OS_PROBER=yes` is the default — set it
    to `no` in the script's config block if you don't dual-boot another
    OS or prefer picking it from the firmware boot menu instead of
    GRUB's), enables `grub-btrfsd`, regenerates `grub.cfg`
13. Removes stale UEFI boot entries named exactly `GRUB` or `UEFI OS`
    left behind by `archInstall.sh`'s temporary `--bootloader-id=GRUB
    --removable` install — but only entries whose device path matches
    *this* install's own ESP (compared by `PARTUUID`), so boot entries
    belonging to other OSes or other disks (e.g. a Windows install) are
    never touched
14. Creates and cleans up an initial protected snapshot
15. Prints a final status report (filesystems, subvolumes, LUKS status,
    Snapper config/snapshots, timers, Plymouth theme, the other
    operating systems that ended up in the GRUB menu, GRUB cmdline)

### 3. `installDE.sh` — on the installed system, as root

Run any time after `archInstall.sh` (before or after
`setupAfterInstall.sh`, order doesn't matter). Installs a desktop
environment; doesn't touch partitioning, LUKS, Snapper, or GRUB.

1. Not running as root? Re-launches itself with `sudo` (asks for your
   password) instead of just refusing
2. Picks the target user automatically if there's exactly one regular
   (UID ≥ 1000) account on the system; otherwise a menu asks which one
   (none at all → it stops and tells you to create one first)
3. Asks for a desktop environment: **GNOME** or **KDE Plasma** (both
   Wayland), **XFCE** (X11 — its Wayland session is still
   experimental/unstable upstream, so X11 is the stable choice here),
   or none/cancel — and, if one is chosen, full or minimal package set.
   GNOME full installs the official `gnome` group plus the **current
   contents of the `gnome-extra` group read from the package database,
   minus the games** (so new/renamed upstream packages are picked up
   automatically; a built-in list is the fallback if the group can't be
   read), plus Tweaks, `power-profiles-daemon` and
   `bluez`/`bluez-utils`; GNOME minimal is a small hand-picked set (shell, Control
   Center, Nautilus, a terminal, GDM, `power-profiles-daemon`,
   `bluez`/`bluez-utils`); KDE is a curated set that differs between the modes:
   minimal = `plasma-desktop`, SDDM, `plasma-nm`, Dolphin, Konsole; full
   adds the usual Plasma applets (`plasma-pa`, `powerdevil`, `bluedevil` +
   `bluez`, `kscreen`, `kinfocenter`, `kdeplasma-addons`, `kde-gtk-config`,
   portal) and Kate, Ark, Gwenview, Okular, Spectacle. There is **no**
   `plasma-workspace-wayland` package any more (the Wayland session is part
   of `plasma-workspace`) — naming it made the whole pacman transaction
   fail; earlier versions also installed the identical set for "full" and
   "minimal". XFCE uses the official `xfce4` group
   (+ `xfce4-goodies` for full) with LightDM + `lightdm-gtk-greeter`,
   plus `network-manager-applet` (XFCE has no built-in network UI;
   GNOME's shell has its own) GNOME and KDE share a common set of
   portal/Qt/polkit packages needed for Wayland apps; XFCE gets an
   equivalent X11 set (Xorg server + portals/polkit, no Qt-Wayland bits)
4. **GPU userspace drivers, detected from sysfs** (`/sys/class/drm`, no
   `lspci` needed): `mesa` always, `vulkan-radeon` for AMD,
   `vulkan-intel` + `intel-media-driver` for Intel. NVIDIA is *not*
   automated (open vs. proprietary module is your call) — a warning is
   shown. **Audio:** `pipewire`, `pipewire-pulse`, `pipewire-alsa` and
   `wireplumber` are added for every desktop — the DE packages only depend on
   the PulseAudio *client* library, not on a sound server, so KDE and XFCE
   used to come up without sound (the PipeWire user sockets are enabled by
   the packages themselves, nothing to switch on). Then the package list is
   checked against the sync databases:
   a name that no longer exists is **skipped with a warning** instead of
   making `pacman -S` abort the whole transaction
5. Shows a summary (user, DE, GPU, package list, skipped packages) and
   asks for confirmation in a yes/no dialog (default Yes)
6. Installs the packages
7. **GNOME only:** downloads and installs the
   [Reversal icon theme](https://github.com/yeyushengfan258/Reversal-icon-theme)
   from this repo's `icons/Reversal-icon-theme-master.tar.xz` — extracted
   to a temp dir and built via its own `install.sh`, once per color
   variant (`yellow` default, then `orange`, `black`, `grey` via `-t
   <color>`). A failed download or a missing `install.sh` in the archive warns and
   skips that theme rather than failing the script; the icon cache is
   refreshed afterwards so both themes show up immediately in
   theme pickers. **All desktops:** the Catppuccin Mocha cursor theme
   (`catppuccin-mocha-dark-cursors`) is downloaded from the latest release of
   [catppuccin/cursors](https://github.com/catppuccin/cursors) (not from this
   repo), unpacked with `bsdtar` into `/usr/share/icons/` and skipped if it is
   already there; a failed download only warns. The **DeepinV20-dark** cursor
   theme is installed for every desktop too, from `cursor/DeepinV20-dark.tar.xz`
   **in this repo**, into `/usr/share/icons/DeepinV20-dark/` (system-wide, not
   `~/.icons`). **It is the cursor applied by default** on every desktop;
   Catppuccin Mocha is still installed and can be picked in the cursor settings
8. Enables the matching display manager/greeter (`gdm.service` /
   `sddm.service` / `lightdm.service`)
9. **GNOME only:** sets the dark color scheme
   (`org.gnome.desktop.interface color-scheme=prefer-dark` +
   `gtk-theme=Adwaita-dark` for older GTK3 apps, plus `accent-color=slate`
   on GNOME 47+), `clock-format=24h`, directories-before-files in GTK file dialogs, an
   always-visible "Log Out" entry in the GNOME shell menu, and the
   Reversal icon theme + dark cursor theme installed in step 7 — all as
   defaults for the target user, applied via a temporary
   `dbus-run-session` since there's no live GNOME session yet to talk to
10. **GNOME and full KDE:** enables `bluetooth.service` and sets
   `AutoEnable=true` in `/etc/bluetooth/main.conf` so the adapter comes
   up powered after boot instead of staying soft-blocked until you
   toggle it manually
11. **GNOME only:** enables `power-profiles-daemon.service` (needed for
    Settings → Power to work)
12. **XFCE only:** explicitly sets `lightdm-gtk-greeter` as the greeter
    in `/etc/lightdm/lightdm.conf`'s `[Seat:*]` section (LightDM
    otherwise often comes up with no greeter session configured at all)

Interactive mode uses dialog menus for the desktop, full/minimal and the
user, a confirmation box, and live install output in a dialog box (log:
`/var/log/installDE.log`).

**Non-interactive mode** (this is how `archInstall.sh` calls it inside the
new system's chroot): set `ASSUME_YES=1` together with `DE_CHOICE`
(`1` GNOME, `2` KDE Plasma, `3` XFCE), `INSTALL_MODE` (`full`|`minimal`)
and `TARGET_USER`, and no dialog is shown — e.g.
`ASSUME_YES=1 DE_CHOICE=2 INSTALL_MODE=minimal TARGET_USER=alice ./installDE.sh`.

**Chroot behaviour (GNOME):** package install, `systemctl enable`, theme
downloads, Bluetooth and LightDM config all work in a chroot. The GNOME
defaults are applied in **two layers, always**: first per-user with
`gsettings` inside a temporary `dbus-run-session` as the target user
(works in a chroot too — it needs no running desktop session; this is the
only reliable way to set the *Formats* region), then as **system-wide
dconf defaults** (`/etc/dconf/db/local.d/00-arch-defaults` +
`dconf update`; applies to every user, who can still change them) as a
fallback. Non-essential keys (accent colour, file-chooser, log-out entry)
are best-effort, so a schema missing on one GNOME version cannot abort the
rest. Testing the chroot path in a VM is the first thing to do after
changing this part.

**KDE:** the target user's `kdeglobals` (Breeze Dark), `kcminputrc`
(DeepinV20-dark cursor) and `plasma-localerc` (regional formats + UI
language, read from `LANG` in `/etc/locale.conf`) are written with the
user's ownership — KDE ignores config files owned by root. Existing files
are merged in place, not overwritten.

**XFCE:** there is no way to preset settings through a session bus from a
chroot, so they are written as the user's own xfconf channel files, which
XFCE reads on first login: `xsettings.xml` (Adwaita-dark, Adwaita icons,
DeepinV20-dark cursor), `xfwm4.xml` and `xfce4-panel.xml` (a panel whose
clock shows time then date, 24 h).

You can re-run this later to install a different desktop environment or
change from full to minimal (or vice versa) — it doesn't remove
anything from a previous run, it only adds.

### 4. `installApps.sh` — at the desktop, as your regular user

Run this **as your normal user, not root/sudo** — `makepkg`/`yay` refuse
to run as root. It installs applications on top of the base system from
the two scripts above; it doesn't touch partitioning, LUKS, Snapper, or
GRUB at all.

The UI is **`dialog`-based (ncurses)**: all questions are asked up front
as proper menus, you confirm once, then the install runs unattended with
live output inside a dialog box. Works on a plain TTY (no desktop
needed). Keys: `SPACE` toggles a checkbox, `ENTER` confirms, `ESC`
cancels (nothing is installed on cancel).

1. Refuses to run as root; asks for your `sudo` password **once**, then
   installs a short-lived `NOPASSWD` drop-in
   (`/etc/sudoers.d/99-installer-timestamp`, mode 0440, this user only) so that
   `yay`/`makepkg` — which call `sudo` themselves — can never pop a password
   prompt over the dialog during a long AUR build. The file is first written
   as `99-installer-timestamp.staging` (sudo ignores names containing a dot),
   validated there with `visudo -cf` and only then renamed into place, so a
   syntax error can never leave sudo broken. The drop-in is removed on every normal exit
   path (success, error, Ctrl+C); only a `kill -9` would leave it behind
   (then delete it by hand). Installs `dialog` itself if it's missing
2. **Package checklists** — seven `dialog` checklists, each a list of
   *individual packages* (no all-or-nothing bundles). The tag of every row is
   the package name, so what you tick is exactly what gets installed. `SPACE`
   toggles a row; a list longer than the screen scrolls with
   `UP`/`DOWN`/`PgUp`/`PgDn`, and the box widens up to the terminal width
   because dialog clips a too-wide row instead of wrapping it. In order:

   | Dialog | Rows | Defaults |
   |--------|------|----------|
   | Optional packages | `lact`, `coolercontrol-bin`, fingerprint for sudo, `nautilus-admin-gtk4` (listed only on GNOME), `libreoffice-still`, `wps-office` + fonts, `onlyoffice-bin` | LACT **on** with an AMD GPU; CoolerControl **on** on a desktop; fingerprint **on** on a laptop; Nautilus **on**; office suites off |
   | Work programs | `jdk11-openjdk`, `meld`, `code`, `remmina`, `intellij-idea-oss`, `dbeaver`, `postman-bin`, `f5vpn-ng`, `ferdium-bin` | all **on** |
   | VPN | `wireguard-tools`, `networkmanager-openconnect` (Cisco AnyConnect, F5), `networkmanager-vpnc` (legacy Cisco IPsec), `networkmanager-openvpn`, `snx-rs` (Check Point, native client, no NetworkManager plugin) | all **on** |
   | Printer and scanner | `hplip`, `cups`, `system-config-printer`, `python-pyqt5`, `avahi`, `nss-mdns`, `cups-pdf`, `simple-scan` | all **on** |
   | Office and fonts | `hunspell-hr`, `libreoffice-still-hr`, `ttf-liberation`, `noto-fonts-emoji`, `ttf-jetbrains-mono-nerd`, `ttf-ms-fonts` | all **on** |
   | Multimedia and utilities | `vlc`, `mpv`, `ffmpeg`, `flatpak`, `fastfetch`, `ncdu`, `localsend-bin`, `gnome-shell-extension-gsconnect` | all **on** |
   | System maintenance | `fwupd`, `ntfs-3g`, `fstrim.timer` (a systemd unit, not a package), `ufw`, `gufw` | first three **on**; `ufw`/`gufw` off |

   The *Fingerprint for sudo* row is not a package but the PAM line
   `pam_fprintd.so timeout=3` in `/etc/pam.d/sudo` (official `fprintd` module,
   no AUR); it also installs `fprintd`. A one-line-per-package list with
   sources and descriptions is in the [package overview](#installappssh--package-overview).
3. **Extra packages** input box (space-separated, blank to skip) —
   official-repo and AUR names both work. Only plain package names are
   accepted; anything starting with `-` (which pacman/yay would treat as
   an option, e.g. `--overwrite`) is ignored with a message; ESC aborts, as in every other dialog
4. **Confirmation** — duplicates are removed first (an extra package that was
   already ticked above is dropped). The box shows the final repo / AUR /
   extra lists with their counts and a **System changes** section listing
   everything that is not a package: services to enable, the
   `/etc/nsswitch.conf` and `/etc/pam.d/sudo` edits, the firewall. If the text
   is taller than the screen it is shown as ONE scrollable screen whose two
   buttons are **Yes** and **No** (a plain yes/no box cannot scroll, so its
   buttons would be pushed off the screen; `ask_yes` in `lib.sh` switches to a
   scrollable text box with relabelled buttons). Answering No (or `ESC`) at any
   dialog above aborts cleanly
5. Installs unattended, with live output in a dialog box (also saved to
   `installApps.log` next to the script when that folder is writable, e.g.
   `~/arch-setup/downloads/installApps.log` when started via the manager;
   otherwise `~/installApps.log`):
   - first runs a **full system upgrade** (`pacman -Syu`; shown under *System
     changes* in the confirmation). A bare `-Sy` would be a partial upgrade. If
     the upgrade fails, nothing is installed and the script stops
   - bootstraps `yay` if missing (`base-devel` + `git` via `pacman`, then
     `yay` itself built from AUR with `makepkg`). If that build fails the
     run **continues** with the official-repo packages; the AUR packages
     are then listed as FAILED ("yay is not available") instead of the
     whole run stopping
   - always-installed base set — **Repo:** `terminator`, `guake`, `qmmp`,
     `kolourpaint`, `mission-center`, `stow`, `eza`, `peazip`; **AUR:**
     `google-chrome`, `sublime-text-4`. Every entry in the package arrays
     at the top of the script carries a short inline comment saying what it
     is for
   - then whatever you picked above
6. Every package — list-defined or typed in — is checked with
   `pacman -Si` / `yay -Si` before install; unknown/typo'd names are
   skipped with a warning instead of aborting the whole run. Which list a
   package sits in does not matter: a name in the "repo" list that is only in
   the AUR goes to `yay`, and a name in the "AUR" list that is in the
   official repos goes to plain `pacman` (so it no longer needs `yay`).
   Genuine install failures (found, but errored) are collected and reported,
   not fatal to the rest of the run
7. Post-install steps, each shown in the progress window and each done only
   for what was actually installed:
   - sets the work JDK as the default JVM (`archlinux-java set`) — the
     package and its `archlinux-java` name are the two variables `JAVA_PKG` /
     `JAVA_ENV` at the top of the script (default `jdk11-openjdk` /
     `java-11-openjdk`)
   - **printing:** enables `cups.service` and `avahi-daemon.service`; adds
     `mdns_minimal [NOTFOUND=return]` to the `hosts:` line of
     `/etc/nsswitch.conf` (before `resolve`/`dns`) only when **both**
     `nss-mdns` and `avahi` are installed — the edit is made on a temp copy,
     verified, and the original is kept as `/etc/nsswitch.conf.bak-mdns`
   - **hardware daemons:** `lactd.service` (LACT) and `coolercontrold.service`
     (CoolerControl) — the packages install them but don't start them
   - **sudo fingerprint:** the PAM line described below (backup `.bak-fprint`)
   - **SSD TRIM:** `fstrim.timer`, if ticked
   - **firewall (only if `ufw` or `gufw` was ticked):** installs `ufw`, sets
     `deny incoming` / `allow outgoing`, allows `22/tcp` first when an SSH
     server is running (so enabling the firewall cannot lock out a remote
     session), runs `ufw enable` **and enables `ufw.service`** (`ufw enable`
     alone only loads the rules for the running system; without the unit the
     firewall would be gone after the next boot). Ports are then opened only
     for packages that really got installed: GSConnect 1714-1764 tcp/udp,
     LocalSend 53317 tcp/udp. Printing needs no rule (CUPS listens on
     localhost only; mDNS discovery is accepted by the default ufw/firewalld
     rules). If `ufw` (or `firewalld`) is already active its default
     policies are left alone and only port rules are added; raw
     nftables/iptables rules are never touched
8. Final summary dialog (scrollable when long): what was skipped/failed, the
   firewall state, and manual next steps — each hint appears only if the
   matching package was selected: `hp-setup` for the actual printer, an mDNS
   note (if you also run `systemd-resolved` with its own mDNS, disable one of
   the two), adding the Flathub remote for `flatpak`,
   `fwupdmgr refresh && fwupdmgr get-updates` for `fwupd`, enabling the
   GSConnect extension, logging out and in after installing VPN plugins and
   how to import a WireGuard config (`nmcli connection import type wireguard
   file <name>.conf`), the `snx-rs` build time and `f5vpn-ng` library fixes

**Fingerprint reader note:** `fprintd` is installed only together with the optional
*Fingerprint for sudo* item (it is not in the base set, so a machine without a
reader never gets it). The item adds `auth sufficient pam_fprintd.so timeout=3` right under the
`#%PAM-1.0` header of `/etc/pam.d/sudo` (once only; the original is kept as
`/etc/pam.d/sudo.bak-fprint`; `FPRINT_TIMEOUT` at the top of the script
changes the 3 s). `sudo` then waits for a fingerprint for 3 seconds and
afterwards asks for the password as usual — typing the password *while*
it waits for the finger is not possible with the official module (that
needs the AUR `pam-fprint-grosshack`, deliberately not used). GDM and the
GNOME lock screen need no PAM change: once a finger is enrolled they accept
the fingerprint and the typed password at the same time. If no finger is
enrolled, `sudo` simply asks for the password. Keep a second terminal with
`sudo -i` open while testing a PAM change. They only help if the reader is supported by
`libfprint` — check with `lsusb` against the
[supported devices list](https://fprint.freedesktop.org/supported-devices.html).
Enroll a finger afterwards with `fprintd-enroll` and test it with
`fprintd-verify` (GNOME also offers it under Settings → Users). The
fingerprint works for the login screen, `sudo` and polkit prompts, but it
**cannot unlock the LUKS root** at boot (the initramfs has no fingerprint
support), and on GDM the keyring is not unlocked by a fingerprint login.

You can re-run `installApps.sh` any time later to add more software —
it's idempotent (`--needed` skips already-installed packages) and shows
the dialogs every time.

### `installApps.sh` — package overview

One row per package, grouped like the dialogs. Generated from the arrays and
checklists in `installApps.sh` (also saved as `packages.md`); if you change them
there, update this table. *Source* is where the package is expected — the script
installs it from wherever it is actually found. `base-devel`, `git` and `yay` are
installed without asking (the build tools the script itself needs).

#### Base packages (always installed)

| Package | Source | Description |
|---|---|---|
| terminator | pacman | terminal emulator with split panes |
| guake | pacman | drop-down terminal (toggle with F12) |
| qmmp | pacman | lightweight audio player (Winamp-style) |
| kolourpaint | pacman | simple paint / image editor |
| mission-center | pacman | system monitor (CPU, RAM, GPU, processes) |
| stow | pacman | symlink manager, handy for dotfiles |
| eza | pacman | modern ls replacement |
| peazip | pacman | official repo (extra); used to be AUR-only |
| google-chrome | AUR | Google Chrome web browser |
| sublime-text-4 | AUR | Sublime Text 4 editor |

#### Optional packages (checklist)

| Package | Source | Default | Description |
|---|---|---|---|
| lact | pacman | on with an AMD GPU | Lact - AMD GPU control/overclock |
| coolercontrol-bin | AUR | on on a desktop, off on a laptop | CoolerControl - fan/cooling control |
| fprintd + sudo PAM line | pacman | on on a laptop, off on a desktop | Fingerprint for sudo: PAM line, 3 s timeout, then password |
| nautilus-admin-gtk4 | AUR | on (offered only on GNOME) | Nautilus 'Open as Administrator' |
| libreoffice-still | pacman | off | LibreOffice still |
| wps-office + ttf-wps-fonts | AUR | off | WPS Office + fonts |
| onlyoffice-bin | AUR | off | OnlyOffice |

#### Work programs (checklist)

| Package | Source | Default | Description |
|---|---|---|---|
| jdk11-openjdk | pacman | on | work JDK, becomes the default java |
| meld | pacman | on | visual diff and merge tool |
| code | pacman | on | open-source VS Code |
| remmina | pacman | on | remote desktop client RDP/VNC/SSH |
| intellij-idea-oss | pacman | on | IntelliJ IDEA open-source build (the former `intellij-idea-community-edition`, renamed in `[extra]`) |
| dbeaver | pacman | on | universal database client |
| postman-bin | AUR | on | Postman API client |
| f5vpn-ng | AUR | on | F5 VPN client |
| ferdium-bin | AUR | on | Ferdium messaging client |

#### VPN (checklist)

| Package | Source | Default | Description |
|---|---|---|---|
| wireguard-tools | pacman | on | WireGuard tools wg / wg-quick; NetworkManager supports WireGuard itself |
| networkmanager-openconnect | pacman | on | Cisco AnyConnect and F5 via openconnect |
| networkmanager-vpnc | pacman | on | legacy Cisco IPsec |
| networkmanager-openvpn | pacman | on | OpenVPN |
| snx-rs | AUR | on | Check Point VPN client, native, not a NetworkManager plugin |

#### Printer and scanner (checklist)

| Package | Source | Default | Description |
|---|---|---|---|
| hplip | pacman | on | HP printer support |
| cups | pacman | on | printing system |
| system-config-printer | pacman | on | GUI printer management |
| python-pyqt5 | pacman | on | Python Qt5 bindings, needed by hp-setup GUI |
| avahi | pacman | on | mDNS/DNS-SD daemon for network printer discovery |
| nss-mdns | pacman | on | resolve .local hostnames via Avahi |
| cups-pdf | pacman | on | virtual printer: print to PDF |
| simple-scan | pacman | on | simple scanning GUI |

#### Office and fonts (checklist)

| Package | Source | Default | Description |
|---|---|---|---|
| hunspell-hr | pacman | on | Croatian spellcheck dictionary |
| libreoffice-still-hr | pacman | on | Croatian LibreOffice UI, pulls libreoffice-still |
| ttf-liberation | pacman | on | metric-compatible Arial/Times/Courier |
| noto-fonts-emoji | pacman | on | emoji font |
| ttf-jetbrains-mono-nerd | pacman | on | monospace font with icons |
| ttf-ms-fonts | AUR | on | Microsoft core fonts Arial/Times/... |

#### Multimedia and utilities (checklist)

| Package | Source | Default | Description |
|---|---|---|---|
| vlc | pacman | on | video player |
| mpv | pacman | on | lightweight video player |
| ffmpeg | pacman | on | audio/video conversion tools |
| flatpak | pacman | on | Flatpak runtime and CLI |
| fastfetch | pacman | on | system info in the terminal |
| ncdu | pacman | on | disk usage analyzer, ncurses |
| localsend-bin | AUR | on | AirDrop-like file transfer |
| gnome-shell-extension-gsconnect | pacman or AUR | on | GSConnect, phone integration for GNOME Shell |

#### System maintenance (checklist)

| Package | Source | Default | Description |
|---|---|---|---|
| fwupd | pacman | on | firmware updates via LVFS |
| ntfs-3g | pacman | on | read/write NTFS Windows partitions |
| fstrim.timer | systemd unit | on | weekly SSD TRIM (systemd unit, not a package) |
| ufw | pacman | off | Uncomplicated Firewall, command-line only |
| gufw | pacman | off | Graphical frontend for ufw, includes ufw |

### `arch-manager.sh` — optional dialog menu

Not part of the numbered phases — a convenience front-end that downloads
`lib.sh` and the four scripts from the repo and lets you run them from a
menu instead of typing filenames. A status block (Arch? Live ISO? root? Btrfs? Snapper? installed desktop, plus
the configuration from `/root/arch-install-state.conf` when it exists) is shown
above the menu every time.

The menu is **state-aware**: the numbers never change, but entries that make no
sense in the current state are prefixed `[N/A -- reason]` and only show an
explanation when selected (dialog has no real "disabled" item).

1. **Install Arch** — runs `archInstall.sh`. Only on the live ISO; on an installed
   system it shows an explanation instead (it never starts the disk wipe from
   there). On success the manager exits so you can reboot; `archInstall.sh`
   itself already put the manager and all scripts into `/archInstall/` on the
   new system. (Running `archInstall.sh` *directly* on a non-live system asks
   first, default No.)
2. Run `setupAfterInstall.sh` only (not on the live ISO)
3. Run `installDE.sh` only (not on the live ISO; labelled "Reinstall / change"
   when a desktop is already installed)
4. Run `installApps.sh` only (not on the live ISO)
5. **Install all after reboot:** `setupAfterInstall.sh` → `installDE.sh` →
   `installApps.sh`. `installDE.sh` is skipped (with a question, default
   No) if a desktop is already installed — e.g. you chose one in
   `archInstall.sh`. If a step fails it asks whether to continue; cancelling a
   step stops the whole sequence
6. Download / update `lib.sh` and the four scripts now (the manager itself,
   `arch-manager.sh`, is not updated by this)

Details:

- Scripts are fetched **on demand** (and `lib.sh` with them), but local
  copies win: it first seeds its download folder from files next to the
  manager, a `scripts/` folder beside it, or `/archInstall/scripts/` (on
  the installed system), so nothing needs re-downloading. Failed downloads
  say why (HTTP code + URL) and never leave an HTML error page behind
- Downloads go to `~/arch-setup/downloads/` of the *real* user (resolved
  via `$SUDO_USER` when run with `sudo`), not `/root`
- Runs `archInstall.sh` / `setupAfterInstall.sh` / `installDE.sh` with
  `sudo` automatically if not already root; runs `installApps.sh` as the
  real non-root user even if the manager itself is root (drops privileges
  via `runuser`)
- CLI shortcuts: `./arch-manager.sh --download` (fetch everything),
  `--install` (fetch + run **only** `archInstall.sh`), `--help`, or
  `./arch-manager.sh <script-name.sh>` to run one script directly
- To use your own fork/branch set `ARCH_REPO_URL` (see "Getting the
  scripts onto the Arch ISO") — one variable instead of editing
  `SCRIPT_URL`, `REPO_RAW_URL` and the snippet at the top of every script
- The "is this Arch?" status check matches `ID=arch` exactly (derivatives
  such as CachyOS, which only set `ID_LIKE=arch`, show *Arch: no*)

## Booting a snapshot after a bad update

The goal: an update breaks the system or it no longer boots → reboot, pick the
last good snapshot in GRUB, and **keep working in it as a normal system** until
the broken package is fixed upstream.

```
GRUB  →  Arch Linux snapshots (own kernel)  →  Snapshot #42 [post] pacman -Syu (kernel 6.x.y)
```

Two things normally stand in the way, and `setupAfterInstall.sh` handles both:

1. **Snapper snapshots are read-only.** A read-only root cannot boot to a
   usable system (`/var`, `/etc` need to be written). The generated GRUB
   entries therefore switch every snapshot they list to read-write
   (`btrfs property set -ts … ro false`). Changes you make while booted from a
   snapshot stay in that snapshot.
2. **`/boot` is a separate ext4 partition, outside Btrfs.** A snapshot holds the
   kernel *modules* (`/usr/lib/modules/<kver>`) but not the kernel, so it would
   boot with the newest kernel from `/boot` — mismatched modules, or the very
   kernel that broke the system. To avoid that, every kernel version that the
   system or any snapshot still has modules for is archived in
   `/boot/kernel-archive/<kver>/{vmlinuz,initramfs.img}`, and each snapshot's
   GRUB entry uses the archived kernel that matches *its own* modules.

### What gets installed

| Path | Purpose |
|------|---------|
| `/usr/local/sbin/arch-kernel-archive` | Copies the installed kernel + initramfs to `/boot/kernel-archive/<kver>/` and prunes copies no snapshot refers to any more. |
| `/etc/pacman.d/hooks/99-kernel-archive.hook` | Runs it after every kernel/initramfs change. The `99-` prefix makes it run *after* mkinitcpio's own hook, so the initramfs it copies is the new one. |
| `/etc/grub.d/42_snapshot-kernels` | Run by `grub-mkconfig`: builds the submenu, one entry per snapshot (newest first, at most 30), and makes those snapshots writable. The generated block is checked with `grub-script-check` first and dropped if invalid, so it can never make `grub-mkconfig` fail. |
| `/etc/pacman.d/hooks/zzz-grub-refresh.hook` + `/usr/local/sbin/arch-grub-refresh` | After **every** pacman transaction, regenerates `grub.cfg` so the new snap-pac `[pre]`/`[post]` snapshots show up in the menu immediately (the `zzz-` prefix sorts after snap-pac's own `zz-snap-pac-post`). The new config is built in a temp file, stripped of "EFI BootNext" entries, and only replaces the live one if `grub-mkconfig` succeeded and an existing Windows entry survived (os-prober can lose it when the Windows ESP is not reachable). It always exits 0, so it can never fail an update. Costs a few seconds per transaction. |
| `/usr/local/sbin/arch-snapshot-promote` | Two modes (see below): plain = make the snapshot you are booted from the permanent root; `--kernel-only` = after a Btrfs Assistant restore, put the matching kernel back into `/boot`. |
| `/etc/arch-snapshot.conf` | Name of the normal root subvolume (`ROOT_SUBVOL=@`), read by the promote tool. |

`grub-btrfs` stays installed — its **daemon** regenerates `grub.cfg` whenever a
snapshot is created or deleted — but its own menu is switched off
(`GRUB_BTRFS_DISABLE="true"`), because its entries can only use the current
kernel. If your `grub-btrfs` has no such option the setup warns about it and
you will see two snapshot menus; use the one called *(own kernel)*.

### Using it

1. **Something broke.** Reboot (or power-cycle if it hangs during boot).
2. In GRUB choose **Arch Linux snapshots (own kernel)** and the last snapshot
   from before the bad update. The entry shows date, type, description and
   kernel version; `snap-pac` snapshots are labelled `[pre]` / `[post]` with
   the pacman command. A `[pre]` snapshot is the state *before* that
   transaction.
3. **GRUB remembers your choice**, exactly like it does for the normal entry
   (`GRUB_DEFAULT=saved` + `GRUB_SAVEDEFAULT=true`, which `setupAfterInstall.sh`
   sets; the snapshot entries carry `savedefault` as well). The snapshot you
   booted is therefore the default at the next boot, with no menu needed. To go
   back to the normal system, pick the normal first entry once. Note that GRUB
   saves the choice when you *select* the entry, not after the boot succeeded —
   if a snapshot fails to boot, choose another entry manually. If the saved
   snapshot is later deleted by Snapper, GRUB falls back to the first entry.
4. Work normally. Don't run the update that broke things. `/home` is a separate
   subvolume, so your files are the same as in the normal system.
5. **When the fix is available**, either boot the normal first entry and
   update, or — if you decided to stay in the snapshot for good — run, while
   booted from it:

   ```bash
   sudo arch-snapshot-promote
   ```

   It renames the current `@` to `@.broken-<date>` (nothing is deleted),
   copies the snapshot you are in to a new `@`, puts the matching kernel back
   into `/boot` (`vmlinuz-<pkgbase>`, then `mkinitcpio -p <pkgbase>`), and
   tells you how to delete the old `@.broken-*` later. Then reboot into the
   normal first GRUB entry.

### Restoring with Btrfs Assistant instead

Btrfs Assistant's **Restore** does the same root swap as `arch-snapshot-promote`
(for the `@` / `@snapshots` layout used here) but only touches Btrfs, never
`/boot` — and `/boot` holds the kernel. If the kernel was updated since the
snapshot, the restored system would boot the newer kernel with older modules.
So after the restore and **before rebooting**, run:

```bash
sudo arch-snapshot-promote --kernel-only
```

It mounts the Btrfs top level, reads which kernel the (restored) `@` needs from
its `/usr/lib/modules`, and copies the matching kernel and initramfs from
`/boot/kernel-archive` into `/boot`; no snapshot number is needed. It does
nothing when `/boot` already matches, and it refuses (changing nothing) if the
needed kernel was never archived. The *fallback* initramfs is not archived, so
after the reboot run `sudo mkinitcpio -P` once to rebuild it. Use
`sudo arch-snapshot-promote --help` for a short reminder.

If you want to keep working in a snapshot for longer than Snapper's retention
allows, protect it first so cleanup cannot delete it:
`sudo snapper -c root modify -c "" <number>`.

### Things to know

- **All snapshots with an entry become writable.** They are still ordinary
  Snapper snapshots; the difference is only that they can be mounted
  read-write. Don't modify snapshots you want to keep pristine.
- **Disk use in `/boot`:** roughly 15 MB for a kernel plus 30–60 MB for an
  initramfs per archived version; with Snapper's default retention that is
  well within the 4 GiB `/boot`.
- **HP printer discovery behind ufw.** When `hplip` is installed and ufw is the
  active firewall, `installApps.sh` allows UDP replies with source port 161
  (SNMP), 3702 (WS-Discovery) and 427 (SLP) from the private ranges `10/8`,
  `172.16/12` and `192.168/16`. Without them HP's network search finds nothing
  while adding the printer by IP works. They are source-port rules, so no
  service on the machine is exposed. Not done for firewalld. Printers in a
  different subnet/VLAN are still not found by any broadcast search -- add them
  by IP/hostname.
- **Bulk installs create many snapshots.** `installApps.sh` installs packages
  one by one, i.e. one pacman/yay transaction per package. Each transaction gets a
  snap-pac `[pre]`/`[post]` pair and runs `arch-grub-refresh` (which includes
  os-prober), so a full app run adds dozens of snapshot pairs and noticeably
  slows down. With `NUMBER_LIMIT=20` Snapper's cleanup later removes the oldest
  ones, including the initial snapshot. Protect a snapshot you want to keep with
  `sudo snapper -c root modify -c "" <number>` (see snap-pac's documentation for
  skipping snapshots for one transaction).
- **Snapshots older than the setup** (made before `arch-kernel-archive` first
  ran) have no archived kernel and therefore no entry; the script says so on
  stderr during `grub-mkconfig`.
- **Same fstab for every snapshot.** It works because `archInstall.sh` strips
  `subvolid=` from fstab, leaving only `subvol=/@…`; the kernel command line
  (`rootflags=subvol=@snapshots/<N>/snapshot`) selects the root subvolume.
- **`snapper rollback` does not work with this layout** — it changes the
  default subvolume, but the kernel command line pins `subvol=@`, so the
  rollback would be silently ignored. Use `arch-snapshot-promote`.
- The GRUB entries and tools were exercised in isolation (a fake snapshot
  tree with stubbed `btrfs`/`grub-probe`); they have **not** been run on a real
  Arch + LUKS + GRUB system. Try the whole flow once in a VM before relying on
  it: break something, boot an entry, run `arch-snapshot-promote`.

## GRUB themes

`setupAfterInstall.sh` downloads the selected theme from
`grub-themes/<name>.tar.xz` in this repo, so that folder needs to exist
alongside the scripts with matching archive names. Current themes:

| Menu name      | Archive                              | Source |
|-----------------|--------------------------------------|--------|
| `Xenlism-Arch`  | `grub-themes/Xenlism-Arch.tar.xz`    | [xenlism/Grub-themes](https://github.com/xenlism/Grub-themes) |
| `arch-linux`    | `grub-themes/arch-linux.tar.xz`      | [gnome-look.org/p/1230780](https://www.gnome-look.org/p/1230780) |
| `poly-dark`     | `grub-themes/poly-dark.tar.xz`       | [gnome-look.org/p/1482847](https://www.gnome-look.org/p/1482847) |

The archive's internal layout is free: it is extracted to a scratch
directory, `theme.txt` is searched there and the theme folder is installed
as `/boot/grub/themes/<archive name>/`. **To add a theme: just drop a
`.tar.xz` into `grub-themes/` in the repo** — the menu is built from the
folder's contents (GitHub contents API, 60 unauthenticated requests/hour;
when the listing isn't available the built-in `GRUB_THEMES` array in
`setupAfterInstall.sh` is used instead).

## Plymouth themes

Same pattern as GRUB themes, separate folder: `setupAfterInstall.sh`
downloads the selected theme from `plymouth-themes/<name>.tar.xz` in
this repo. Current themes:

| Menu name      | Archive                                   | Source |
|-----------------|-------------------------------------------|--------|
| `cuts_alt`      | `plymouth-themes/cuts_alt.tar.xz`         | [adi1090x/plymouth-themes](https://github.com/adi1090x/plymouth-themes) |
| `hud_3`         | `plymouth-themes/hud_3.tar.xz`            | [adi1090x/plymouth-themes](https://github.com/adi1090x/plymouth-themes) |
| `linux-penguin` | `plymouth-themes/linux-penguin.tar.xz`    | [yucellmustafa/plymouth-linux](https://github.com/yucellmustafa/plymouth-linux) |
| `metal_ball`    | `plymouth-themes/metal_ball.tar.xz`       | [adi1090x/plymouth-themes](https://github.com/adi1090x/plymouth-themes) |

Each archive must contain a `<name>.plymouth` file somewhere inside; the
theme folder that holds it is installed as
`/usr/share/plymouth/themes/<name>/` (name = the `.plymouth` file's base
name — that is what `plymouth-set-default-theme` needs). If no `.plymouth`
file is found the script warns and leaves the default theme active rather
than failing. **To add a theme: just drop a `.tar.xz` into
`plymouth-themes/` in the repo** — the menu is built from the folder's
contents; the `PLYMOUTH_THEMES` array in `setupAfterInstall.sh` is only
the offline fallback.

## Icon & cursor themes

`installDE.sh` installs two themes. They come from different places and apply
to different desktops:

| What | Where from | Installed for |
|------|-----------|---------------|
| Reversal icon theme | `icons/Reversal-icon-theme-master.tar.xz` **in this repo** ([upstream](https://github.com/yeyushengfan258/Reversal-icon-theme)) | GNOME only |
| Catppuccin Mocha cursor (`catppuccin-mocha-dark-cursors`) | `releases/latest/download/…zip` of [catppuccin/cursors](https://github.com/catppuccin/cursors) — **not** in this repo | every desktop |
| DeepinV20-dark cursor | `cursor/DeepinV20-dark.tar.xz` **in this repo** | every desktop (installed **and applied by default**) |

**Reversal.** The archive ships its own `install.sh`, which is run once per
colour variant to produce the `yellow` (default), `orange`, `black` and `grey`
icon sets. It is only applied through `gsettings`, which is GNOME-specific —
that is why KDE and XFCE skip it. To update it replace the archive in the repo
(same filename/path); no script change is needed unless you rename it or add
variants (edit the `for color in orange black grey` loop in `installDE.sh`).

**Catppuccin cursor.** The upstream release is a ready-to-use cursor
directory (no `install.sh`), so it is extracted straight into
`/usr/share/icons/` with `bsdtar` (skipped if it is already there; a failed
download only warns and the desktop keeps its default cursor). It is applied
with each desktop's own mechanism: `gsettings`/dconf for GNOME, `kcminputrc`
for KDE, `xsettings.xml` for XFCE. The AUR package is not used because
`installDE.sh` runs as root and `yay`/`makepkg` refuse to.

**DeepinV20-dark cursor.** The archive also carries an SVG layer
(`cursors_scalable/`); on the tested GNOME 51.1 it made the pointer invisible
while the Xcursor layer works (51.1 restored Xcursor support; 51.0 had dropped
it). `installDE.sh` therefore **removes `cursors_scalable/` after extracting**
(`DEEPIN_KEEP_SCALABLE="no"`; set it to `"yes"` to keep it). On GNOME 51.0 this
theme would fall back to Adwaita. The tar has no top-level theme directory (it holds
`cursors/`, `cursors_scalable/` and `index.theme`), so it is extracted to a temp
dir and copied to `/usr/share/icons/DeepinV20-dark/` (a wrapper directory
around those items is detected as well; an archive without `index.theme` +
`cursors/` is rejected with a warning). It is applied through each desktop's own
mechanism (`gsettings` + system dconf default for GNOME, `kcminputrc` for KDE,
`xsettings.xml` for XFCE). To go back to Catppuccin as the applied cursor,
replace `DeepinV20-dark` with `catppuccin-mocha-dark-cursors` in those four
places of `installDE.sh`. If the Deepin download fails, a warning is logged and
the desktop falls back to its built-in cursor.

## `lib.sh` — shared helpers

Sourced by all five scripts so the dialog code lives in one place:

- `log` / `info` / `warn` / `die` — coloured only when stdout is a real
  terminal, plain text inside a dialog box (dialog can't render ANSI
  colours), so the same functions work in both. `warn` also appends to
  `$WARN_FILE` when the caller has set it, and `load_warn_file <file>` reads
  those lines back into `WARN_LIST` — needed because the functions run by
  `run_with_gauge` / `run_in_box` live in a subshell and cannot extend the
  parent's array (`setupAfterInstall.sh` and `installDE.sh` use this for their
  closing dialogs)
- `ensure_dialog` — installs `dialog` if missing (`pacman -Sy` on the live
  ISO, plain `pacman -S` on an installed system so it never does a partial
  upgrade)
- `dlg` sizes every `--menu` / `--checklist` itself: whatever height the
  caller passes is replaced by one computed from the real item count and
  text length, so the box is as small as possible, **all items are visible
  at once** (no scrolling for a handful of disks) and the list only scrolls
  when it truly doesn't fit the terminal. (Passing `0 0 0` to dialog does
  *not* do this — it showed a large box with a single visible row.)
- Text sizing and scrolling: `_text_lines` counts the lines of the text
  *after word wrapping* (a `ceil(length / width)` estimate undercounts and the
  last lines get cut off). `msg_box` and `ask_yes` use it: text that fits is
  shown in a plain box, text that does not fit goes to a scrollable `--textbox`
  (`UP`/`DOWN`/`PgUp`/`PgDn`), and `ask_yes` then asks a short yes/no question,
  because a `--yesno` box cannot scroll and its buttons would fall off the
  screen
- `ui_init`, `dlg_capture`, `abort`, `ask_yes`, `msg_box` (never fails,
  so an ESC can't kill a `set -e` script), `ask_text`, `ask_password`
  (asks twice, loops until they match)
- `unit_exists <unit>` — true if a systemd unit file is installed. Uses
  the listing itself, not the exit code of `systemctl list-unit-files`
  (which is 0 even when nothing matched on some systemd versions), and
  works inside a chroot
- Hardware/repo helpers: `detect_gpu_vendors` (amd / intel / nvidia from
  sysfs), `is_laptop` (battery or DMI chassis type), `efi_grub_target`
  (`x86_64-efi` / `i386-efi`), `repo_list_archives <folder>` (theme
  archives in the repo, used to build the theme menus),
  `existing_repo_packages` (drops package names the repos don't have)
- `REPO_RAW_URL` — the single repository URL, overridable with
  `ARCH_REPO_URL`
- `run_in_box <title> <logfile> <function>` — runs a function with live
  output in a dialog box, appended to a log file; the result is left in
  `$RUN_RC`. **Call it as a plain statement and then test `$RUN_RC`** —
  never inside `if`/`&&`/`||`, because bash disables `set -e` for
  everything inside such a call, so a failing command would no longer
  abort the function
- `run_with_gauge <title> <logfile> <function>` — same contract (result in
  `$RUN_GAUGE_RC`), but shows a filling progress bar (`dialog --gauge`);
  the function prints `XXX / percent / text / XXX` frames, which is how the
  phase checklists in the install scripts are drawn
- `run_on_terminal <title> <logfile> <function>` — runs a function directly
  on the terminal (pacman's native progress bar needs a TTY), output also
  logged; result in `$RUN_TTY_RC`

Each script finds `lib.sh` next to itself and downloads it from the repo
if it's missing (if the folder is not writable it keeps the copy in
`$TMPDIR/archInstall-lib.sh` and sources it from there), so a single script can still be fetched and run on its
own.

## Requirements between the scripts

`setupAfterInstall.sh` and `installDE.sh` both assume the exact layout
`archInstall.sh` produces (mountpoints `/efi`, `/boot`, `/.snapshots`,
Btrfs subvolumes, LUKS2, a regular user already created; the LUKS mapper
name and the root subvolume are detected, so they no longer have to be
`cryptroot` / `@`). If you set up
the base system manually instead of using `archInstall.sh`, make sure
it matches that layout first. `installApps.sh` has no such dependency —
it only needs a working `pacman` + `sudo`, so it also works on a
machine that wasn't set up with the other three scripts.
`setupAfterInstall.sh` and `installDE.sh` don't depend on each other and
can run in either order.

## Notes

- `archInstall.sh` asks for confirmation before any destructive action
  (a typed `WIPE`, deliberately kept — a typed word is a better failsafe
  than a default-Enter Yes/No). `setupAfterInstall.sh` and `installDE.sh`
  show a summary and ask before installing/changing anything.
  `installApps.sh` doesn't touch disks or the boot config; what it
  changes besides packages (services, `/etc/pam.d/sudo`,
  `/etc/nsswitch.conf`, the firewall) is listed in the confirmation dialog
  under *System changes*, and only happens for the items you ticked.
- All four scripts back up what they change (where relevant) and are
  safe to re-read before running (`bash -n script.sh` for a
  syntax-only check).
- `setupAfterInstall.sh` and `installDE.sh` both refuse to run as a
  non-root user and instead **re-launch themselves with `sudo`**,
  prompting for your password — you don't need to type `sudo` yourself.
  This matters if you didn't set a root password in `archInstall.sh`
  (root stays locked when you create a sudo user): `sudo` asks for
  *your own* account password, not a root password that doesn't exist.
- CPU microcode (`amd-ucode` / `intel-ucode`) is auto-detected from
  `/proc/cpuinfo` in `archInstall.sh` and `setupAfterInstall.sh` —
  useful if you run these on more than one machine with different CPU
  vendors. The same goes for the GPU stack (`installDE.sh`) and the
  hardware-dependent defaults in `installApps.sh`: one set of scripts for
  an AMD desktop and an Intel-graphics laptop.
- Disk selection in `archInstall.sh` is a dialog menu built from `lsblk`
  — nothing is hardcoded, so the same script works whether the
  disk is `/dev/sda`, `/dev/nvme0n1`, `/dev/vda`, etc. The live USB and
  `zram` devices are filtered out.
- **What is detected vs. configured.** Detected at run time: disks and
  partition names, SSD vs. HDD mount options, CPU microcode, wired NIC for
  WOL, GPU vendor (driver packages, LACT default), laptop vs. desktop
  (CoolerControl default), UEFI bitness (GRUB target), LUKS device, mapper
  name and root subvolume, theme lists. Asked in dialogs: hostname,
  timezone, keymap, user, clock mode and so on. Still constants in the
  config block at the top of each script (edit before running): `ESP_SIZE`,
  `BOOT_SIZE`, `LOCALE`/`LOCALES`, `MOUNT_OPTS`, the Snapper retention
  numbers, `GRUB_BOOTLOADER_ID`, the package lists in `installApps.sh`.
- `archInstall.sh` asks whether the hardware clock should be UTC or
  local time. This only matters if you dual-boot another OS: Windows
  always assumes the hardware clock is local time, while Linux
  defaults to UTC, so with mismatched conventions one of the two OSes
  shows the wrong time. Picking local time here avoids having to change
  a registry key on the Windows side.
- `archInstall.sh` runs `reflector` before `pacstrap` to rank mirrors by
  speed, so both the install itself and everything installed later pull
  from a fast mirror. It's the one non-interactive step that can take a
  little while depending on your connection; a `reflector` failure
  doesn't abort the install; it just falls back to the ISO's default
  mirrorlist.
- Wake-on-LAN in `archInstall.sh` is opt-in (default No) and the interface
  name is always auto-detected, never hardcoded — useful since NIC names
  like `enp39s0` depend on PCI topology and differ between machines. The
  actual `ethtool -s <iface> wol g` call happens on every boot via a
  systemd unit, not just once during install, because most NIC drivers
  reset WOL to off on every boot/link-reset.
- `installApps.sh` must run as your regular user (not root/sudo) —
  `makepkg` and `yay` both refuse to build AUR packages as root. This is
  the opposite of `setupAfterInstall.sh` and `installDE.sh`, which both
  want root.
- `installDE.sh` currently offers three desktop environments: GNOME,
  KDE Plasma (both Wayland) and XFCE. XFCE is installed as an X11
  session, not Wayland, even though the other two options are Wayland —
  XFCE's Wayland support is still experimental/unstable upstream (known
  issues include black screens on login with some GPU/driver
  combinations), so X11 is the stable, working choice there.
- The Reversal icon theme is GNOME-only (it is applied via `gsettings`). The
  DeepinV20-dark cursor (Catppuccin Mocha is installed too) is installed for
  every desktop and applied with each desktop's own mechanism (gsettings/dconf, `kcminputrc`,
  `xsettings.xml`).
- `arch-manager.sh` is a convenience wrapper, not a replacement for
  understanding what each script does — it just saves typing
  `curl`/`chmod`/filenames by hand. Nothing about the four numbered
  scripts changes when run through it.
- **Known limitation: "EFI BootNext" entries.** `setupAfterInstall.sh`
  strips them from `grub.cfg` once, right after generating it. But
  `grub-btrfsd` regenerates `grub.cfg` whenever a snapshot is created or
  deleted, and a plain `grub-mkconfig` does too, so on GRUB versions that
  emit those entries they can reappear (the `zzz-grub-refresh` pacman hook strips
  them again after the next pacman transaction). Remove them again with
  `sudo grub-mkconfig -o /boot/grub/grub.cfg` followed by deleting the
  `(EFI BootNext)` menuentry blocks, or re-run `setupAfterInstall.sh`.
- **PXE / "USB HDD" entries are not os-prober results.** Those names are
  the firmware's own boot entries (network boot, USB boot) in the UEFI boot
  menu (e.g. F9 / Esc on HP laptops) — os-prober only reads partitions,
  never UEFI NVRAM, so no os-prober setting can add or remove them. What the
  "internal" mode fixes is *partition-based* noise: Windows/Linux installers
  on USB sticks, external drives, and similar showing up as GRUB entries. If
  junk still appears **inside the GRUB menu**, look at what was detected with
  `grep -E "^menuentry.*osprober" /boot/grub/grub.cfg` and
  `lsblk -o NAME,UUID,RM,TRAN`, then add the offending `UUID@/dev/part` to
  `GRUB_OS_PROBER_SKIP_LIST` in `/etc/default/grub` and run
  `grub-mkconfig -o /boot/grub/grub.cfg`. The skip list only covers devices
  connected when the script ran.
- Passwords (user, root, LUKS) are asked in password boxes and applied via
  stdin (`chpasswd`, `cryptsetup --key-file=-`) — never as command-line
  arguments, so they don't show up in the process list. They are kept in
  shell variables only until the install ends.
- **Dual boot (e.g. Windows 11 on a gaming PC).** Pick **local time** at the
  hardware-clock question in `archInstall.sh` (Windows assumes the RTC is local
  time) and leave the os-prober mode at **internal** in `setupAfterInstall.sh`.
  The temporary read-only mount of the Windows ESP (`/mnt/win-esp`) used for
  detection is released on every exit path, including a failed run.

## Revision notes (review pass, October 2026)

- **`lib.sh` bootstrap fallback (`archInstall.sh`, `installDE.sh`,
  `setupAfterInstall.sh`, `installApps.sh`)** — when the script folder was not
  writable, `SCRIPT_DIR` was switched to `/tmp` but the file is called
  `archInstall-lib.sh`, so `source "$SCRIPT_DIR/lib.sh"` failed with *No such
  file*. The scripts now keep `SCRIPT_DIR` and use a separate `LIB_FILE`
  (`archInstall.sh` also copies that file to the new system). The downloaded
  `lib.sh` is `chmod 644` before it is moved into place (`mktemp` makes it 0600,
  which a different user could not read).
- **`installApps.sh` — IntelliJ** — `intellij-idea-community-edition` is now only
  a `provides`/`replaces` name of `intellij-idea-oss` in `[extra]`; `pacman -Si`
  does not find a provided name, so the script reported it as not found and
  skipped it. The checklist uses `intellij-idea-oss`.
- **`installApps.sh` — partial upgrade** — `pacman -Sy` followed by installs is a
  partial upgrade. It is now `pacman -Syu`, listed in the confirmation, and the
  run stops (installing nothing) if it fails.
- **`archInstall.sh` — pacman.conf** — `VerbosePkgLists` is uncommented and
  `ILoveCandy` added to `[options]` on the new system (`Color` is left as it is).
- **`archInstall.sh` — NTP** — nothing enabled a time-sync service, so GNOME's
  *Automatic Date & Time* was off. `systemd-timesyncd` is now enabled in the new
  system. *Automatic Time Zone* stays off on purpose (it needs location services
  and would override the timezone chosen in the installer).
- **`installDE.sh` — Deepin SVG layer dropped** — `cursors_scalable/` is removed after
  extraction (see the DeepinV20-dark note above).
- **`installDE.sh` — DeepinV20-dark cursor** — installed from
  `cursor/DeepinV20-dark.tar.xz` in this repo, next to Catppuccin Mocha; Deepin is
  the cursor applied by default.
- **`lib.sh` — `ask_yes`** — a confirmation text taller than the screen is now one
  scrollable screen with **Yes / No** buttons instead of a text box with a single
  *Exit* button followed by a separate *Continue?* question. Affects every
  script's confirmation dialogs.
- **`installApps.sh` — HP discovery under ufw** — added the ufw rules described under
  *Things to know* (found while testing: HP Scan only found the printer with ufw off).
- README: default hostname is `blackbox`, installApps log location, state-aware
  menu and status block of `arch-manager.sh` (option 1 does not ask on a
  non-live system, it refuses), `/root/arch-install-state.conf`, a note on the
  snapshot/hook load of bulk installs.
- Checked, no change: `bash -n` and `shellcheck` clean; the other scripts' logic
  (partitioning, LUKS/Btrfs, GRUB cmdline, snapshot tooling) read through without
  finding further bugs. Not run on real hardware.

## Revision notes (bug-fix pass)

New in this pass: **bootable, writable snapshots with matching kernels** —
see [Booting a snapshot after a bad update](#booting-a-snapshot-after-a-bad-update)
(`arch-kernel-archive`, the `99-kernel-archive` pacman hook, the
`42_snapshot-kernels` GRUB generator and `arch-snapshot-promote`, all installed
by `setupAfterInstall.sh`).

Fixed in the scripts:

- `archInstall.sh` — the *Regional formats* menu listed a tag twice when the
  chosen language was `hr_HR` or `en_US`; `reflector` is now installed with
  `pacman -Sy` on the live ISO (a plain `-S` fails on a stale database).
- `setupAfterInstall.sh` — warnings raised during the run were lost (the run
  is a subshell) and are now shown in the closing dialog; the temporary
  Windows-ESP mount is unmounted even when the setup fails midway.
- `installDE.sh` — added PipeWire (no sound on KDE/XFCE before); a pacman
  failure now reports its exit code instead of the generic "Failed at line"
  from the ERR trap; warnings from the install phase reach the final dialog.
- `installApps.sh` — the sudoers drop-in is staged under a name sudo ignores
  and validated *before* it becomes active (a syntax error could previously
  leave sudo unusable, including for the cleanup that removes the file);
  `peazip`, `python-pyqt5` and `intellij-idea-community-edition` moved to the
  official-repo lists, with a `yay` fallback for packages that move between
  the repos and the AUR; ESC at the "Extra packages" box now aborts as
  documented; the drop-in uses `id -un` instead of `$USER`; added `fprintd`
  and `imagemagick` (fingerprint support) to the base set, an optional
  *Fingerprint for sudo* PAM step (3 s timeout, backup of the PAM file,
  laptop default on) and an explanatory comment to every entry of the
  package arrays.
- `installApps.sh` (later passes) — printer support moved out of the base set
  into optional groups; every group (optional, work, printer, office/fonts,
  multimedia, system) is now a per-package checklist that widens to the
  longest row and scrolls; `dbeaver`, GSConnect, LocalSend, `ufw`/`gufw` and
  more were added. Fixes: **`ufw.service` is now enabled** (the firewall
  used to vanish after a reboot); SSH is allowed before the firewall is
  enabled; the CUPS port rules were dropped (CUPS listens on localhost, mDNS
  is covered by the default rules) and the mDNS edit needs `avahi` as well as
  `nss-mdns`; a stale `99-installer-timestamp` sudoers drop-in from a killed
  run is now removed (it used to stay and keep passwordless sudo active);
  `JAVA_PKG` is used as the checklist tag (changing it no longer breaks the
  mapping); duplicate packages are removed; names in the "AUR" list that
  are in the official repos go through pacman; the confirmation lists
  *System changes*; the progress tree shows the step that is really running.
- `installApps.sh` — new *VPN (NetworkManager)* checklist so VPN connections
  can be created from the desktop network menu: `wireguard-tools` (WireGuard
  itself is native to NetworkManager) and `networkmanager-openconnect` (Cisco
  AnyConnect and F5), `networkmanager-vpnc` and `networkmanager-openvpn`. Check
  Point has no NetworkManager plugin, so its native client `snx-rs` is listed
  in the same dialog (moved there from *Work programs*). The *Work programs*
  and *VPN* checklists now start with every row ticked.
- `lib.sh` — `WARN_FILE` / `load_warn_file` (see above); `_text_lines` counts
  wrapped lines, `msg_box` / `ask_yes` scroll tall texts instead of cutting
  them off (a tall confirmation used to push the Yes/No buttons off the screen).
- `arch-manager.sh` — reviewed, no changes needed.

All six scripts pass `bash -n` and `shellcheck` (re-checked in the October 2026 pass).
