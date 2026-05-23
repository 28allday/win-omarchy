# Win-Omarchy

Patch the [Omarchy](https://omarchy.com) installer ISO to install Omarchy alongside an
existing Windows 11 system, with LUKS2 encryption and btrfs snapshots. After install the
machine boots the **Limine menu first on every power-on** — no F12, no firmware boot-menu
interaction — and Windows is offered as a menu entry alongside Omarchy and bootable
snapshots.

[![Win-Omarchy demo](https://img.youtube.com/vi/Bxb4HwsUO34/maxresdefault.jpg)](https://youtu.be/Bxb4HwsUO34)

Forked from [Dual-Boot-Omarchy](https://git.no-signal.uk/nosignal/Dual-Boot-Omarchy).

## How Limine-first boot is guaranteed

Many consumer firmwares ignore the UEFI boot order and always boot
`\EFI\Microsoft\Boot\bootmgfw.efi` (the Windows Boot Manager), so a normal Linux
bootloader never appears. Rather than rely on boot order, the installer **replaces
`bootmgfw.efi` with Limine** and preserves the genuine Windows loader alongside it as
`bootmgfwbackup.efi`. When the firmware boots "Windows Boot Manager" it launches Limine,
which then offers Omarchy and chainloads the real Windows loader on demand. An
`efibootmgr` BootOrder lock is also set as best-effort for firmware that honours it.

## Requirements

- **OS to run the patcher**: Arch Linux or Omarchy
- **Omarchy ISO**: from [omarchy.com](https://omarchy.com) — version-agnostic (tested through 3.8)
- **UEFI** firmware (no legacy BIOS)
- **20GB+ unallocated space** on the target drive
- **USB drive** for booting the patched ISO
- **Secure Boot OFF** — Limine is unsigned; with Secure Boot on the firmware silently
  rejects it and falls through to Windows. The installer detects this and stops by default.

## Before installing — BitLocker / Device Encryption

Changing the bootloader changes the TPM PCR 4/7 measurements, so Windows may demand the
48-digit BitLocker recovery key on its next boot. Before booting the installer USB, in
Windows:

1. **Back up your recovery key** (`https://account.microsoft.com/devices/recoverykey` or
   Settings → Privacy & security → Device encryption → Back up your recovery key).
2. **Suspend BitLocker** in an admin PowerShell:
   ```powershell
   manage-bde -protectors -disable C: -RebootCount 0
   ```
3. **Shut down fully** (not "Restart" — Fast Startup leaves the NTFS dirty):
   `shutdown /s /f /t 0`

The installer will not proceed past Windows detection until you confirm you have the key.

## Quick start

```bash
# 1. Clone the repo
git clone https://github.com/28allday/win-omarchy.git
# (or the Forgejo mirror: git clone https://git.no-signal.uk/nosignal/win-omarchy.git)
cd win-omarchy

# 2. Put your Omarchy ISO in this directory and run the patcher
sudo ./patch-win-omarchy.sh

# Or point it at the ISO directly (from anywhere):
sudo ./patch-win-omarchy.sh /path/to/omarchy-3.8.0.iso
```

This produces `win-omarchy-YYYY.MM.DD.iso`. It's a hybrid ISO — write it to USB with
`dd` (or Ventoy) and boot the target machine from it.

## Installer menu

| # | Option | Action |
|---|--------|--------|
| 1 | Dual Boot (Heaven and Hell mode) | Install Omarchy alongside Windows (dual-boot) |
| 2 | Consider that a divorce | Remove a failed/old install; restores the genuine Windows bootloader |
| 3 | Nuke the site from orbit | Standard install — wipes the whole drive (no dual-boot) |
| 4 | Exit to Ghost in the… | Drop to a terminal |
| 5 | I'll be back | Repair: re-apply Limine after a Windows update overwrote it |

### Option 1 — Dual-boot install

1. Drive selection (auto-detects a single non-USB drive; detects Windows)
2. Free-space check (20GB+)
3. LUKS2 encryption password
4. Partitioning in free space: 1GB `LINUXEFI` (FAT32) + LUKS2 root
5. Btrfs subvolumes: `@`, `@home`, `@log`, `@pkg`
6. Omarchy configurator (username, hostname, timezone, keyboard)
7. `archinstall` base system + full Omarchy desktop (offline, from the ISO)
8. Limine + unified kernel image (encrypt hook), snapper, Plymouth
9. **bootmgfw spoof** + Windows chainload entry (by GPT PARTUUID) + BootOrder lock

Windows partitions are untouched apart from the single `bootmgfw.efi` swap (original
preserved as `bootmgfwbackup.efi`).

### Option 5 — Repair after a Windows update

A Windows **feature update** can reinstall `bootmgfw.efi`, overwriting Limine; the
machine then boots straight to Windows and the Limine menu disappears. Option 5 re-applies
the spoof — refreshing the backup with the current Windows loader and re-installing
Limine. It is idempotent (does nothing if the spoof is already intact).

## Target drive layout

```
Drive:
├── Windows partitions (preserved)
│   └── EFI System Partition
│       ├── EFI/Microsoft/Boot/bootmgfw.efi        ← replaced with Limine
│       └── EFI/Microsoft/Boot/bootmgfwbackup.efi  ← original Windows loader (chainloaded)
├── LINUXEFI (1GB FAT32)          ← Limine, EFI/Linux/omarchy_linux.efi (UKI), limine.conf
└── Linux root (LUKS2 → btrfs)    ← @ / @home / @log / @pkg
```

## How the patcher works

Extracts the ISO and its squashfs, injects a dual-boot setup script into the live
environment, re-points the boot sequence to run it on tty1, then repacks the squashfs and
rebuilds the ISO via `xorriso` boot-image replay — preserving the original MBR/GPT/El
Torito layout byte-for-byte, so it works across Omarchy versions without per-version
tweaks. Build dependencies (`xorriso`, `squashfs-tools`, `cdrtools`) are installed
automatically if missing.

## Troubleshooting

**Boots straight to Windows, no Limine menu.** A Windows feature update likely reinstalled
its bootloader over the spoof — boot the USB and run **option 5**. On a fresh install that
never showed Limine, confirm **Secure Boot is OFF**.

**No LUKS prompt / won't unlock.** Check the encrypt hook:
`lsinitcpio /boot/EFI/Linux/omarchy_linux.efi | grep encrypt`, then `sudo mkinitcpio -P`.

**Windows missing from the Limine menu.** The entry chainloads `bootmgfwbackup.efi` on the
Windows ESP by GPT PARTUUID — verify it's present in `/boot/limine.conf` and on the ESP.
(`FIND_BOOTLOADERS` does **not** detect Windows; the entry is written explicitly.)

**Failed install left orphan partitions.** Boot the USB and pick **option 2** — it removes
the Linux partitions and restores the genuine Windows bootloader.

## Uninstalling (keeping Windows)

Boot the USB and choose **option 2**: restores the real `bootmgfw.efi`, removes the Linux
EFI + LUKS partitions, cleans up UEFI entries. Reclaim the free space from Windows Disk
Management.

## Credits

- [Omarchy](https://omarchy.com) — Arch-based distribution
- [archinstall](https://github.com/archlinux/archinstall) — Arch installer framework
- [Limine](https://limine-bootloader.org/) — bootloader
- [Snapper](http://snapper.io/) — btrfs snapshot management

## License

Provided as-is for the Omarchy community.
