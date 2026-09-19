<#
.SYNOPSIS
    Creates a bootable USB flash drive, optionally populated from a Windows or
    Linux installation ISO.

.DESCRIPTION
    - Formats the drive as FAT32 (boots both UEFI and legacy BIOS PCs)
    - Caps the FAT32 partition at 32 GB (Windows format limit)
    - No ISO given: partitions and formats the drive, labels it 'BootableUsb', and ends
    - Windows ISO: labels the drive after the media ('Windows 11', 'Windows 10',
      'WinSrv 2025', ...), copies Windows Setup, and splits install.wim with DISM
      when it exceeds the FAT32 4 GB file limit, per Microsoft's procedure
    - Other ISO (Linux etc.): labels the drive after the distribution when it can be
      identified from the media, otherwise after the ISO's own volume label, then
      copies the full ISO contents
    - SAFETY: refuses to touch any disk that is not on the USB bus, or that
      is the system/boot disk, is write-protected, or hosts a Windows installation.
    - Started as a regular user, it re-launches itself elevated via the
      standard UAC prompt, forwarding the same parameters.

    Based on: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/install-windows-from-a-usb-flash-drive?view=windows-11

.PARAMETER IsoPath
    Full path to an installation ISO (Windows or Linux). Prompted for if omitted.
    Leave the prompt empty, or pass -IsoPath '', to skip the ISO: the drive is
    then only partitioned and formatted (label 'BootableUsb') and nothing is copied.
    A relative path is resolved against the directory the script was started from.

.PARAMETER DiskNumber
    Disk number of the target USB drive.

.PARAMETER UsbDriveLetter
    Current drive letter of the target USB drive (e.g. E or E:).
    The script resolves it to the underlying disk number for you.

    If neither DiskNumber nor UsbDriveLetter is supplied, you are
    prompted and may enter either one. The disk is validated by the
    safety gate regardless of how it was identified.

.EXAMPLE
    .\BootableUsbIsoInstallation.ps1
    .\BootableUsbIsoInstallation.ps1 -DiskNumber 2
    .\BootableUsbIsoInstallation.ps1 -IsoPath C:\ISO\Win11_25H2.iso -DiskNumber 2
    .\BootableUsbIsoInstallation.ps1 -IsoPath C:\ISO\ubuntu-24.04-desktop-amd64.iso -UsbDriveLetter E

.NOTES
    FAT32 volume labels are limited to 11 characters and cannot contain
    * ? . , ; : / \ | + = < > [ ] "  - names are trimmed and cleaned to fit.

    Non-Windows media copied file-by-file boots via UEFI only (no MBR boot
    code is written). Distributions whose boot loader locates the media by
    volume label (Fedora/RHEL family: inst.stage2=hd:LABEL=...) may need
    the label in grub.cfg adjusted; the script warns when it sees this.

    The script always ends with the working directory set to its own folder,
    in the calling console and in the elevated console alike.
#>

[CmdletBinding()]
param(
    [string]$IsoPath,
    [int]$DiskNumber = -1,
    [string]$UsbDriveLetter
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------
# Constants
# ------------------------------------------------------------
$Fat32MaxFileBytes   = 4294967295          # 4 GB - 1 byte
$Fat32MaxPartition   = 32GB                # Windows won't FORMAT FAT32 above this
$Fat32MaxLabelLength = 11
$DefaultLabel        = 'BootableUsb'
$RobocopyCommonArgs  = @('/r:1', '/w:1', '/njh', '/njs', '/ndl', '/nc', '/ns', '/np', '/a-:R')
                       # /r:1 /w:1 - without these robocopy retries a failed file
                       # 1,000,000 times at 30 s intervals, which looks like a hang.
                       # /a-:R - files on an ISO are read-only; copies should not be.

# ------------------------------------------------------------
# Console output helpers - every console write goes through these
# ------------------------------------------------------------
function Write-Step     { param($Text) Write-Host "`n$Text" -ForegroundColor Cyan }
function Write-Info     { param($Text, [switch]$NoNewline, [switch]$Overwrite)
                          # -Overwrite redraws the current console line in place (status/timer lines)
                          $prefix = if ($Overwrite) { "`r     " } else { "     " }
                          Write-Host "$prefix$Text" -NoNewline:$NoNewline }
function Write-Warn     { param($Text) Write-Host "[WARNING] $Text" -ForegroundColor Yellow }
function Write-Fatal    { param($Text) Write-Host "[ERROR] $Text" -ForegroundColor Red; exit 1 }
function Write-Success  { param($Text) Write-Host "$Text" -ForegroundColor Green }

# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------
function Resolve-DiskNumberFromLetter {
    param([string]$Letter)
    # Accept "E", "E:", or "E:\"
    $Letter = $Letter.Trim().TrimEnd('\').TrimEnd(':').ToUpper()
    if ($Letter -notmatch '^[A-Z]$') { Write-Fatal "Invalid drive letter: '$Letter'" }
    $partition = Get-Partition -DriveLetter $Letter -ErrorAction SilentlyContinue
    if (-not $partition) { Write-Fatal "No partition found with drive letter ${Letter}: - is the drive connected and formatted?" }
    Write-Info "Drive ${Letter}: is on disk $($partition.DiskNumber)."
    return [int]$partition.DiskNumber
}

# Make any text a legal FAT32 volume label: strip forbidden characters,
# collapse whitespace, keep the first 11 characters. Empty -> default label.
function ConvertTo-Fat32Label {
    param([string]$Text)
    if (-not $Text) { return $DefaultLabel }
    $clean = ($Text -replace '[\*\?\.,;:/\\\|\+=<>\[\]"]', '') -replace '\s+', ' '
    $clean = $clean.Trim()
    if ($clean.Length -gt $Fat32MaxLabelLength) {
        $clean = $clean.Substring(0, $Fat32MaxLabelLength).Trim()
    }
    if (-not $clean) { return $DefaultLabel }
    return $clean
}

# Read "key = value" from one [section] of an INI-style file (.treeinfo).
function Get-IniValue {
    param([string]$Path, [string]$Section, [string]$Key)
    $inSection = $false
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*\[(.+?)\]\s*$') { $inSection = ($Matches[1] -eq $Section); continue }
        if ($inSection -and $line -match "^\s*$Key\s*=\s*(.+?)\s*$") { return $Matches[1] }
    }
    return $null
}

# Removable media (USB flash sticks, RMB bit set) vs. fixed/external hard disks.
# Get-Disk does not expose this; Win32_DiskDrive.Index matches Get-Disk.Number.
function Test-RemovableDisk {
    param([int]$Number)
    $drive = Get-CimInstance -ClassName Win32_DiskDrive -Filter "Index = $Number" -ErrorAction SilentlyContinue
    return [bool]($drive -and $drive.MediaType -like 'Removable*')
}

# Run an external program with its console output captured, showing a single
# in-place elapsed-time line so the user can see the script is still working.
# Returns the exit code. stdout/stderr are left in the given log files.
function Invoke-ProcessWithTimer {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$Activity,
        [string]$OutLog,
        [string]$ErrLog
    )
    $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru `
                          -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog
    # Touching .Handle caches it while the process is alive. Without this,
    # Start-Process -PassThru leaves .ExitCode unreadable once the process exits.
    $null  = $proc.Handle
    $start = Get-Date

    # Redrawn in place (Write-Info -Overwrite) rather than Write-Progress: the Windows
    # PowerShell 5.1 console host pins Write-Progress to the top of the window.
    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 1
        Write-Info -Overwrite -NoNewline ("{0}  elapsed {1:hh\:mm\:ss}" -f $Activity, ((Get-Date) - $start))
    }
    $proc.WaitForExit()
    Write-Info -Overwrite ("{0}  elapsed {1:hh\:mm\:ss}  done" -f $Activity, ((Get-Date) - $start))
    return $proc.ExitCode
}

function Show-LogTail {
    param([string[]]$Paths, [int]$Lines = 30)
    $tail = @(Get-Content -LiteralPath $Paths -ErrorAction SilentlyContinue | Select-Object -Last $Lines)
    # Blank line, then each log line indented to align with Write-Info's prefix.
    Write-Info ("`n     " + ($tail -join "`n     "))
}

# Windows media: install image details and a label derived from the image
# metadata. Returns $null when the ISO is not Windows media.
function Get-WindowsMediaInfo {
    param([string]$Root, [string]$VolumeLabel)   # Root like 'X:\'

    $imagePath = $null
    foreach ($name in 'install.wim', 'install.esd') {
        $p = Join-Path $Root "sources\$name"
        if (Test-Path -LiteralPath $p -PathType Leaf) { $imagePath = $p; break }
    }

    if ($imagePath) {
        $result = [pscustomobject]@{
            Name      = 'Windows (edition could not be read from the install image)'
            Label     = $VolumeLabel
            ImagePath = $imagePath
            ImageSize = (Get-Item -LiteralPath $imagePath).Length
            IsEsd     = $imagePath -like '*.esd'
        }

        $img = $null
        try { $img = Get-WindowsImage -ImagePath $imagePath -Index 1 -ErrorAction Stop } catch { }
        if ($img) {
            $build = 0
            if ($img.Version -match '^\d+\.\d+\.(\d+)') { $build = [int]$Matches[1] }
            $result.Name = "$($img.ImageName) (build $build)"

            if ($img.InstallationType -like 'Server*' -or $img.ImageName -match 'Windows Server') {
                if ($img.ImageName -match 'Server\s+(\d{4})') { $result.Label = "WinSrv $($Matches[1])" }
                else                                           { $result.Label = 'Win Server' }
            }
            elseif ($build -ge 22000)                               { $result.Label = 'Windows 11' }
            elseif ($build -ge 10240)                               { $result.Label = 'Windows 10' }
            elseif ($img.ImageName -match 'Windows\s+(\d+(\.\d)?)') { $result.Label = "Windows $($Matches[1])" }
            else                                                    { $result.Label = 'Windows' }
        }
        return $result
    }

    if ((Test-Path -LiteralPath (Join-Path $Root 'bootmgr')) -or
        (Test-Path -LiteralPath (Join-Path $Root 'sources\boot.wim'))) {
        # Windows boot media without an install image (WinPE, recovery, ...)
        return [pscustomobject]@{
            Name = 'Windows boot media (no install image)'; Label = $VolumeLabel
            ImagePath = $null; ImageSize = 0; IsEsd = $false
        }
    }
    return $null
}

# Linux / other media: a distribution name from the usual metadata files or
# boot menus (may be $null), plus any LABEL= references its boot config uses.
function Get-LinuxMediaName {
    param([string]$Root)   # Root like 'X:\'

    $name = $null

    # Debian / Ubuntu family:  Ubuntu 24.04.1 LTS "Noble Numbat" - Release amd64 (...)
    $diskInfo = Join-Path $Root '.disk\info'
    if (Test-Path -LiteralPath $diskInfo -PathType Leaf) {
        $line = Get-Content -LiteralPath $diskInfo -TotalCount 1 -ErrorAction SilentlyContinue
        if ($line) {
            $name = (($line -split ' - ', 2)[0] -replace '\s*".*?"\s*', ' ' -replace '\s*GNU/Linux\s*', ' ').Trim()
        }
    }

    # Fedora / RHEL / Rocky / Alma / CentOS:  .treeinfo [general] name = Rocky Linux 9.4
    if (-not $name) {
        $treeInfo = Join-Path $Root '.treeinfo'
        if (Test-Path -LiteralPath $treeInfo -PathType Leaf) {
            $name = Get-IniValue -Path $treeInfo -Section 'general' -Key 'name'
        }
    }
    if (-not $name) {
        $discInfo = Join-Path $Root '.discinfo'          # line 2 = "Fedora 40"
        if (Test-Path -LiteralPath $discInfo -PathType Leaf) {
            $lines = @(Get-Content -LiteralPath $discInfo -TotalCount 2 -ErrorAction SilentlyContinue)
            if ($lines.Count -ge 2 -and $lines[1].Trim()) { $name = $lines[1].Trim() }
        }
    }

    # Boot menu titles: GRUB menuentry, systemd-boot entries, isolinux/syslinux labels
    $grubCfgs = @(@('boot\grub\grub.cfg', 'boot\grub2\grub.cfg', 'EFI\BOOT\grub.cfg', 'EFI\boot\grub.cfg') |
                    ForEach-Object { Join-Path $Root $_ } |
                    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                    Select-Object -Unique)

    if (-not $name) {
        foreach ($cfg in $grubCfgs) {
            $m = Select-String -LiteralPath $cfg -Pattern '^\s*menuentry\s+[''"]([^''"]+)[''"]' | Select-Object -First 1
            if ($m) { $name = $m.Matches[0].Groups[1].Value; break }
        }
    }
    if (-not $name) {
        $entry = Get-ChildItem -LiteralPath (Join-Path $Root 'loader\entries') -Filter '*.conf' -ErrorAction SilentlyContinue |
                     Sort-Object Name | Select-Object -First 1
        if ($entry) {
            $m = Select-String -LiteralPath $entry.FullName -Pattern '^\s*title\s+(.+?)\s*$' | Select-Object -First 1
            if ($m) { $name = $m.Matches[0].Groups[1].Value }
        }
    }
    if (-not $name) {
        foreach ($rel in 'isolinux\isolinux.cfg', 'isolinux\txt.cfg', 'syslinux\syslinux.cfg', 'boot\syslinux\syslinux.cfg') {
            $cfg = Join-Path $Root $rel
            if (-not (Test-Path -LiteralPath $cfg -PathType Leaf)) { continue }
            $m = Select-String -LiteralPath $cfg -Pattern '^\s*menu\s+(?:title|label)\s+(.+?)\s*$' | Select-Object -First 1
            if ($m) { $name = $m.Matches[0].Groups[1].Value; break }
        }
    }
    if ($name) {
        # "Try or Install Ubuntu" -> "Ubuntu"; "Install Fedora 40 (safe graphics)" -> "Fedora 40"
        $name = ($name -replace '^\s*(Try or Install|Install|Start|Boot|Run|Launch)\s+', '' -replace '\s*\(.*\)\s*$', '').Trim()
        $name = $name -replace '\^', ''     # syslinux hot-key marker
    }

    # Distributions that find their media by volume label (Fedora/RHEL family)
    $hints = @()
    foreach ($cfg in $grubCfgs) {
        $hits = Select-String -LiteralPath $cfg -Pattern 'LABEL=([^\s"''\\]+)' -AllMatches
        foreach ($h in $hits) { foreach ($mm in $h.Matches) { $hints += $mm.Groups[1].Value } }
    }

    return [pscustomobject]@{ Name = $name; LabelHints = @($hints | Select-Object -Unique) }
}

# Inspect a mounted ISO and work out what it is and what to call the drive.
#   Kind : Windows | Linux | Unknown  ('Linux' = any non-Windows bootable media)
function Get-IsoMediaInfo {
    param([string]$Root, [string]$VolumeLabel)   # Root like 'X:\'

    $info = [pscustomobject]@{
        Kind        = 'Unknown'
        Name        = $VolumeLabel   # human-readable description shown to the user
        Label       = $VolumeLabel   # FAT32 volume label for the USB drive
        ImagePath   = $null          # Windows install.wim / install.esd
        ImageSize   = 0
        IsEsd       = $false
        NeedSplit   = $false
        HasEfiBoot  = $false
        HasBiosBoot = $false
        LabelHints  = @()            # LABEL=... references found in boot configs
    }

    $info.HasEfiBoot  = [bool](Get-ChildItem -LiteralPath (Join-Path $Root 'EFI') -Recurse -Filter '*.efi' `
                                   -ErrorAction SilentlyContinue | Select-Object -First 1)
    $info.HasBiosBoot = [bool](@('isolinux', 'syslinux', 'boot\syslinux', 'bootmgr') |
                                   Where-Object { Test-Path -LiteralPath (Join-Path $Root $_) } |
                                   Select-Object -First 1)

    $win = Get-WindowsMediaInfo -Root $Root -VolumeLabel $VolumeLabel
    if ($win) {
        $info.Kind      = 'Windows'
        $info.Name      = $win.Name
        $info.Label     = $win.Label
        $info.ImagePath = $win.ImagePath
        $info.ImageSize = $win.ImageSize
        $info.IsEsd     = $win.IsEsd
        $info.NeedSplit = $win.ImageSize -gt $Fat32MaxFileBytes
    }
    else {
        $linux = Get-LinuxMediaName -Root $Root
        $info.LabelHints = $linux.LabelHints
        if ($info.HasEfiBoot -or $info.HasBiosBoot -or $linux.Name) { $info.Kind = 'Linux' }
        if ($linux.Name) { $info.Name = $linux.Name; $info.Label = $linux.Name }
    }

    $info.Label = ConvertTo-Fat32Label $info.Label
    return $info
}

# ------------------------------------------------------------
# Anchor the working directory to the script's folder for the
# whole run, and leave it there on exit (see the finally block).
# This also matters for the elevated re-launch below: the RunAs
# verb ignores the requested working directory and would drop the
# new console in C:\Windows\System32. The original location is kept
# so a relative -IsoPath still resolves against it.
# ------------------------------------------------------------
$ScriptDir     = Split-Path -Parent $PSCommandPath
$StartLocation = (Get-Location).Path
Set-Location -LiteralPath $ScriptDir

# ------------------------------------------------------------
# Self-elevate. Partitioning and formatting need administrator
# rights; when started as a regular user, re-launch this script
# in an elevated PowerShell (standard UAC prompt), forwarding the
# same parameters, and let this un-elevated instance exit.
# The elevated console is kept open (-NoExit) so its output and
# prompts stay visible; close it when the script is finished.
# ------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Info ("This script needs administrator rights to partition and format the USB drive.`n" +
                "     Requesting elevation - answer Yes at the UAC prompt to continue in a new window...")

    # Quote each value; a trailing backslash would escape the closing quote in
    # the Windows argument parser (E:\ -> E:"), so strip it - no value here
    # legitimately ends in one.
    $quote = { param($v) '"{0}"' -f (([string]$v).TrimEnd('\') -replace '"', '\"') }

    # Forward ONLY the parameters that were actually supplied. All of them are
    # optional, and anything omitted here must stay omitted in the elevated
    # instance so its prompts (ISO path, disk) still run. Forwarding an empty
    # -IsoPath, for example, would read as "no ISO" and skip the prompt.
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', (& $quote $PSCommandPath))
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        $value = $kv.Value
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $argList += "-$($kv.Key)" }
            continue
        }
        # The elevated console starts in the script folder, so a relative ISO
        # path must be made absolute against the ORIGINAL location first.
        if ($kv.Key -eq 'IsoPath') {
            $value = "$value".Trim('"').Trim()
            if ($value -and -not [System.IO.Path]::IsPathRooted($value)) {
                $value = [System.IO.Path]::GetFullPath((Join-Path $StartLocation $value))
            }
        }
        $argList += "-$($kv.Key)"
        $argList += (& $quote $value)
    }

    try {
        # Re-launch with the same console host that is running now. Other hosts
        # (the ISE, for example) would open the file rather than run it, so
        # fall back to powershell.exe for anything else.
        $hostExe = (Get-Process -Id $PID).Path
        if ((Split-Path -Leaf $hostExe) -notin 'powershell.exe', 'pwsh.exe') { $hostExe = 'powershell.exe' }
        Start-Process -FilePath $hostExe -ArgumentList $argList -Verb RunAs `
                      -WorkingDirectory $ScriptDir | Out-Null
    }
    catch {
        Write-Fatal ("Elevation was cancelled or failed: $($_.Exception.Message) " +
                     "Re-run this script from a PowerShell window opened with 'Run as administrator'.")
    }
    exit 0
}

# ============================================================
# Main
# ============================================================
Write-Step ("============================================================`n" +
            " Bootable USB Creator`n" +
            "============================================================")

# ------------------------------------------------------------
# Locate the ISO. Prompt when -IsoPath was not given; an empty
# answer means "no ISO - just make the drive bootable". This runs in
# the elevated instance; an omitted -IsoPath is not forwarded by the
# elevation block above, so the prompt appears there exactly once.
# ------------------------------------------------------------
if (-not $PSBoundParameters.ContainsKey('IsoPath')) {
    $IsoPath = Read-Host "Enter full path to an installation ISO (Windows or Linux), or press Enter to only format the drive"
}
$IsoPath = "$IsoPath".Trim('"').Trim()
if ($IsoPath) {
    if (-not [System.IO.Path]::IsPathRooted($IsoPath)) {
        $IsoPath = [System.IO.Path]::GetFullPath((Join-Path $StartLocation $IsoPath))
    }
    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
        Write-Fatal "ISO file not found: $IsoPath"
    }
    $IsoPath = (Resolve-Path -LiteralPath $IsoPath).Path
}

$isoImage      = $null
$isoWasMounted = $false
$isoLetter     = $null
$media         = $null
$isoTotalBytes = 0
$label         = $DefaultLabel

# Silence the progress stream: the Windows PowerShell 5.1 console host renders it
# as a block pinned to the TOP of the window, and the script draws its own status
# inline instead.
#
# This MUST be $global:. Clear-Disk, Format-Volume, New-Partition and friends are
# CDXML *functions* in the Storage module, not binary cmdlets, so they resolve
# $ProgressPreference through the module's scope chain - module scope, then global
# - and never see a script-scoped assignment. The `finally` block restores the
# caller's value on every exit path, including Write-Fatal/exit and Ctrl+C.
$savedProgressPreference   = $global:ProgressPreference
$global:ProgressPreference = 'SilentlyContinue'

try {
    # --------------------------------------------------------
    # Mount and identify the ISO BEFORE anything is erased, so a
    # bad ISO or an unsupported layout costs nothing.
    # --------------------------------------------------------
    if ($IsoPath) {
        Write-Step "Mounting ISO..."

        # Remember whether the ISO was mounted before this run so the finally
        # block does not pull a mount the user made out from under them.
        $existingImage = Get-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue
        $isoWasMounted = [bool]($existingImage -and $existingImage.Attached)
        $isoImage      = Mount-DiskImage -ImagePath $IsoPath -PassThru

        # The volume is not always enumerated the instant Mount-DiskImage returns.
        $isoVolume = $null
        for ($i = 0; $i -lt 20 -and -not $isoVolume; $i++) {
            Start-Sleep -Milliseconds 500
            $isoVolume = $isoImage | Get-Volume -ErrorAction SilentlyContinue
            if ($isoVolume -and -not $isoVolume.DriveLetter) { $isoVolume = $null }
        }
        if (-not $isoVolume) { Write-Fatal "Failed to mount ISO or determine its drive letter." }

        $isoLetter   = $isoVolume.DriveLetter
        $isoVolLabel = $isoVolume.FileSystemLabel
        Write-Info "ISO mounted at ${isoLetter}: (volume label '$isoVolLabel')"

        Write-Step "Identifying installation media..."
        $media = Get-IsoMediaInfo -Root "${isoLetter}:\" -VolumeLabel $isoVolLabel
        $label = $media.Label

        switch ($media.Kind) {
            'Windows' { Write-Info "Media type  : Windows - $($media.Name)" }
            'Linux'   { Write-Info "Media type  : Linux / other bootable media - $($media.Name)" }
            default   {
                $desc = if ($media.Name) { " (volume label '$($media.Name)')" } else { '' }
                Write-Info "Media type  : unknown$desc"
                Write-Warn "No Windows, UEFI or isolinux/syslinux boot files were found. The contents will be copied, but the drive will probably not boot."
            }
        }
        Write-Info "Drive label : $label"

        if ($media.Kind -eq 'Windows' -and $media.ImagePath) {
            $imgName = Split-Path -Leaf $media.ImagePath
            $imgGB   = [math]::Round($media.ImageSize / 1GB, 2)
            if ($media.NeedSplit -and $media.IsEsd) {
                Write-Fatal ("This ISO contains an install.esd larger than 4 GB.`n" +
                             "        DISM /Split-Image cannot split .esd files.`n" +
                             "        Either use a WIM-based ISO, or export the ESD to WIM first:`n" +
                             "          dism /Export-Image /SourceImageFile:install.esd /SourceIndex:<n> ```n" +
                             "               /DestinationImageFile:install.wim /Compress:max /CheckIntegrity")
            }
            if ($media.NeedSplit) { Write-Info "Image       : $imgName, $imgGB GB - exceeds the 4 GB FAT32 limit, will be split with DISM" }
            else                  { Write-Info "Image       : $imgName, $imgGB GB - within the FAT32 limit, copied as-is" }
        }
        elseif ($media.Kind -eq 'Linux') {
            if (-not $media.HasEfiBoot) {
                Write-Warn "No EFI boot loader found on this media. A file copy to FAT32 does not write BIOS boot code, so this drive is unlikely to boot."
            }
            else {
                Write-Info "Boot mode   : UEFI (no BIOS/MBR boot code is written for non-Windows media)"
            }
            if ($media.LabelHints.Count -gt 0 -and ($media.LabelHints -notcontains $label)) {
                Write-Warn ("The boot configuration on this media locates its files by volume label " +
                            "($($media.LabelHints -join ', ')), but the drive will be labeled '$label'. " +
                            "If the installer cannot find its media, edit LABEL= in grub.cfg on the USB drive.")
            }
        }

        # Every file except the Windows image must fit FAT32's 4 GB file limit.
        $allFiles = @(Get-ChildItem -LiteralPath "${isoLetter}:\" -Recurse -File -Force -ErrorAction SilentlyContinue)
        $isoTotalBytes = ($allFiles | Measure-Object -Property Length -Sum).Sum
        if (-not $isoTotalBytes) { $isoTotalBytes = 0 }
        $tooBig = @($allFiles | Where-Object { $_.Length -gt $Fat32MaxFileBytes -and $_.FullName -ne $media.ImagePath })
        if ($tooBig.Count -gt 0) {
            $bigList = @($tooBig | ForEach-Object { "        {0}  ({1:N2} GB)" -f $_.FullName, ($_.Length / 1GB) })
            Write-Fatal ("These file(s) exceed the FAT32 4 GB file-size limit and cannot be copied to a FAT32 drive:`n" +
                         ($bigList -join "`n"))
        }
        Write-Info ("Total size  : {0:N2} GB in {1} files" -f ($isoTotalBytes / 1GB), $allFiles.Count)
    }
    else {
        Write-Info "No ISO specified - the drive will only be partitioned and formatted as '$label'."
    }

    # ------------------------------------------------------------
    # SAFETY STEP - list ONLY USB disks; internal disks never shown
    # ------------------------------------------------------------
    Write-Step "Scanning for USB disks (internal drives are hidden and cannot be selected)..."

    $usbDisks = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' })
    if ($usbDisks.Count -eq 0) {
        Write-Fatal "No USB disks detected. Insert your flash drive and re-run."
    }

    $diskTable = @(($usbDisks |
        Format-Table -AutoSize Number, FriendlyName,
            @{ Name = 'Size(GB)'; Expression = { [math]::Round($_.Size / 1GB, 1) } },
            @{ Name = 'Letter(s)'; Expression = {
                ($_ | Get-Partition -ErrorAction SilentlyContinue |
                    Where-Object DriveLetter |
                    ForEach-Object { "$($_.DriveLetter):" }) -join ', '
            } },
            PartitionStyle, IsSystem, IsBoot, IsReadOnly |
        Out-String -Width 200).TrimEnd() -split "`r?`n" | Where-Object { $_ -ne '' })
    # One write; continuation lines indented to align with Write-Info's prefix.
    Write-Info ($diskTable -join "`n     ")

    Write-Warn "ALL DATA on the selected USB drive will be PERMANENTLY ERASED."

    # Resolve the target disk: -UsbDriveLetter wins if supplied, then
    # -DiskNumber, otherwise prompt and accept either form.
    if ($UsbDriveLetter) {
        $DiskNumber = Resolve-DiskNumberFromLetter $UsbDriveLetter
    }
    elseif ($DiskNumber -lt 0) {
        $rawInput = (Read-Host "Enter the DISK NUMBER or DRIVE LETTER (e.g. 2 or E:) of your USB drive").Trim()
        if     ($rawInput -match '^\d+$')          { $DiskNumber = [int]$rawInput }
        elseif ($rawInput -match '^[A-Za-z]:?\\?$') { $DiskNumber = Resolve-DiskNumberFromLetter $rawInput }
        else   { Write-Fatal "Enter a disk number (e.g. 2) or a drive letter (e.g. E or E:)." }
    }

    # ------------------------------------------------------------
    # SAFETY GATE - validate the selected disk before ANY change.
    # Refuses unless ALL of the following are true:
    #   1. Disk exists
    #   2. BusType is USB (blocks SATA/NVMe/RAID/SAS internal disks)
    #   3. Disk is NOT the system disk
    #   4. Disk is NOT the boot disk
    #   5. Disk is NOT write-protected
    #   6. No volume on the disk contains a Windows installation
    # There is intentionally NO override for these checks.
    # ------------------------------------------------------------
    Write-Step "Validating disk $DiskNumber ..."

    $disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
    if (-not $disk)                  { Write-Fatal "Disk $DiskNumber does not exist." }
    if ($disk.BusType -ne 'USB')     { Write-Fatal "Disk $DiskNumber is NOT a USB disk. It is on an internal bus ($($disk.BusType)) and will not be touched." }
    if ($disk.IsSystem)              { Write-Fatal "Disk $DiskNumber is the SYSTEM disk. Refusing to format it." }
    if ($disk.IsBoot)                { Write-Fatal "Disk $DiskNumber is the BOOT disk. Refusing to format it." }
    if ($disk.IsReadOnly)            { Write-Fatal "Disk $DiskNumber is write-protected (read-only). Remove the write protection (hardware switch or 'diskpart' -> 'attributes disk clear readonly') and re-run." }

    $hasWindows = $false
    Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
        Get-Volume -ErrorAction SilentlyContinue |
        Where-Object DriveLetter |
        ForEach-Object {
            if (Test-Path -LiteralPath "$($_.DriveLetter):\Windows\System32") { $hasWindows = $true }
        }
    if ($hasWindows) {
        Write-Fatal "Disk $DiskNumber contains a Windows installation. Refusing to format it. If this really is your target USB, wipe it manually in Disk Management first."
    }

    $diskGB      = [math]::Round($disk.Size / 1GB, 1)
    $isRemovable = Test-RemovableDisk -Number $DiskNumber

    # The ISO must fit the partition we are about to create (3% headroom for
    # FAT32 overhead and the slightly larger total of split .swm files).
    if ($isoTotalBytes -gt 0) {
        $usable = [math]::Min([uint64]$disk.Size, [uint64]$Fat32MaxPartition) * 0.97
        if ($isoTotalBytes -gt $usable) {
            Write-Fatal ("The ISO contents ({0:N2} GB) will not fit on disk {1} ({2} GB, FAT32 partition capped at 32 GB)." -f
                         ($isoTotalBytes / 1GB), $DiskNumber, $diskGB)
        }
    }

    # ------------------------------------------------------------
    # Final confirmation
    # ------------------------------------------------------------
    $lastChance = ("!! LAST CHANCE !!`n" +
                   "          Disk $DiskNumber`: `"$($disk.FriendlyName)`" ($diskGB GB, USB) will be completely erased`n" +
                   "          and formatted FAT32 with the label '$label'.")
    if ($isRemovable -and $disk.Size -gt $Fat32MaxPartition) {
        # Said here, BEFORE the erase, rather than discovered after it: on some
        # removable drives Windows keeps a single full-size partition after a
        # clean, and FAT32 cannot be formatted above 32 GB, so the run may stop
        # with the drive already wiped.
        $lastChance += ("`n          This is REMOVABLE media larger than 32 GB. If Windows insists on one full-size " +
                        "partition after the`n          erase, FAT32 formatting is impossible and the script will stop " +
                        "with the drive already wiped.`n          A 32 GB or smaller stick, or an external hard disk, avoids this.")
    }
    Write-Info ""
    Write-Warn $lastChance
    $confirm = Read-Host "Type ERASE to continue (anything else cancels)"
    if ($confirm -cne 'ERASE') {
        Write-Info "Cancelled. No changes were made."
        exit 0
    }

    # --------------------------------------------------------
    # Partition and format the USB drive
    # NOTE: Windows cannot FORMAT a FAT32 volume larger than
    # 32 GB, so on big sticks the partition is capped.
    # --------------------------------------------------------
    Write-Step "Partitioning and formatting USB drive (Disk $DiskNumber)..."

    if ($disk.IsOffline) {
        Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction SilentlyContinue
        $disk = Get-Disk -Number $DiskNumber
        if ($disk.IsOffline) { Write-Fatal "Disk $DiskNumber is offline and could not be brought online. Bring it online in Disk Management and re-run." }
    }

    # Clear-Disk throws on a disk that has never been initialized; there is
    # nothing to clear on it anyway.
    if ($disk.PartitionStyle -ne 'RAW') {
        Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
    }
    else {
        Write-Info "Disk is uninitialized (RAW) - nothing to clear."
    }
    Initialize-Disk -Number $DiskNumber -PartitionStyle MBR -ErrorAction SilentlyContinue

    # Clear-Disk/Initialize-Disk are async with respect to the storage service's
    # cached MSFT_Disk. Refresh and let the layout settle before inspecting it.
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        Update-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
        $disk = Get-Disk -Number $DiskNumber
        if ($disk.PartitionStyle -ne 'RAW') { break }
    }
    if ($disk.PartitionStyle -eq 'RAW') {
        Write-Fatal "Disk $DiskNumber is still uninitialized after Initialize-Disk. Initialize it as MBR in Disk Management and re-run."
    }

    # Removable USB flash drives (RMB bit set) are owned by Windows' partition
    # manager: it keeps exactly ONE partition spanning the whole device at
    # offset 0 and re-creates it immediately after a clean. LargestFreeExtent
    # is then 0 and New-Partition fails with "Not enough available capacity".
    # In that case format the partition Windows made instead of creating one.
    $existing = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
                    Where-Object { $_.Type -ne 'Reserved' })

    if ($disk.LargestFreeExtent -lt 1GB -and $existing.Count -eq 1) {
        $partition = $existing[0]
        $partGB    = [math]::Round($partition.Size / 1GB, 1)
        Write-Info "Removable drive: reusing the full-device partition Windows maintains ($partGB GB)."

        if ($partition.Size -gt $Fat32MaxPartition) {
            Write-Fatal ("This drive's partition is $partGB GB, above the 32 GB FAT32 format limit, and Windows " +
                         "will not let it be shrunk on removable media. Use a 32 GB or smaller stick, or a tool " +
                         "such as Rufus that writes an NTFS layout with a UEFI:NTFS boot shim.")
        }
    }
    elseif ($disk.LargestFreeExtent -lt 1GB) {
        Write-Fatal ("Disk $DiskNumber reports no free space after being cleared " +
                     "($($existing.Count) partition(s) present). Clear it manually with " +
                     "'diskpart' -> 'select disk $DiskNumber' -> 'clean', then re-run.")
    }
    else {
        $newSize = [math]::Min([uint64]$disk.LargestFreeExtent, [uint64]$Fat32MaxPartition)
        if ($disk.Size -gt $Fat32MaxPartition) {
            Write-Info "Disk is larger than 32 GB - creating a 32 GB FAT32 partition."
        }
        $partition = New-Partition -DiskNumber $DiskNumber -Size $newSize -AssignDriveLetter
    }

    # MBR active flag: meaningful for BIOS boot on fixed-disk USB, and a no-op
    # (harmless failure) on a superfloppy-style removable drive.
    try { $partition | Set-Partition -IsActive $true -ErrorAction Stop }
    catch { Write-Info "Note: could not set the active flag (normal for removable media)." }

    Format-Volume -Partition $partition -FileSystem FAT32 `
                  -NewFileSystemLabel $label -Force -Confirm:$false | Out-Null

    # Re-query rather than trusting the returned object: a freshly created or
    # reused partition may not carry its drive letter on the pipeline object.
    $partition = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber
    if (-not $partition.DriveLetter) {
        $partition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue
        $partition = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber
    }

    $usbLetter = $partition.DriveLetter
    if (-not $usbLetter) { Write-Fatal "Could not detect USB drive letter after formatting." }
    Write-Info "USB drive formatted at ${usbLetter}: with label '$label'"

    # --------------------------------------------------------
    # No ISO: the empty, active FAT32 drive is the deliverable.
    # --------------------------------------------------------
    if (-not $media) {
        Write-Success ("`n" +
                       "============================================================`n" +
                       " SUCCESS! USB drive partitioned and formatted.`n" +
                       " Drive letter : ${usbLetter}:`n" +
                       " Label        : $label`n" +
                       " File system  : FAT32, active primary partition (MBR)`n" +
                       "============================================================")
        exit 0
    }

    $logOut = Join-Path $env:TEMP 'bootableusb-out.log'
    $logErr = Join-Path $env:TEMP 'bootableusb-err.log'

    # --------------------------------------------------------
    # Copy the ISO contents. For Windows media the install image
    # is held back and handled separately below (Microsoft's
    # procedure). robocopy: /xf applies recursively with /e;
    # exit codes 0-7 = success, 8+ = failure. Paths are passed as
    # bare drive specs ("D:", "E:") because a trailing backslash
    # before a closing quote is mangled by robocopy's argument parser.
    # --------------------------------------------------------
    Write-Step "Copying ISO contents to USB drive..."

    $roboArgs = @("${isoLetter}:", "${usbLetter}:", '/e') + $RobocopyCommonArgs
    if ($media.ImagePath) { $roboArgs += @('/xf', 'install.wim', 'install.esd') }

    $rc = Invoke-ProcessWithTimer -FilePath 'robocopy.exe' -ArgumentList $roboArgs `
                                  -Activity 'Copying files...' -OutLog $logOut -ErrLog $logErr
    if ($rc -ge 8) {
        Show-LogTail -Paths $logOut, $logErr
        Write-Fatal "robocopy failed to copy ISO contents (exit code $rc)."
    }
    Remove-Item -LiteralPath $logOut, $logErr -ErrorAction SilentlyContinue

    # --------------------------------------------------------
    # Windows only: copy or split the install image
    # (/FileSize:3800 per Microsoft docs, headroom under 4 GB)
    # --------------------------------------------------------
    if ($media.ImagePath) {
        Write-Step "Processing Windows install image..."

        $sourcesDir = "${usbLetter}:\sources"
        if (-not (Test-Path -LiteralPath $sourcesDir)) {
            New-Item -ItemType Directory -Path $sourcesDir | Out-Null
        }

        if ($media.NeedSplit) {
            Write-Info "Splitting image with DISM (this can take several minutes with no output from DISM)..."
            $dismArgs = @(
                '/Split-Image'
                "/ImageFile:`"$($media.ImagePath)`""
                "/SWMFile:`"$sourcesDir\install.swm`""
                '/FileSize:3800'
            )
            $rc = Invoke-ProcessWithTimer -FilePath 'dism.exe' -ArgumentList $dismArgs `
                                          -Activity 'Splitting install image...' -OutLog $logOut -ErrLog $logErr
            if ($rc -ne 0) {
                Show-LogTail -Paths $logOut, $logErr
                Write-Fatal "DISM failed to split the image file (exit code $rc)."
            }
            Remove-Item -LiteralPath $logOut, $logErr -ErrorAction SilentlyContinue

            $swmCount = @(Get-ChildItem -LiteralPath $sourcesDir -Filter 'install*.swm' -ErrorAction SilentlyContinue).Count
            Write-Info "Image split into $swmCount .swm file(s)."
        }
        else {
            # A single file of up to 4 GB: robocopy again so the timer shows progress.
            $imgDir  = Split-Path -Parent $media.ImagePath
            $imgName = Split-Path -Leaf   $media.ImagePath
            $rc = Invoke-ProcessWithTimer -FilePath 'robocopy.exe' -ArgumentList (@($imgDir, $sourcesDir, $imgName) + $RobocopyCommonArgs) `
                                          -Activity 'Copying install image...' -OutLog $logOut -ErrLog $logErr
            if ($rc -ge 8) {
                Show-LogTail -Paths $logOut, $logErr
                Write-Fatal "robocopy failed to copy $imgName (exit code $rc)."
            }
            Remove-Item -LiteralPath $logOut, $logErr -ErrorAction SilentlyContinue
        }
    }

    $bootMode = if ($media.Kind -eq 'Windows') { 'UEFI and legacy BIOS (FAT32 + active partition)' }
                else                            { 'UEFI (FAT32; no BIOS boot code written)' }
    Write-Success ("`n" +
                   "============================================================`n" +
                   " SUCCESS! Your bootable USB drive is ready.`n" +
                   " Media        : $($media.Name)`n" +
                   " Drive letter : ${usbLetter}:`n" +
                   " Label        : $label`n" +
                   " Boot mode    : $bootMode`n" +
                   "============================================================")
}
finally {
    # ISO is dismounted on success, failure, or Ctrl+C alike - unless it was
    # already mounted before this run, in which case it is left as found.
    if ($isoImage) {
        if ($isoWasMounted) {
            Write-Info "ISO was already mounted before this run - leaving it mounted."
        }
        else {
            Write-Step "Unmounting ISO..."
            Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
        }
    }

    # Put the caller's progress setting back - $global: would otherwise persist
    # in their session after the script ends.
    $global:ProgressPreference = $savedProgressPreference

    # End in the script's own folder, whatever happened above (this also
    # covers the elevated -NoExit console, which would otherwise be left
    # wherever RunAs started it).
    Set-Location -LiteralPath $ScriptDir -ErrorAction SilentlyContinue
}

write-host -NoNewLine "Press Any Key To Continue" -BackgroundColor Gray -ForegroundColor Black
$null = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown");
