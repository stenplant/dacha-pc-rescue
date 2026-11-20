<#
.SYNOPSIS
  Re-points symlinks and junctions that lead to a drive letter that no longer exists.
.DESCRIPTION
  Typical after applying a WIM with wimlib to a temporary letter: absolute links end up pointing there.
  Without -Apply only lists what it finds. With -Apply (as Administrator) recreates each link with the
  new letter and keeps its ACL and Hidden/System attributes.
.EXAMPLE
  .\fix-retargeted-links.ps1 -From W -To C
.EXAMPLE
  .\fix-retargeted-links.ps1 -From W -To C -Apply
#>
[CmdletBinding()]
param(
  [string]$Root = 'C:\',
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z]$')][string]$From,
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z]$')][string]$To,
  [switch]$Apply
)

function Repair-Link($link, $newTarget) {
  $path = $link.FullName
  $attributes = $link.Attributes
  $aclFile = Join-Path $env:TEMP ('acl_' + [guid]::NewGuid().ToString('N'))
  icacls "$path" /save "$aclFile" /L /C | Out-Null

  if ($link.PSIsContainer) { cmd /c rmdir "$path" } else { cmd /c del /f /a "$path" }
  if ($link.LinkType -eq 'Junction') { cmd /c mklink /J "$path" "$newTarget" | Out-Null }
  elseif ($link.PSIsContainer) { cmd /c mklink /D "$path" "$newTarget" | Out-Null }
  else { cmd /c mklink "$path" "$newTarget" | Out-Null }

  icacls (Split-Path $path) /restore "$aclFile" /L /C | Out-Null
  Remove-Item $aclFile -ErrorAction SilentlyContinue
  if ($attributes -band [IO.FileAttributes]::Hidden) { attrib +h "$path" /L }
  if ($attributes -band [IO.FileAttributes]::System) { attrib +s "$path" /L }
  @((Get-Item -LiteralPath $path -Force).Target)[0] -eq $newTarget
}

$links = Get-ChildItem $Root -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue |
  Where-Object { $_.Target -and (@($_.Target)[0] -like "${From}:\*") }
"Found $(@($links).Count) link(s) pointing to ${From}:"

foreach ($link in $links) {
  $newTarget = "${To}:\" + (@($link.Target)[0]).Substring(3)
  if (-not $Apply) { "  $($link.FullName) -> $newTarget  [$($link.LinkType)]"; continue }
  $ok = Repair-Link $link $newTarget
  "  {0}  {1} -> {2}" -f $(if ($ok) { 'OK  ' } else { 'FAIL' }), $link.FullName, $newTarget
}
if (-not $Apply -and @($links).Count) { 'Dry run. Re-run with -Apply as Administrator to fix.' }
