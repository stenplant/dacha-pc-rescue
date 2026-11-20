#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Erases an SSD, sends a full TRIM, then writes and verifies every block. Destructive.
.DESCRIPTION
  -Phase Trim  wipes the disk, formats one partition over it, runs ReTrim, wipes it again and takes it Offline.
  -Phase Test  writes a unique 1 MiB block to every MiB, the first 8 bytes being the block index, then reads
               everything back. A mismatch is logged with the index found in its place, which shows where the
               drive actually put the data. Resumable.
  The disk must match serial, model and exact size, and must not be the boot or system disk.
.EXAMPLE
  .\ssd-verify.ps1 -Serial XXXX -Model 'KINGSTON SA400S37240G' -Size 240057409536 -WorkDir D:\ssdtest -Phase Trim -IUnderstandThisErasesTheDisk
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Serial,
  [Parameter(Mandatory)][string]$Model,
  [Parameter(Mandatory)][int64]$Size,
  [Parameter(Mandatory)][string]$WorkDir,
  [Parameter(Mandatory)][ValidateSet('Trim', 'Test')][string]$Phase,
  [switch]$IUnderstandThisErasesTheDisk
)
$ErrorActionPreference = 'Stop'
if (-not $IUnderstandThisErasesTheDisk) { throw 'This erases the whole disk. Add -IUnderstandThisErasesTheDisk to proceed.' }

New-Item -ItemType Directory -Force $WorkDir | Out-Null
$log = Join-Path $WorkDir 'test-progress.txt'
$state = Join-Path $WorkDir 'test-state.txt'

function Get-Target {
  $d = @(Get-Disk | Where-Object { $_.SerialNumber -and $_.SerialNumber.Trim() -eq $Serial })
  if ($d.Count -ne 1) { throw "Serial $Serial matched $($d.Count) disks." }
  $d = $d[0]
  if ($d.FriendlyName -notlike "$Model*") { throw "Model mismatch: $($d.FriendlyName)" }
  if ([int64]$d.Size -ne $Size) { throw "Size mismatch: $($d.Size)" }
  if ($d.IsBoot -or $d.IsSystem) { throw 'Refusing to touch the boot/system disk.' }
  $d
}

$d = Get-Target
"Target: disk $($d.Number)  $($d.FriendlyName)  SN $Serial  $($d.Size) bytes"

if ($Phase -eq 'Trim') {
  if ($d.IsOffline) { Set-Disk -Number $d.Number -IsOffline $false; Start-Sleep 2 }
  if ((Get-Target).IsReadOnly) { Set-Disk -Number $d.Number -IsReadOnly $false }
  Clear-Disk -Number (Get-Target).Number -RemoveData -RemoveOEM -Confirm:$false
  Initialize-Disk -Number (Get-Target).Number -PartitionStyle GPT
  $p = New-Partition -DiskNumber (Get-Target).Number -UseMaximumSize -AssignDriveLetter
  Format-Volume -Partition $p -FileSystem NTFS -NewFileSystemLabel TRIMTEST -Confirm:$false | Out-Null
  Optimize-Volume -DriveLetter (Get-Partition -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber).DriveLetter -ReTrim -Verbose
  Clear-Disk -Number (Get-Target).Number -RemoveData -RemoveOEM -Confirm:$false
  Set-Disk -Number (Get-Target).Number -IsOffline $true
  Remove-Item $state -ErrorAction SilentlyContinue
  'TRIM done, disk is empty and Offline. Next: -Phase Test'
  return
}

if (-not $d.IsOffline) { Set-Disk -Number $d.Number -IsOffline $true }

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class RawVerify {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);

  const int Chunk = 1 << 20;

  static void Fill(byte[] b, long block) {
    ulong x = (ulong)block * 0x9E3779B97F4A7C15UL + 0xD1B54A32D192ED03UL;
    for (int i = 0; i < Chunk; i += 8) {
      x ^= x << 13; x ^= x >> 7; x ^= x << 17;
      BitConverter.GetBytes(x).CopyTo(b, i);
    }
    BitConverter.GetBytes(block).CopyTo(b, 0);
  }

  static void ReadExactly(Stream s, byte[] b, int n) {
    int r = 0;
    while (r < n) { int k = s.Read(b, r, n - r); if (k <= 0) throw new IOException("Unexpected end of device"); r += k; }
  }

  public static void Run(string device, long size, string log, string state) {
    string phase = "W";
    long pos = 0;
    if (File.Exists(state)) {
      var p = File.ReadAllText(state).Trim().Split(' ');
      phase = p[0];
      pos = long.Parse(p[1]);
    }
    // FILE_FLAG_WRITE_THROUGH: every block must really reach the drive before it is read back.
    var handle = CreateFile(device, 0xC0000000, 3, IntPtr.Zero, 3, 0x80000000, IntPtr.Zero);
    if (handle.IsInvalid) throw new IOException("Cannot open device, Win32 error " + Marshal.GetLastWin32Error());

    using (var fs = new FileStream(handle, FileAccess.ReadWrite, 1)) {
      var expected = new byte[Chunk];
      var actual = new byte[Chunk];
      long blocks = (size + Chunk - 1) / Chunk, mismatches = 0, phaseStart = pos;
      var started = DateTime.Now;

      while (phase == "W" || phase == "V") {
        if (pos >= size) {
          if (phase == "W") { phase = "V"; pos = 0; phaseStart = 0; started = DateTime.Now; File.WriteAllText(state, "V 0"); continue; }
          File.WriteAllText(state, "DONE 0");
          File.AppendAllText(log, string.Format("{0} RESULT: {1} mismatched blocks of {2}{3}", DateTime.Now, mismatches, blocks, Environment.NewLine));
          break;
        }
        long block = pos / Chunk;
        int n = (int)Math.Min(Chunk, size - pos);
        Fill(expected, block);
        fs.Position = pos;
        if (phase == "W") {
          fs.Write(expected, 0, n);
        } else {
          try {
            ReadExactly(fs, actual, n);
            for (int i = 0; i < n; i++) {
              if (actual[i] != expected[i]) {
                mismatches++;
                File.AppendAllText(log, string.Format("MISMATCH block {0} at byte {1}, holds block {2}{3}", block, i, BitConverter.ToInt64(actual, 0), Environment.NewLine));
                break;
              }
            }
          } catch (IOException e) {
            mismatches++;
            File.AppendAllText(log, "MISMATCH block " + block + " read error: " + e.Message + Environment.NewLine);
          }
        }
        pos += n;
        if ((pos / Chunk) % 1024 == 0 || pos >= size) {
          if (phase == "W") fs.Flush();
          File.WriteAllText(state, phase + " " + pos);
          double mbps = (pos - phaseStart) / 1048576.0 / Math.Max(1, (DateTime.Now - started).TotalSeconds);
          File.AppendAllText(log, string.Format("{0} {1} {2:F1}% {3:F0} MB/s mismatches={4}{5}",
            DateTime.Now, phase == "W" ? "WRITE" : "VERIFY", pos * 100.0 / size, mbps, mismatches, Environment.NewLine));
        }
      }
    }
  }
}
'@

[RawVerify]::Run("\\.\PhysicalDrive$($d.Number)", $Size, $log, $state)
Get-Content $log -Tail 3
