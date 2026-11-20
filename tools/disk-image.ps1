#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Sector-by-sector image of a failing disk. The source is opened read-only.
.DESCRIPTION
  Reads 1 MiB chunks, falls back to 512-byte sectors on error, zero-fills unreadable sectors
  and logs their LBA to bad-sectors.txt. Resumes from the last complete chunk.
  Take the source Offline first (Set-Disk -IsOffline $true) so Windows leaves its file system alone.
.EXAMPLE
  .\disk-image.ps1 -Model 'KINGSTON SA400S37240G' -OutDir D:\rescue
.EXAMPLE
  .\disk-image.ps1 -Serial 'XXXXXXXXXXXXXXXX' -OutDir D:\rescue -ImageName old-ssd.img
#>
[CmdletBinding()]
param(
  [string]$Model,
  [string]$Serial,
  [Parameter(Mandatory)][string]$OutDir,
  [string]$ImageName = 'disk.img'
)
$ErrorActionPreference = 'Stop'
if (-not $Model -and -not $Serial) { throw 'Specify -Model and/or -Serial of the source disk.' }

$disk = @(Get-Disk | Where-Object {
  (-not $Model -or $_.FriendlyName -like "$Model*") -and
  (-not $Serial -or ($_.SerialNumber -and $_.SerialNumber.Trim() -eq $Serial))
})
if ($disk.Count -ne 1) { throw "Source disk matched $($disk.Count) times, expected exactly one." }
$disk = $disk[0]

New-Item -ItemType Directory -Force $OutDir | Out-Null
$outDrive = (Resolve-Path $OutDir).Drive.Name
$outDisk = (Get-Partition -DriveLetter $outDrive).DiskNumber
if ($outDisk -eq $disk.Number) { throw 'OutDir is on the source disk. Write the image somewhere else.' }
$size = [int64]$disk.Size
if ((Get-PSDrive $outDrive).Free -lt $size) { Write-Warning "$($outDrive): has less free space than the image needs ($([int]($size / 1GB)) GB)." }

$out = Join-Path $OutDir $ImageName
$log = Join-Path $OutDir 'progress.txt'
$bad = Join-Path $OutDir 'bad-sectors.txt'
"Source: \\.\PhysicalDrive$($disk.Number)  $($disk.FriendlyName)  SN $($disk.SerialNumber)  $size bytes"
"Image:  $out"

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class DiskImager {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);

  const int Chunk = 1 << 20;
  const int Sector = 512;

  public static void Run(string source, string target, long size, string log, string bad) {
    // GENERIC_READ only: nothing in this process can write to the source.
    var handle = CreateFile(source, 0x80000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
    if (handle.IsInvalid) throw new IOException("Cannot open source, Win32 error " + Marshal.GetLastWin32Error());

    using (var input = new FileStream(handle, FileAccess.Read, 1))
    using (var output = new FileStream(target, FileMode.OpenOrCreate, FileAccess.Write, FileShare.Read)) {
      long pos = output.Length / Chunk * Chunk;
      output.SetLength(pos);
      output.Position = pos;
      var buffer = new byte[Chunk];
      var sector = new byte[Sector];
      long badSectors = 0, startPos = pos, nextReport = pos;
      var started = DateTime.Now;

      while (pos < size) {
        int n = (int)Math.Min(Chunk, size - pos);
        try {
          input.Position = pos;
          ReadExactly(input, buffer, n);
          output.Write(buffer, 0, n);
        } catch (IOException) {
          for (int offset = 0; offset < n; offset += Sector) {
            try {
              input.Position = pos + offset;
              ReadExactly(input, sector, Sector);
            } catch (IOException) {
              Array.Clear(sector, 0, Sector);
              badSectors++;
              File.AppendAllText(bad, ((pos + offset) / Sector) + Environment.NewLine);
            }
            output.Write(sector, 0, Sector);
          }
        }
        pos += n;
        if (pos >= nextReport || pos >= size) {
          output.Flush();
          double mbps = (pos - startPos) / 1048576.0 / Math.Max(1, (DateTime.Now - started).TotalSeconds);
          File.WriteAllText(log, string.Format("{0:F1}%  {1}/{2} MB  {3:F0} MB/s  unreadable sectors: {4}  {5}",
            pos * 100.0 / size, pos >> 20, size >> 20, mbps, badSectors, DateTime.Now));
          nextReport = pos + (1L << 30);
        }
      }
      File.AppendAllText(log, Environment.NewLine + "DONE");
    }
  }

  static void ReadExactly(Stream s, byte[] buffer, int count) {
    int read = 0;
    while (read < count) {
      int k = s.Read(buffer, read, count - read);
      if (k <= 0) throw new IOException("Unexpected end of device");
      read += k;
    }
  }
}
'@

[DiskImager]::Run("\\.\PhysicalDrive$($disk.Number)", $out, $size, $log, $bad)
Get-Content $log
if (Test-Path $bad) { "Unreadable sectors: $((Get-Content $bad).Count), LBAs in $bad" } else { 'Unreadable sectors: 0' }
