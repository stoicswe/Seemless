# EXPERIMENTAL: installs WacOS (https://github.com/renzyxx/WacOS), a
# macOS-style shell that replaces the taskbar and Start menu, for the
# signed-in user (docs/03 "Optional: WacOS"; owner, 2026-11-24).
#
# Seemless ships none of WacOS: its licence forbids redistributing or
# bundling it. This script downloads the pinned official release named in
# wacos.json (next to it), checks its SHA-256 and runs WacOS's own installer
# (instalador\instalar.ps1 -Silencioso: full shell, every question "yes").
# The person who created the VM accepted the WacOS licence on the Mac.
#
#   -Register  (firstboot.cmd, as SYSTEM) registers the logon task
#              \Seemless\WacOS for every interactive user, without
#              elevation: WacOS installs per user and needs no admin.
#   (none)     (that task) installs once per user, then does nothing.
#
# The first sign-in runs offline (VMConfig.offlineUntilSetupDone): the
# script waits until github.com answers, so it installs once the Mac plugs
# the network in. A failed download or a wrong checksum is retried at the
# next sign-in. Log: %LOCALAPPDATA%\Seemless\wacos.log.
# Windows PowerShell 5.1 only; curl.exe is inbox on Windows 11.
param([switch]$Register)

# 'Continue': with 'Stop', Windows PowerShell 5.1 turns any stderr line of a
# native command (curl.exe, the child powershell.exe) into a terminating
# error. Cmdlets that must stop say -ErrorAction Stop.
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot

if ($Register) {
    $script = Join-Path $here 'install-wacos.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 8) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskPath '\Seemless\' -TaskName 'WacOS' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    Write-Output "registered \Seemless\WacOS -> $script"
    exit 0
}

$base = Join-Path $env:LOCALAPPDATA 'Seemless'
New-Item -ItemType Directory -Force -Path $base | Out-Null
$log = Join-Path $base 'wacos.log'
$done = Join-Path $base 'wacos-done.txt'
function Write-Log([string]$message) { Add-Content -Path $log -Value ("{0:u} {1}" -f (Get-Date), $message) }

try {
    $cfg = Get-Content -Raw -LiteralPath (Join-Path $here 'wacos.json') -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    # The host validated these too (WacOSRelease.validationErrors); check
    # again before anything reaches a URL or a path.
    $tag = [string]$cfg.tag; $url = [string]$cfg.url; $sha = ([string]$cfg.sha256).ToLowerInvariant()
    if ($tag -notmatch '^[A-Za-z0-9._-]{1,40}$') { throw "bad tag '$tag'" }
    if ($sha -notmatch '^[0-9a-f]{64}$') { throw 'bad sha256' }
    if ($url -notmatch '^https://github\.com/renzyxx/WacOS/releases/download/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.zip$' -or
        -not $url.StartsWith("https://github.com/renzyxx/WacOS/releases/download/$tag/")) { throw "bad url '$url'" }

    if ((Test-Path -LiteralPath $done) -and ((Get-Content -LiteralPath $done -TotalCount 1) -eq $tag)) { exit 0 }
    $shell = Join-Path $env:LOCALAPPDATA 'Programs\WacOS\bin\WacOSShell.exe'
    if (Test-Path -LiteralPath $shell) {
        Write-Log "WacOS already installed ($shell); nothing to do"
        Set-Content -LiteralPath $done -Value $tag
        exit 0
    }
    Write-Log "WacOS $tag for ${env:USERNAME}: waiting for the network"

    # Wait for github.com (the first sign-in is offline). Up to 6 hours.
    $deadline = (Get-Date).AddHours(6)
    while ($true) {
        & curl.exe --silent --head --fail --max-time 15 --output NUL 'https://github.com/' 2>$null
        if ($LASTEXITCODE -eq 0) { break }
        if ((Get-Date) -gt $deadline) { Write-Log 'no network after 6 hours; trying again at the next sign-in'; exit 1 }
        Start-Sleep -Seconds 20
    }

    $work = Join-Path $env:TEMP "Seemless\wacos-$tag"
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $zip = Join-Path $work 'WacOS.zip'
    Write-Log "downloading $url"
    & curl.exe --silent --show-error --fail --location --retry 5 --retry-delay 10 --proto '=https' --output $zip $url 2>&1 |
        ForEach-Object { Write-Log "curl: $_" }
    if ($LASTEXITCODE -ne 0) { Write-Log "download failed (curl exit $LASTEXITCODE); trying again at the next sign-in"; exit 1 }

    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
    if ($got -ne $sha) {
        Write-Log "checksum mismatch: expected $sha, got $got; deleted, not installed"
        Remove-Item -LiteralPath $work -Recurse -Force
        exit 1
    }
    Write-Log "checksum ok ($got)"

    $unpacked = Join-Path $work 'x'
    Expand-Archive -LiteralPath $zip -DestinationPath $unpacked -Force -ErrorAction Stop
    # The package's installer: instalador\instalar.ps1 with bin\WacOSShell.exe
    # one level up (the layout instalar.ps1 itself checks for).
    $installer = Get-ChildItem -LiteralPath $unpacked -Recurse -Filter 'instalar.ps1' -File |
        Where-Object { (Test-Path (Join-Path $_.Directory.FullName '..\bin\WacOSShell.exe')) -or
                       (Test-Path (Join-Path $_.Directory.FullName 'bin\WacOSShell.exe')) } |
        Sort-Object { $_.FullName.Length } | Select-Object -First 1
    if (-not $installer) { Write-Log 'no instalar.ps1 next to bin\WacOSShell.exe in the package; not installed'; exit 1 }

    Write-Log "running $($installer.FullName) -Silencioso"
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer.FullName -Silencioso 2>&1 |
        ForEach-Object { Write-Log "wacos: $_" }
    Write-Log "installer exit $LASTEXITCODE"
    if (-not (Test-Path -LiteralPath $shell)) { Write-Log "not installed: $shell missing"; exit 1 }
    Set-Content -LiteralPath $done -Value $tag
    Write-Log "WacOS $tag installed"
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
} catch {
    Write-Log "error: $($_.Exception.Message)"
    exit 1
}
