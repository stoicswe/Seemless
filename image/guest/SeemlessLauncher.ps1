# Seemless launcher (Windows side of "Open in Seemless", docs/07 "Files").
#
# Runs in the logged-on user's session (scheduled task "Seemless\Launcher",
# at logon, highest privileges). The Mac hot-plugs a small USB drive labelled
# SLRUN that holds one installer plus seemless-launch.txt:
#   line 1: request id (32 hex characters, new for every request)
#   line 2: file name of the installer on the drive (.exe or .msi, no path)
# Each request id runs once: the installer is copied to %TEMP% (so the Mac
# can remove the drive) and started there. Nothing else on the drive runs.
#
# Until the guest agent exists (M4) this is the only host -> guest launch
# path. Windows PowerShell 5.1 only; no modules beyond the inbox Storage one.

$ErrorActionPreference = 'Continue'
$base = Join-Path $env:LOCALAPPDATA 'Seemless'
$state = Join-Path $base 'launched.txt'
$log = Join-Path $base 'launcher.log'
New-Item -ItemType Directory -Force -Path $base | Out-Null

function Write-Log([string]$message) {
    Add-Content -Path $log -Value ("{0:u} {1}" -f (Get-Date), $message)
}

function Test-Request([string]$id, [string]$file) {
    if ($id -notmatch '^[0-9a-f]{32}$') { return $false }
    if ([string]::IsNullOrWhiteSpace($file)) { return $false }
    if ($file.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $false }
    if ($file -match '\.\.') { return $false }
    return $file -match '\.(exe|msi)$'
}

Write-Log 'launcher started'
while ($true) {
    try {
        $volumes = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'SLRUN' -and $_.DriveLetter }
        foreach ($v in $volumes) {
            $root = "$($v.DriveLetter):\"
            $request = Join-Path $root 'seemless-launch.txt'
            if (-not (Test-Path -LiteralPath $request)) { continue }
            $lines = @(Get-Content -LiteralPath $request -TotalCount 2)
            if ($lines.Count -lt 2) { continue }
            $id = $lines[0].Trim().ToLowerInvariant()
            $file = $lines[1].Trim()
            if ((Test-Path -LiteralPath $state) -and (Select-String -LiteralPath $state -SimpleMatch $id -Quiet)) { continue }
            Add-Content -Path $state -Value $id
            if (-not (Test-Request $id $file)) { Write-Log "rejected request $id ($file)"; continue }

            $source = Join-Path $root $file
            $dir = Join-Path $env:TEMP "Seemless\$id"
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Copy-Item -LiteralPath $source -Destination $dir
            $copy = Join-Path $dir $file
            Write-Log "starting $file ($id)"
            if ($file -match '\.msi$') {
                Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$copy`"") -WorkingDirectory $dir
            } else {
                Start-Process -FilePath $copy -WorkingDirectory $dir
            }
        }
    } catch {
        Write-Log "error: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 2
}
