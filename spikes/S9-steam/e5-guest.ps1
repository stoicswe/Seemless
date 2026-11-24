# E5 guest side: echo everything read from the virtio-serial port
# \\.\Global\seemless.steam back to the host. Spike code, not product.
# Needs the vioserial driver. Logs to C:\s9\e5.log. Waits for the port to
# appear (it is hot-added), then runs until the port goes away.
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path C:\s9 | Out-Null
$log = 'C:\s9\e5.log'
function Log($m) { Add-Content -Path $log -Value ("{0:u} {1}" -f (Get-Date), $m) }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;
public static class S9Echo {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(SafeFileHandle h, byte[] buf, int n, out int read, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(SafeFileHandle h, byte[] buf, int n, out int written, IntPtr ov);
    public static SafeFileHandle Open(string path, int seconds) {
        for (int i = 0; i < seconds * 2; i++) {
            var h = CreateFile(path, 0xC0000000, 0, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (!h.IsInvalid) return h;
            Thread.Sleep(500);
        }
        return null;
    }
    public static string Echo(SafeFileHandle h) {
        var buf = new byte[1 << 17];
        var tail = new byte[1 << 17];
        long total = 0;
        while (true) {
            int r;
            if (!ReadFile(h, buf, buf.Length, out r, IntPtr.Zero)) return "read failed, error " + Marshal.GetLastWin32Error() + " after " + total + " bytes";
            if (r == 0) continue;
            int off = 0;
            while (off < r) {
                byte[] src = buf;
                if (off > 0) { Array.Copy(buf, off, tail, 0, r - off); src = tail; }
                int w;
                if (!WriteFile(h, src, r - off, out w, IntPtr.Zero)) return "write failed, error " + Marshal.GetLastWin32Error();
                off += w;
            }
            total += r;
        }
    }
}
'@

$port = '\\.\Global\seemless.steam'
Log "waiting up to 30 min for $port"
$h = [S9Echo]::Open($port, 1800)
if ($null -eq $h) { Log 'port never appeared'; exit 1 }
Log 'port open, echoing'
Log ([S9Echo]::Echo($h))
