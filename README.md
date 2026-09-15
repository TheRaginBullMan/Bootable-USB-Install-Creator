# Bootable USB Creator

`BootableUsbIsoInstallation.ps1` turns a USB flash drive into a bootable FAT32 drive and, optionally, fills it from a Windows or Linux installation ISO.

For Windows media it follows Microsoft's documented procedure, [Install Windows from a USB flash drive](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/install-windows-from-a-usb-flash-drive?view=windows-11), including splitting `install.wim` with DISM when it exceeds the FAT32 4 GB file limit. For Linux and other media it copies the ISO contents so the drive boots via UEFI.

## What it does

1. Requests administrator rights through the standard UAC prompt if it was started as a regular user.
2. Prompts for an ISO path if none was given. An empty answer means "format only".
3. Mounts the ISO and identifies the media before any drive is touched.
4. Lists USB disks only. Internal disks are never shown and cannot be selected.
5. Validates the chosen disk against a safety gate with no override.
6. Asks for the word `ERASE` before making any change.
7. Partitions and formats the drive as FAT32 with an active MBR partition, capped at 32 GB.
8. Copies the ISO contents with robocopy, splitting or copying the Windows install image as needed.
9. Dismounts the ISO and leaves the console in the script's folder.

Long-running steps show an elapsed-time counter so you can tell the script is still working.

## Requirements

- Windows 10 or Windows 11 with Windows PowerShell 5.1. The script has also been written to run under PowerShell 7 but has only been tested on 5.1.
- Administrator rights. The script elevates itself if needed.
- The built-in Storage and DISM PowerShell modules, plus `robocopy.exe` and `dism.exe`, all of which ship with Windows.
- A USB drive. Everything on it will be erased.

## Usage

Run from any PowerShell window. If the window is not elevated, a UAC prompt appears and the script continues in a new elevated window.

```powershell
# Fully interactive: prompts for the ISO and the target disk
.\BootableUsbIsoInstallation.ps1

# Windows ISO onto disk 2
.\BootableUsbIsoInstallation.ps1 -IsoPath C:\ISO\Win11_25H2.iso -DiskNumber 2

# Linux ISO onto the drive currently lettered E:
.\BootableUsbIsoInstallation.ps1 -IsoPath C:\ISO\ubuntu-24.04-desktop-amd64.iso -UsbDriveLetter E

# Format only, no ISO: creates an empty bootable FAT32 drive labeled BootableUsb
.\BootableUsbIsoInstallation.ps1 -IsoPath '' -DiskNumber 2
```

### Parameters

| Parameter | Description |
|---|---|
| `-IsoPath` | Path to a Windows or Linux ISO. Prompted for if omitted. Empty means format only. A relative path is resolved against the directory the script was started from. |
| `-DiskNumber` | Disk number of the target USB drive, as shown by `Get-Disk` or Disk Management. |
| `-UsbDriveLetter` | Current drive letter of the target drive, for example `E` or `E:`. Resolved to the disk number for you. Wins over `-DiskNumber` if both are given. |

If neither disk parameter is supplied, the script lists the USB disks and prompts. Either a disk number or a drive letter is accepted at the prompt.

## How the drive is named

FAT32 volume labels are limited to 11 characters and cannot contain `* ? . , ; : / \ | + = < > [ ] "`. The script derives a label from the media and cleans it to fit.

| Media | Label |
|---|---|
| No ISO | `BootableUsb` |
| Windows 11 client | `Windows 11` |
| Windows 10 client | `Windows 10` |
| Windows Server | `WinSrv 2025` style, or `Win Server` if no year is found |
| Linux with identifiable name | Distribution name, for example `Ubuntu 2404`, `Debian 1270`, `Rocky Linux` |
| Anything else | First 11 characters of the ISO's own volume label |

Windows editions are read from `sources\install.wim` or `install.esd`. Linux names are taken, in order, from `.disk/info` (Debian and Ubuntu), `.treeinfo` or `.discinfo` (Fedora, RHEL, Rocky, Alma, CentOS), the first GRUB menu entry, systemd-boot entries, or isolinux/syslinux menu titles.

## Safety

The script refuses to proceed, before anything is changed, when the selected disk:

- is not on the USB bus (blocks SATA, NVMe, RAID and SAS disks)
- is the system disk or the boot disk
- is write-protected
- contains a Windows installation

It also refuses when the ISO would not fit, when a non-image file exceeds 4 GB, or when a Windows ISO carries an `install.esd` over 4 GB, which DISM cannot split. All of these checks run before the ERASE prompt, so a refusal costs nothing.

## Limitations

- **FAT32 caps the partition at 32 GB.** Larger drives get a 32 GB partition and the rest is left unallocated. On some removable drives Windows keeps a single full-size partition after the erase, which makes FAT32 formatting impossible. The script warns about this before erasing such a drive.
- **Linux media boots via UEFI only.** Copying files does not write MBR boot code, so legacy BIOS boot is not available for non-Windows media. Windows media boots both ways.
- **Some distributions locate their media by volume label**, notably the Fedora and RHEL family (`inst.stage2=hd:LABEL=...`). Their original label does not fit FAT32, so the installer may not find its files. The script warns when it detects this. Editing `LABEL=` in `grub.cfg` on the USB drive, or writing the ISO with a tool such as Rufus, resolves it.
- **An unattend file is not added.** The Microsoft article lists it as an optional step.

## Working directory

The script switches to its own folder at startup and returns there on every exit path. Running it from an interactive PowerShell window therefore leaves that window in the script's folder. The elevated window is kept open after the run so its output stays readable, and it also ends in the script's folder.

## Troubleshooting

- **"DISM failed" or "robocopy failed"**: the last lines of the tool's output are printed above the error.
- **"still uninitialized after Initialize-Disk"**: initialize the disk as MBR in Disk Management and re-run.
- **"reports no free space after being cleared"**: run `diskpart`, `select disk N`, `clean`, then re-run.
- **A drive over 32 GB stops after the erase**: use a 32 GB or smaller stick, an external hard disk, or Rufus with an NTFS layout.
- **UAC declined**: open PowerShell with "Run as administrator" and re-run.

## Repository

| File | Purpose |
|---|---|
| `BootableUsbIsoInstallation.ps1` | The script |
| `README.md` | This document |
