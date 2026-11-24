# Zen stand-in helper: test tooling until the Windows agent exists (WP4.2).
#
# Runs in the guest. Reports the top-level windows of one app (default:
# Notepad) to `seemlessctl mock-agent` over the VM's user-mode network, and
# applies the host's size and window commands, so Zen mode can be tried on a
# real Windows app. While it runs, Windows' standard cursors are blank (the
# 3D driver draws the pointer into the frame; only the Mac pointer must show).
# They come back when it stops.
#
# Protocol: GuestHelperMessage (kit/Sources/SeemlessKit/Agent/GuestHelperBridge.swift).
# Start (in the guest, with the mock agent's script setting "guestHelper"):
#   powershell -ExecutionPolicy Bypass -File zen-guest-helper.ps1 [-Process Notepad] [-Port 47800]
param([string]$Process = 'Notepad', [string]$HostAddress = '10.0.2.2', [int]$Port = 47800)

Add-Type -Namespace Zen -Name U -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int size);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint f);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern IntPtr CreateCursor(IntPtr h, int x, int y, int w, int t, byte[] a, byte[] b);
[DllImport("user32.dll")] public static extern bool SetSystemCursor(IntPtr c, uint id);
[DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, IntPtr c, uint d);
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
'@

function Hide-Cursors {
    $and = [byte[]](,255 * 128); $xor = [byte[]](,0 * 128)
    foreach ($id in 32512,32513,32514,32515,32516,32642,32643,32644,32645,32646,32648,32649,32650,32651) {
        [void][Zen.U]::SetSystemCursor([Zen.U]::CreateCursor([IntPtr]::Zero, 0, 0, 32, 32, $and, $xor), $id)
    }
}
function Restore-Cursors { [void][Zen.U]::SystemParametersInfo(0x57, 0, [IntPtr]::Zero, 0) }  # SPI_SETCURSORS

function Get-Frame([IntPtr]$h) {
    $f = New-Object Zen.U+RECT
    [void][Zen.U]::DwmGetWindowAttribute($h, 9, [ref]$f, 16)  # DWMWA_EXTENDED_FRAME_BOUNDS
    $f
}

function Get-Title([IntPtr]$h) {
    $n = [Zen.U]::GetWindowTextLength($h)
    $sb = New-Object System.Text.StringBuilder ($n + 1)
    [void][Zen.U]::GetWindowText($h, $sb, $sb.Capacity)
    ($sb.ToString() -replace '[\r\n]', ' ')
}

# "set": the host asks for a visible frame; SetWindowPos takes the outer
# rectangle, which has invisible resize borders around the visible frame.
function Set-Frame([IntPtr]$h, [int]$x, [int]$y, [int]$w, [int]$hh) {
    $o = New-Object Zen.U+RECT
    [void][Zen.U]::GetWindowRect($h, [ref]$o)
    $f = Get-Frame $h
    $l = $f.L - $o.L; $t = $f.T - $o.T; $r = $o.R - $f.R; $b = $o.B - $f.B
    [void][Zen.U]::SetWindowPos($h, [IntPtr]::Zero, $x - $l, $y - $t, $w + $l + $r, $hh + $t + $b, 0x14)  # NOZORDER | NOACTIVATE
}

# Out of the way: in tier 2 a window on top in the guest shows in every crop below it.
[void][Zen.U]::ShowWindow([Zen.U]::GetConsoleWindow(), 6)  # SW_MINIMIZE

$commands = @{ close = 0xF060; min = 0xF020; max = 0xF030; restore = 0xF120 }  # WM_SYSCOMMAND SC_*

Hide-Cursors
try {
    while ($true) {
        try {
            $client = New-Object Net.Sockets.TcpClient($HostAddress, $Port)
        } catch {
            Start-Sleep -Milliseconds 500; continue
        }
        Write-Host "connected to $($HostAddress):$Port"
        $stream = $client.GetStream()
        $utf8 = New-Object Text.UTF8Encoding($false)
        $buffer = New-Object byte[] 4096
        $pending = ''
        $last = @{}
        try {
            while ($client.Connected) {
                $handles = @(Get-Process -Name $Process -ErrorAction SilentlyContinue |
                    Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | ForEach-Object { $_.MainWindowHandle })
                $out = ''
                foreach ($h in $handles) {
                    $id = [int64]$h
                    $f = Get-Frame $h
                    $state = if ([Zen.U]::IsIconic($h)) { 'min' } elseif ([Zen.U]::IsZoomed($h)) { 'max' } else { 'normal' }
                    $line = "rect $id $($f.L) $($f.T) $($f.R - $f.L) $($f.B - $f.T) $state"
                    $title = Get-Title $h
                    # Tier 2 shows whatever is on top in the guest: keep the reported
                    # windows above the rest, without activating them (the real
                    # agent raises the window under the pointer, docs/05 Input model).
                    if (-not $last.ContainsKey($id)) { [void][Zen.U]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 0, 0, 0x13) }  # NOSIZE|NOMOVE|NOACTIVATE
                    if ($last[$id] -ne "$line|$title") {
                        $out += "$line`n"
                        if (-not $last.ContainsKey($id) -or -not $last[$id].EndsWith("|$title")) { $out += "title $id $title`n" }
                        $last[$id] = "$line|$title"
                    }
                }
                foreach ($id in @($last.Keys)) {
                    if (-not ($handles | Where-Object { [int64]$_ -eq $id })) { $out += "gone $id`n"; $last.Remove($id) }
                }
                if ($out) { $bytes = $utf8.GetBytes($out); $stream.Write($bytes, 0, $bytes.Length) }

                while ($stream.DataAvailable) {
                    $n = $stream.Read($buffer, 0, $buffer.Length)
                    $pending += [Text.Encoding]::ASCII.GetString($buffer, 0, $n)
                }
                while (($i = $pending.IndexOf("`n")) -ge 0) {
                    $parts = $pending.Substring(0, $i).Trim().Split(' ')
                    $pending = $pending.Substring($i + 1)
                    $h = [IntPtr][int64]$parts[1]
                    if (-not ($handles | Where-Object { $_ -eq $h })) { continue }  # only the windows it reports
                    if ($parts[0] -eq 'set' -and $parts.Count -eq 6) {
                        Set-Frame $h ([int]$parts[2]) ([int]$parts[3]) ([int]$parts[4]) ([int]$parts[5])
                    } elseif ($parts[0] -eq 'cmd' -and $commands.ContainsKey($parts[2])) {
                        [void][Zen.U]::PostMessage($h, 0x112, [IntPtr]$commands[$parts[2]], [IntPtr]::Zero)
                    }
                }
                [Threading.Thread]::Sleep(15)
            }
        } catch {
            Write-Host "disconnected: $($_.Exception.Message)"
        } finally {
            $client.Close()
        }
    }
} finally {
    Restore-Cursors
}
