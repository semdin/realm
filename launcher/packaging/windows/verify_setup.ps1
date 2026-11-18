# Installs ThousandRealms-Setup.exe silently, checks what it put where, starts
# the launcher headless from there and uninstalls it again. Game data in
# %LOCALAPPDATA%\ThousandRealms is left alone (a silent uninstall keeps it).
#   verify_setup.ps1 <path to ThousandRealms-Setup.exe>
param([Parameter(Mandatory = $true)][string]$Setup)
$ErrorActionPreference = 'Stop'

$app = Join-Path $env:LOCALAPPDATA 'Programs\Thousand Realms'
$exe = Join-Path $app 'ThousandRealms_Launcher.exe'
$menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Thousand Realms.lnk'
$desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Thousand Realms.lnk'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{6E0C8E5B-5B1F-4A8E-9C55-0E7C3B7F4D21}_is1'

function Assert-That([bool]$ok, [string]$what) {
    if (-not $ok) { throw "FAILED: $what" }
    Write-Output "[ok] $what"
}

if ((Test-Path $app) -or (Test-Path $menu) -or (Test-Path $desktop)) {
    throw "Thousand Realms is already installed here; not touching it"
}

$p = Start-Process -FilePath $Setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/TASKS=desktopicon' -PassThru -Wait
Assert-That ($p.ExitCode -eq 0) "setup exits 0 (got $($p.ExitCode))"
Assert-That (Test-Path $exe) 'launcher installed per user'
Assert-That (Test-Path (Join-Path $app 'THIRD_PARTY_NOTICES.txt')) 'third-party notices installed'
Assert-That (Test-Path $menu) 'Start Menu shortcut'
Assert-That (Test-Path $desktop) 'desktop shortcut'
$entry = Get-ItemProperty $uninstallKey
Assert-That ($entry.DisplayName -eq 'Thousand Realms') 'Apps & features entry under HKCU'

$shell = New-Object -ComObject WScript.Shell
Assert-That ($shell.CreateShortcut($menu).TargetPath -ieq $exe) 'Start Menu shortcut points at the launcher'

$out = Join-Path $env:TEMP 'tr-setup-state.json'
$state = Start-Process -FilePath $exe -ArgumentList '--print-state' -RedirectStandardOutput $out -PassThru -Wait
Assert-That ($state.ExitCode -eq 0) 'installed launcher runs'
$json = Get-Content $out -Raw | ConvertFrom-Json
Assert-That ($json.install_root -like '*\ThousandRealms') "game data stays outside the program folder ($($json.install_root))"
Remove-Item $out -Force

$uninstaller = ($entry.UninstallString -replace '"', '')
$u = Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -PassThru -Wait
Assert-That ($u.ExitCode -eq 0) 'uninstaller exits 0'
# The uninstaller finishes from a temporary copy: give it a moment.
for ($i = 0; $i -lt 100 -and (Test-Path $app); $i++) { Start-Sleep -Milliseconds 250 }
Assert-That (-not (Test-Path $app)) 'program folder removed'
Assert-That (-not (Test-Path $menu)) 'Start Menu shortcut removed'
Assert-That (-not (Test-Path $desktop)) 'desktop shortcut removed'
Assert-That (-not (Test-Path $uninstallKey)) 'Apps & features entry removed'
Write-Output 'SETUP VERIFIED'
