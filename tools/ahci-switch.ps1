#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Prepares Windows for switching the SATA controller from IDE to AHCI without reinstalling.
.DESCRIPTION
  Enables storahci at boot and makes the next boot a Safe Mode boot, where Windows binds the AHCI
  driver to the controller. A RunOnce entry then removes the Safe Mode flag and reboots.
  After running: reboot, set SATA mode to AHCI in BIOS, log on in Safe Mode and wait ~20 s.
  INACCESSIBLE_BOOT_DEVICE means the switch failed: set SATA back to IDE, nothing is lost.
#>
$ErrorActionPreference = 'Stop'

$service = 'HKLM:\SYSTEM\CurrentControlSet\Services\storahci'
Set-ItemProperty $service -Name Start -Value 0 -Type DWord
Remove-ItemProperty "$service\StartOverride" -Name '0' -ErrorAction SilentlyContinue

bcdedit /set '{current}' safeboot minimal | Out-Null

# RunOnce values whose name starts with '*' also run in Safe Mode.
$undo = 'cmd /c bcdedit /deletevalue {current} safeboot & shutdown /r /t 20 /c "AHCI ready, rebooting"'
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name '*AHCI-undo-safeboot' -Value $undo

'Ready. Reboot, set SATA mode to AHCI in BIOS, log on in Safe Mode and wait for the automatic reboot.'
