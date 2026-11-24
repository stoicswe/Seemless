# E6 guest side (spike S9): install Steam's common redistributables the way
# a guest-side installscript runner would, then start an x64 D3D11 game with
# no Steam client in the guest. Spike code, not product. Run elevated:
#   powershell -ep bypass -f <drive>:\e6-guest.ps1
# The drive (label S9) holds "Steamworks Shared\_CommonRedist" and Reka\,
# copied from the Mac Steam library for this test only. Results go to
# C:\s9\ and are copied back to <drive>:\results\.
param([string]$GameExe = 'Reka.exe', [string]$AppId = '1737870', [int]$WatchSeconds = 120)
$ErrorActionPreference = 'Continue'
$drive = Split-Path -Qualifier $PSCommandPath
$out = 'C:\s9'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$log = "$out\e6.log"
function Log($m) { $line = "{0:u} {1}" -f (Get-Date), $m; Add-Content -Path $log -Value $line; Write-Host $line }

Log "OS $([Environment]::OSVersion.VersionString) build $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild) arch $env:PROCESSOR_ARCHITECTURE"
Get-CimInstance Win32_VideoController | ForEach-Object { Log "GPU $($_.Name) driver $($_.DriverVersion) status $($_.Status)" }

# ---- 1. Copy the library folder in, as the pseudo-prefix would see it.
$inst = "$out\Steamworks Shared"
$t = Measure-Command { robocopy "$drive\Steamworks Shared" $inst /E /NFL /NDL /NJH /NJS /NP | Out-Null }
Log ("copied _CommonRedist in {0:n1} s" -f $t.TotalSeconds)

# ---- 2. installscript runner: every "Run Process" entry once per HasRunKey.
function Read-RunProcess([string]$vdf) {
    # Minimal VDF reader for installscript.vdf: returns entries under "Run Process".
    $tokens = [regex]::Matches((Get-Content -Raw -LiteralPath $vdf), '"((?:[^"\\]|\\.)*)"|[{}]') | ForEach-Object {
        if ($_.Value -eq '{' -or $_.Value -eq '}') { $_.Value } else { $_.Groups[1].Value -replace '\\\\', '\' }
    }
    $stack = New-Object System.Collections.Stack
    $root = @{}; $cur = $root; $key = $null
    foreach ($tok in $tokens) {
        if ($tok -eq '{') { $n = @{}; $cur[$key] = $n; $stack.Push($cur); $cur = $n; $key = $null }
        elseif ($tok -eq '}') { $cur = $stack.Pop() }
        elseif ($null -eq $key) { $key = $tok }
        else { $cur[$key] = $tok; $key = $null }
    }
    $script = $root.GetEnumerator() | Where-Object { $_.Key -ieq 'installscript' } | Select-Object -First 1
    if (-not $script) { return @() }
    $rp = $script.Value.GetEnumerator() | Where-Object { $_.Key -ieq 'Run Process' } | Select-Object -First 1
    if (-not $rp) { return @() }
    return $rp.Value.GetEnumerator()
}
function Get-Field($h, $name) { ($h.GetEnumerator() | Where-Object { $_.Key -ieq $name } | Select-Object -First 1).Value }

foreach ($vdf in Get-ChildItem -LiteralPath "$inst\_CommonRedist" -Recurse -Filter installscript.vdf) {
    foreach ($entry in Read-RunProcess $vdf.FullName) {
        $name = $entry.Key; $e = $entry.Value
        $req = Get-Field $e 'Requirement_OS'
        if ($req -and (Get-Field $req 'Is64BitWindows') -eq '1' -and -not [Environment]::Is64BitOperatingSystem) { Log "skip $name (needs 64-bit)"; continue }
        $runKey = Get-Field $e 'HasRunKey'
        $regPath = $null
        if ($runKey) {
            $regPath = 'Registry::' + ($runKey -replace '^HKEY_LOCAL_MACHINE', 'HKEY_LOCAL_MACHINE')
            $done = (Get-ItemProperty -LiteralPath $regPath -ErrorAction SilentlyContinue).$name
            if ($done) { Log "skip $name (HasRunKey set)"; continue }
        }
        for ($i = 1; $i -le 9; $i++) {
            $proc = Get-Field $e "process $i"
            if (-not $proc) { break }
            $proc = $proc -replace '%INSTALLDIR%', $inst
            $cmdArgs = Get-Field $e "command $i"
            $sw = [Diagnostics.Stopwatch]::StartNew()
            if ($proc -match '\.cmd$') {
                $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "`"$proc`"") -Wait -PassThru -WindowStyle Hidden
            } elseif ($cmdArgs) {
                $p = Start-Process -FilePath $proc -ArgumentList $cmdArgs -Wait -PassThru
            } else {
                $p = Start-Process -FilePath $proc -Wait -PassThru
            }
            Log ("ran {0} [{1}] {2} {3} -> exit {4} in {5:n1} s" -f (Split-Path -Leaf (Split-Path $vdf.FullName)), $name, (Split-Path -Leaf $proc), $cmdArgs, $p.ExitCode, $sw.Elapsed.TotalSeconds)
            if ($p.ExitCode -in 0, 3010 -and $regPath) {
                New-Item -Path $regPath -Force | Out-Null
                New-ItemProperty -LiteralPath $regPath -Name $name -Value 1 -PropertyType DWord -Force | Out-Null
            }
        }
    }
}

# ---- 3. What landed where (ARM64 Windows: x64 VC++ redist goes to System32).
foreach ($f in 'System32\vcruntime140.dll', 'System32\vcruntime140_1.dll', 'System32\msvcp140.dll', 'System32\msvcr110.dll',
               'System32\d3dx9_43.dll', 'System32\d3dx11_43.dll', 'System32\d3dcompiler_43.dll', 'System32\xinput1_3.dll', 'System32\xactengine3_7.dll',
               'SysWOW64\vcruntime140.dll', 'SysWOW64\msvcp140.dll', 'SysWOW64\d3dx9_43.dll', 'SysWOW64\xinput1_3.dll') {
    $p = Join-Path $env:windir $f
    if (Test-Path $p) {
        $bytes = [IO.File]::ReadAllBytes($p); $pe = [BitConverter]::ToInt32($bytes, 0x3c); $m = [BitConverter]::ToUInt16($bytes, $pe + 4)
        Log ("present {0} version {1} machine 0x{2:x4}" -f $f, (Get-Item $p).VersionInfo.FileVersion, $m)
    } else { Log "missing $f" }
}
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\*' -ErrorAction SilentlyContinue | ForEach-Object { Log "VC runtime key $($_.PSChildName) $($_.Version) installed=$($_.Installed)" }

# ---- 4. The game, with no Steam client in the guest.
$game = "$out\game"
$t = Measure-Command { robocopy "$drive\game" $game /E /NFL /NDL /NJH /NJS /NP | Out-Null }
Log ("copied game in {0:n1} s" -f $t.TotalSeconds)
Set-Content -LiteralPath "$game\steam_appid.txt" -Value $AppId -NoNewline
$env:SteamAppId = $AppId; $env:SteamGameId = $AppId
$p = Start-Process -FilePath "$game\$GameExe" -ArgumentList @('-screen-fullscreen', '0', '-screen-width', '1280', '-screen-height', '720', '-logFile', "$out\player.log") -WorkingDirectory $game -PassThru
Log "started $GameExe pid $($p.Id)"
for ($s = 0; $s -lt $WatchSeconds; $s += 10) {
    Start-Sleep -Seconds 10
    $p.Refresh()
    if ($p.HasExited) { Log "game exited after ~$s s, code $($p.ExitCode)"; break }
    Log ("t+{0}s alive cpu {1:n1}s ws {2} MB title '{3}'" -f ($s + 10), $p.TotalProcessorTime.TotalSeconds, [int]($p.WorkingSet64 / 1MB), $p.MainWindowTitle)
}
dxdiag /t "$out\dxdiag.txt" | Out-Null
Start-Sleep -Seconds 5
New-Item -ItemType Directory -Force -Path "$drive\results" | Out-Null
Copy-Item -Path "$out\*.log", "$out\*.txt" -Destination "$drive\results" -Force -ErrorAction SilentlyContinue
Log 'E6 script done (game left running if alive)'
Copy-Item -Path $log -Destination "$drive\results" -Force
