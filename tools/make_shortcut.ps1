$ErrorActionPreference = 'Stop'

# Cyrillic is built from code points so this file stays ASCII-only: Windows
# PowerShell 5.1 reads a BOM-less .ps1 as ANSI and mangles literal Cyrillic.
function From-CodePoints([int[]]$points) {
  return (-join ($points | ForEach-Object { [char]$_ }))
}

$desktop = [Environment]::GetFolderPath('Desktop')
$gameDir = 'C:\Users\Igor\Downloads\GTAVI'
$gameExe = Join-Path $gameDir 'tools\Godot_v4.7.2-stable_win64.exe'

# "Ночная смена"
$label = From-CodePoints 0x41D, 0x43E, 0x447, 0x43D, 0x430, 0x44F, 0x20, 0x441, 0x43C, 0x435, 0x43D, 0x430

$batDest = Join-Path $desktop ($label + '.bat')
Copy-Item -LiteralPath (Join-Path $gameDir 'play.bat') -Destination $batDest -Force

$lnkDest = Join-Path $desktop ($label + '.lnk')
$ws = New-Object -ComObject WScript.Shell
$s = $ws.CreateShortcut($lnkDest)
$s.TargetPath = $gameExe
$s.Arguments = '--path "' + $gameDir + '"'
$s.WorkingDirectory = $gameDir
$s.Description = 'Night Shift - 3D story location'
$s.Save()
$ws = $null

Write-Output ("bat=" + (Test-Path -LiteralPath $batDest))
Write-Output ("lnk=" + (Test-Path -LiteralPath $lnkDest))
