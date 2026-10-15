----------

NOTE - This is a hobby project created primarily for my personal needs. 

----------


# Arch Linux: LUKS2 + Btrfs + Snapper + DE + apps install scripts

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
   (`monarch`, `Europe/Zagreb`, `us`) and validated (hostname syntax, the
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
   NetworkManager, zram swap, a templated `wol@.service`
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
9. Closing dialog with the next steps and *"Unmount everything and reboot
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
   already there; a failed download only warns
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
(Catppuccin Mocha cursor) and `plasma-localerc` (regional formats + UI
language, read from `LANG` in `/etc/locale.conf`) are written with the
user's ownership — KDE ignores config files owned by root. Existing files
are merged in place, not overwritten.

**XFCE:** there is no way to preset settings through a session bus from a
chroot, so they are written as the user's own xfconf channel files, which
XFCE reads on first login: `xsettings.xml` (Adwaita-dark, Adwaita icons,
Catppuccin Mocha cursor), `xfwm4.xml` and `xfce4-panel.xml` (a panel whose
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
2. **Optional packages checklist** — defaults shown below (Enter
   without touching anything gives you these):

   | Item | Package(s) | Default |
   |------|-----------|---------|
   | Lact (AMD GPU control/overclock) | `lact` (repo) | **on** only if an AMD GPU is detected, otherwise off |
   | CoolerControl (fan/cooling control) | `coolercontrol-bin` (AUR) | **on** on a desktop, **off** on a laptop (battery / DMI chassis type) |
   | Nautilus "Open as Administrator" | `nautilus-admin-gtk4` (AUR) | **on** — only listed if GNOME is detected |
   | LibreOffice | `libreoffice-still` (repo) | off |
   | WPS Office | `wps-office` + `ttf-wps-fonts` (AUR) | off |
   | OnlyOffice | `onlyoffice-bin` (AUR) | off |

3. **Work programs** yes/no box — defaults to **No**. The box lists the
   exact packages so you know what you're agreeing to: `jdk11-openjdk`,
   `meld`, `code` (open-source VS Code build), `remmina` and
   `intellij-idea-community-edition` from the repos (the official `extra`
   package; it may pull in a newer JDK as a dependency, which is harmless
   because the work JDK is set as the default afterwards), plus `postman-bin`,
   `f5vpn-ng`
   (F5 BIG-IP APM VPN client — can occasionally need a library fix after
   a libxml2/webkit2gtk update), `ferdium-bin`, `snx-rs` (Check Point
   VPN client, slow Rust build) from AUR — useful for splitting a
   personal machine from a work machine without editing the script
4. **Extra packages** input box (space-separated, blank to skip) —
   official-repo and AUR names both work. Only plain package names are
   accepted; anything starting with `-` (which pacman/yay would treat as
   an option, e.g. `--overwrite`) is ignored with a message; ESC aborts, as in every other dialog
5. **Confirmation** box showing the final repo / AUR / extra lists;
   answering No (or `ESC`) at any dialog above aborts cleanly
6. Installs unattended, with live output in a dialog box (also saved to
   `~/installApps.log`):
   - bootstraps `yay` if missing (`base-devel` + `git` via `pacman`, then
     `yay` itself built from AUR with `makepkg`). If that build fails the
     run **continues** with the official-repo packages; the AUR packages
     are then listed as FAILED ("yay is not available") instead of the
     whole run stopping
   - always-installed base set — **Repo:** `terminator`, `guake`,
     `qmmp`, `kolourpaint`, `mission-center`, `stow`, `eza`, `peazip`,
     `hplip` + `cups` + `system-config-printer` + `python-pyqt5` (printer
     support; PyQt5 is needed for `hp-setup`'s GUI); **AUR:**
     `google-chrome`, `sublime-text-4`
   - then whatever you picked above
7. Every package — list-defined or typed in — is checked with
   `pacman -Si` / `yay -Si` before install; unknown/typo'd names are
   skipped with a warning instead of aborting the whole run. A package
   listed as "repo" that is no longer in the official repos (packages do
   move between the two: `peazip` is in `extra` now but used to be AUR-only)
   is handed to `yay` instead of being skipped. Genuine
   install failures (found, but errored) are collected and reported,
   not fatal to the rest of the run
8. Sets the work JDK as the default JVM (`archlinux-java set`) if it was
   installed (part of the work bundle) — the package and its
   `archlinux-java` name are the two variables `JAVA_PKG` / `JAVA_ENV` at
   the top of the script (default `jdk11-openjdk` / `java-11-openjdk`),
   enables the CUPS service and, if they were installed, the root daemons
   behind the GUIs: `lactd.service` (LACT) and `coolercontrold.service`
   (CoolerControl) — the packages install them but don't start them
9. Final summary dialog: what was skipped/failed, and manual next steps
   (`hp-setup` for the actual printer; a note about `snx-rs` build time
   and `f5vpn-ng` library fixes, shown only if those were selected)

You can re-run `installApps.sh` any time later to add more software —
it's idempotent (`--needed` skips already-installed packages) and shows
the dialogs every time.

### `arch-manager.sh` — optional dialog menu

Not part of the numbered phases — a convenience front-end that downloads
`lib.sh` and the four scripts from the repo and lets you run them from a
menu instead of typing filenames. A status line (Arch? Live ISO? root?
Btrfs? Snapper?) is shown above the menu every time.

Menu:

1. **Install Arch** — runs `archInstall.sh`. If you're *not* on the live
   ISO it asks first (default No), since that script wipes a disk. On
   success the manager exits so you can reboot; `archInstall.sh` itself
   already put the manager and all scripts into `/archInstall/` on the new
   system
2. Run `setupAfterInstall.sh` only
3. Run `installDE.sh` only
4. Run `installApps.sh` only
5. **Install all after reboot:** `setupAfterInstall.sh` → `installDE.sh` →
   `installApps.sh`. `installDE.sh` is skipped (with a question, default
   No) if a desktop is already installed — e.g. you chose one in
   `archInstall.sh`. If a step fails it asks whether to continue
6. Download / update all scripts now

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
  `--install` (fetch + run **only** `archInstall.sh`), or
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
| `/usr/local/sbin/arch-snapshot-promote` | Makes the snapshot you are booted from the permanent root (see below). |
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
3. Work normally. Don't run the update that broke things. `/home` is a separate
   subvolume, so your files are the same as in the normal system.
4. **When the fix is available**, either boot the normal first entry and
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
if it's missing, so a single script can still be fetched and run on its
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
  `installApps.sh` doesn't touch disks/boot config at all, so it only
  shows a confirmation dialog with the package list.
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
  Catppuccin Mocha cursor is installed for every desktop and applied with
  each desktop's own mechanism (gsettings/dconf, `kcminputrc`,
  `xsettings.xml`).
- `arch-manager.sh` is a convenience wrapper, not a replacement for
  understanding what each script does — it just saves typing
  `curl`/`chmod`/filenames by hand. Nothing about the four numbered
  scripts changes when run through it.
- **Known limitation: "EFI BootNext" entries.** `setupAfterInstall.sh`
  strips them from `grub.cfg` once, right after generating it. But
  `grub-btrfsd` regenerates `grub.cfg` whenever a snapshot is created or
  deleted, and a plain `grub-mkconfig` does too, so on GRUB versions that
  emit those entries they can reappear. Remove them again with
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
  documented; the drop-in uses `id -un` instead of `$USER`.
- `lib.sh` — `WARN_FILE` / `load_warn_file` (see above).
- `arch-manager.sh` — reviewed, no changes needed.

All six scripts pass `bash -n` and `shellcheck`.
