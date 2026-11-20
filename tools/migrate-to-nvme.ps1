#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Moves the running Windows onto another disk as a UEFI/GPT system. Erases the target disk.
.DESCRIPTION
  Meant for "old board, Windows in Legacy/MBR, new NVMe that boots only via UEFI".
  Lays out the target as GPT (EFI, MSR, Windows), captures the live C: from a VSS snapshot with
  wimlib, applies it, writes UEFI boot files, points C: of the new system at the new partition,
  re-points links that wimlib aimed at the temporary letter, and puts Winre.wim next to the system.
  Needs wimlib-imagex (https://wimlib.net). After it finishes, boot the UEFI entry of the new disk
  and run 'reagentc /enable' there.
.EXAMPLE
  .\migrate-to-nvme.ps1 -TargetSerial 'XXXX_XXXX_XXXX_XXXX' -TargetModel 'SAMSUNG MZVLQ256HAJD' -Wim D:\migrate\win.wim -Wimlib 'C:\wimlib\wimlib-imagex.exe' -IUnderstandThisErasesTheTarget
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$TargetSerial,
  [Parameter(Mandatory)][string]$TargetModel,
  [Parameter(Mandatory)][string]$Wim,
  [Parameter(Mandatory)][string]$Wimlib,
  [ValidatePattern('^[A-Za-z]$')][string]$TempLetter = 'W',
  [ValidatePattern('^[A-Za-z]$')][string]$EfiLetter = 'S',
  [switch]$IUnderstandThisErasesTheTarget
)
$ErrorActionPreference = 'Stop'
if (-not $IUnderstandThisErasesTheTarget) { throw 'This erases the target disk. Add -IUnderstandThisErasesTheTarget to proceed.' }
if (-not (Test-Path $Wimlib)) { throw "wimlib-imagex not found: $Wimlib" }

$log = Join-Path (Split-Path $Wim) 'migrate.log'
New-Item -ItemType Directory -Force (Split-Path $Wim) | Out-Null
function Write-Log($message) { "$(Get-Date -Format HH:mm:ss) $message" | Tee-Object -FilePath $log -Append }

$target = @(Get-Disk | Where-Object { $_.SerialNumber -like "$TargetSerial*" -and $_.FriendlyName -like "$TargetModel*" })
if ($target.Count -ne 1) { throw "Target matched $($target.Count) disks, expected exactly one." }
$target = $target[0]
if ($target.IsBoot -or $target.IsSystem) { throw 'Refusing to erase the boot/system disk.' }
$wimDisk = (Get-Partition -DriveLetter (Resolve-Path (Split-Path $Wim)).Drive.Name).DiskNumber
if ($wimDisk -eq $target.Number) { throw 'The WIM would be written to the disk that is about to be erased.' }
$n = $target.Number
Write-Log "Target: disk $n $($target.FriendlyName) SN $($target.SerialNumber) $([int]($target.Size / 1GB)) GB"

Clear-Disk -Number $n -RemoveData -RemoveOEM -Confirm:$false
Initialize-Disk -Number $n -PartitionStyle GPT
$efi = New-Partition -DiskNumber $n -Size 300MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
Format-Volume -Partition $efi -FileSystem FAT32 -NewFileSystemLabel EFI -Confirm:$false | Out-Null
$efi | Add-PartitionAccessPath -AccessPath "${EfiLetter}:"
if (-not (Get-Partition -DiskNumber $n | Where-Object GptType -eq '{e3c9e316-0b5c-4db8-817d-f92df00215ae}')) {
  New-Partition -DiskNumber $n -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null
}
$win = New-Partition -DiskNumber $n -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
Format-Volume -Partition $win -FileSystem NTFS -NewFileSystemLabel Windows -Confirm:$false | Out-Null
$win | Add-PartitionAccessPath -AccessPath "${TempLetter}:"
$win = Get-Partition -DiskNumber $n -PartitionNumber $win.PartitionNumber
Write-Log "Partitioned: ${EfiLetter}: EFI, ${TempLetter}: Windows"

Remove-Item $Wim -Force -ErrorAction SilentlyContinue
Write-Log 'Capturing C: ...'
& $Wimlib capture C:\ $Wim Windows --snapshot --compress=fast 2>&1 | Select-Object -Last 1 | ForEach-Object { Write-Log "$_" }
if ($LASTEXITCODE) { throw "wimlib capture failed with $LASTEXITCODE" }
Write-Log 'Applying ...'
& $Wimlib apply $Wim 1 "${TempLetter}:\" 2>&1 | Select-Object -Last 1 | ForEach-Object { Write-Log "$_" }
if ($LASTEXITCODE) { throw "wimlib apply failed with $LASTEXITCODE" }
bcdboot "${TempLetter}:\Windows" /s "${EfiLetter}:" /f UEFI | ForEach-Object { Write-Log $_ }

# Without this the new system may come up with another letter for its own volume.
reg load HKLM\MIGSYS "${TempLetter}:\Windows\System32\config\SYSTEM" | Out-Null
$mounted = 'HKLM:\MIGSYS\MountedDevices'
$oldC = (Get-ItemProperty $mounted).'\DosDevices\C:'
if ($oldC) {
  $oldC64 = [Convert]::ToBase64String($oldC)
  foreach ($name in (Get-Item $mounted).Property) {
    if ($name -ne '\DosDevices\C:' -and [Convert]::ToBase64String((Get-ItemProperty $mounted).$name) -eq $oldC64) {
      Remove-ItemProperty $mounted -Name $name
    }
  }
}
$id = [Text.Encoding]::ASCII.GetBytes('DMIO:ID:') + ([Guid]$win.Guid).ToByteArray()
Set-ItemProperty $mounted -Name '\DosDevices\C:' -Value ([byte[]]$id) -Type Binary
[gc]::Collect()
Start-Sleep 2
reg unload HKLM\MIGSYS | Out-Null
Write-Log 'New system: C: points to the new Windows partition'

& (Join-Path $PSScriptRoot 'fix-retargeted-links.ps1') -Root "${TempLetter}:\" -From $TempLetter -To C -Apply | ForEach-Object { Write-Log $_ }

$winre = Get-ChildItem C:\Windows\System32\Recovery, C:\Recovery -Recurse -Force -Filter Winre.wim -ErrorAction SilentlyContinue | Select-Object -First 1
if ($winre) {
  Copy-Item $winre.FullName "${TempLetter}:\Windows\System32\Recovery\Winre.wim" -Force
  Write-Log 'Winre.wim copied. Run "reagentc /enable" in the new system.'
} else {
  Write-Log 'Winre.wim is on a separate recovery partition. Copy it to \Windows\System32\Recovery of the new system and run reagentc /enable there.'
}

$efi | Remove-PartitionAccessPath -AccessPath "${EfiLetter}:"
Write-Log ("System32 files: new {0}, current {1}" -f (Get-ChildItem "${TempLetter}:\Windows\System32" -File).Count, (Get-ChildItem C:\Windows\System32 -File).Count)
Write-Log 'Done. Reboot and boot the UEFI entry of the new disk.'
