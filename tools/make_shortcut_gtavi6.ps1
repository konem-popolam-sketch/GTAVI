$ErrorActionPreference = 'Stop'

# Cyrillic is built from code points so this file stays ASCII-only: Windows
# PowerShell 5.1 reads a BOM-less .ps1 as ANSI and mangles literal Cyrillic.
function From-CodePoints([int[]]$points) {
  return (-join ($points | ForEach-Object { [char]$_ }))
}

$desktop = [Environment]::GetFolderPath('Desktop')
$gameDir = 'C:\Users\Igor\Downloads\GTAVI'
$gameExe = Join-Path $gameDir 'tools\Godot_v4.7.2-stable_win64.exe'

# "GTA 6" -> G(0x413) T(0x422) A(0x410) space 6
$label = From-CodePoints 0x413, 0x422, 0x410, 0x20, 0x36
# "Nochnaya smena" (old name) -> to find and remove the stale shortcuts
$oldLabel = From-CodePoints 0x41D, 0x43E, 0x447, 0x43D, 0x430, 0x44F, 0x20, 0x441, 0x43C, 0x435, 0x43D, 0x430

$batDest = Join-Path $desktop ($label + '.bat')
Copy-Item -LiteralPath (Join-Path $gameDir 'play.bat') -Destination $batDest -Force

# .lnk is created inside the project folder under an ASCII name first: WScript's Save()
# fails (FileNotFoundException) when the destination path contains Cyrillic, so the
# Cyrillic file name is applied by Copy-Item afterwards.
$lnkLocal = Join-Path $gameDir '_gtavi6.lnk'
$lnkDest = Join-Path $desktop ($label + '.lnk')
$ws = New-Object -ComObject WScript.Shell
$s = $ws.CreateShortcut($lnkLocal)
$s.TargetPath = $gameExe
$s.Arguments = '--path "' + $gameDir + '"'
$s.WorkingDirectory = $gameDir
$s.Description = 'GTA 6 - night shift story location'
$s.Save()
$ws = $null
Copy-Item -LiteralPath $lnkLocal -Destination $lnkDest -Force
Remove-Item -LiteralPath $lnkLocal -Force

foreach ($stale in @((Join-Path $desktop ($oldLabel + '.lnk')), (Join-Path $desktop ($oldLabel + '.bat')))) {
  if (Test-Path -LiteralPath $stale) {
    $archive = Join-Path $gameDir ('docs\archive\desktop_' + (Split-Path -Leaf $stale))
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $archive) | Out-Null
    Move-Item -LiteralPath $stale -Destination $archive -Force
    Write-Output ('archived=' + (Split-Path -Leaf $stale))
  }
}

Write-Output ('bat=' + (Test-Path -LiteralPath $batDest))
Write-Output ('lnk=' + (Test-Path -LiteralPath $lnkDest))
