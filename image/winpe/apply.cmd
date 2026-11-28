@echo off
rem ==========================================================================
rem Seemless apply-time install (docs/03 "apply.cmd (WinPE phase)").
rem
rem Runs inside the Windows ISO's own WinPE, started by autounattend.xml.
rem Installs Windows onto the NVMe disk with DISM, applies the removal recipe
rem offline, injects drivers and the agent, then reboots into the new
rem install. Windows Setup's own pages never run.
rem
rem   %1  payload drive, e.g. E:
rem
rem Everything is logged to <payload>\seemless\result\apply.log and the final
rem outcome to result\status.txt, which the host reads after the VM stops.
rem On failure WinPE shuts down instead of rebooting.
rem
rem S4 (2026-11-23, build 26300 ARM64): Setup runs this script; WinPE has
rem no findstr or where, so text is parsed with for /f only.
rem ==========================================================================
setlocal EnableExtensions EnableDelayedExpansion

set "P=%~1"
if "%P%"=="" set "P=%~d0"
set "S=%P%\seemless"
set "R=%S%\result"
if not exist "%R%" mkdir "%R%"
set "LOG=%R%\apply.log"
set "STAGE=init"
set "WARNINGS=0"
set "W=W:"

echo ==== Seemless apply %DATE% %TIME% > "%LOG%"
echo RUNNING> "%R%\status.txt"

if not exist "%S%\config.cmd" (
  call :fail "config.cmd missing from payload"
  goto :eof
)
call "%S%\config.cmd"
call :log "config: index=%SL_INDEX% compact=%SL_COMPACT% inventory=%SL_INVENTORY% testsigning=%SL_TESTSIGNING%"

rem ---------------------------------------------------------------- tools
rem WinPE ships a reduced tool set (S4, build 26300 ARM64: no findstr, no
rem where). Log what is there and stop early if a required tool is missing,
rem instead of failing obscurely later. Uses %%~$PATH:t, no external tools.
set "STAGE=tools"
set "MISSING="
for %%t in (diskpart.exe dism.exe bcdboot.exe reg.exe wpeutil.exe) do (
  if "%%~$PATH:t"=="" (set "MISSING=!MISSING! %%t") else (>> "%LOG%" echo [tools] %%~$PATH:t)
)
for %%t in (bcdedit.exe xcopy.exe takeown.exe icacls.exe findstr.exe) do (
  if "%%~$PATH:t"=="" (>> "%LOG%" echo [tools] not available: %%t) else (>> "%LOG%" echo [tools] %%~$PATH:t)
)
if defined MISSING (
  call :fail "required tools missing:!MISSING!"
  goto :eof
)

rem ---------------------------------------------------------------- media
set "STAGE=find-media"
set "IMG="
for %%d in (C D E F G H I J K L M N O P Q R S T U V Y Z) do (
  if not defined IMG if exist "%%d:\sources\install.wim" set "IMG=%%d:\sources\install.wim"
  if not defined IMG if exist "%%d:\sources\install.esd" set "IMG=%%d:\sources\install.esd"
)
if not defined IMG (
  call :fail "no sources\install.wim or install.esd on any drive"
  goto :eof
)
call :log "image: %IMG%"

rem ---------------------------------------------------------------- disk
rem Pick the first NVMe disk. The payload and the ISO are USB disks, so
rem "select disk 0" could wipe the wrong one. diskpart prints a line
rem "Type   : NVMe"; it is parsed with for /f because WinPE has no findstr.
rem The listing goes to the log so a failure here can be diagnosed.
set "STAGE=find-disk"
set "DISK="
> "%TEMP%\sl-list.txt" echo list disk
diskpart /s "%TEMP%\sl-list.txt" >> "%LOG%" 2>&1
for /l %%n in (0,1,7) do (
  if not defined DISK (
    > "%TEMP%\sl-detail.txt" echo select disk %%n
    >> "%TEMP%\sl-detail.txt" echo detail disk
    diskpart /s "%TEMP%\sl-detail.txt" > "%TEMP%\sl-detail.out" 2>&1
    for /f "usebackq tokens=1,2,3" %%a in ("%TEMP%\sl-detail.out") do (
      if /i "%%a"=="Type" if "%%b"==":" if /i "%%c"=="NVMe" set "DISK=%%n"
    )
  )
)
if not defined DISK (
  call :fail "no NVMe disk found"
  goto :eof
)
call :log "target disk: %DISK%"

set "STAGE=partition"
> "%TEMP%\sl-part.txt" (
  echo select disk %DISK%
  echo clean
  echo convert gpt
  echo create partition efi size=260
  echo format quick fs=fat32 label="System"
  echo assign letter=S
  echo create partition msr size=16
  echo create partition primary
  echo format quick fs=ntfs label="Windows"
  echo assign letter=W
)
call :run diskpart /s "%TEMP%\sl-part.txt" || goto :eof

rem ---------------------------------------------------------------- apply
set "STAGE=apply-image"
set "COMPACTARG="
if "%SL_COMPACT%"=="1" set "COMPACTARG=/Compact"
call :run dism /English /Apply-Image /ImageFile:"%IMG%" /Index:%SL_INDEX% /ApplyDir:%W%\ %COMPACTARG% || goto :eof

rem WinPE's X: RAM disk is too small for DISM servicing (it warns in the
rem inventory). Servicing uses a scratch folder on the new Windows volume,
rem removed before the reboot.
set "SCRATCH=%W%\SeemlessScratch"
if not exist "%SCRATCH%" mkdir "%SCRATCH%"
set "DISMX=/ScratchDir:%SCRATCH%"

rem ---------------------------------------------------------------- inventory
rem Real package/capability/feature lists for writing the removal recipe
rem (WP2.3). Cheap, so it always runs unless disabled.
if "%SL_INVENTORY%"=="1" (
  set "STAGE=inventory"
  dism /English /Image:%W%\ %DISMX% /Get-ProvisionedAppxPackages > "%R%\inventory-appx.txt" 2>&1
  dism /English /Image:%W%\ %DISMX% /Get-Capabilities > "%R%\inventory-capabilities.txt" 2>&1
  dism /English /Image:%W%\ %DISMX% /Get-Features > "%R%\inventory-features.txt" 2>&1
  call :log "inventory written"
)

rem ---------------------------------------------------------------- recipe
set "STAGE=recipe-appx"
rem For each recipe prefix, find "PackageName : <name>" lines in the DISM
rem listing whose name starts with the prefix. Pure cmd (WinPE has no
rem findstr): "!N:*prefix=!" strips through the first occurrence of the
rem prefix, so prefix + rest == name exactly when the name starts with it.
if exist "%S%\recipe\remove-appx.txt" (
  dism /English /Image:%W%\ %DISMX% /Get-ProvisionedAppxPackages > "%TEMP%\sl-appx.txt" 2>&1
  for /f "usebackq eol=# delims=" %%p in ("%S%\recipe\remove-appx.txt") do (
    set "HIT="
    for /f "usebackq tokens=1,2,3" %%a in ("%TEMP%\sl-appx.txt") do (
      if /i "%%a"=="PackageName" if "%%b"==":" (
        set "N=%%c"
        set "REST=!N:*%%p=!"
        if /i "%%p!REST!"=="!N!" (
          set "HIT=1"
          call :try dism /English /Image:%W%\ %DISMX% /Remove-ProvisionedAppxPackage /PackageName:%%c
        )
      )
    )
    if not defined HIT call :log "skip appx %%p: not in this image"
  )
)

set "STAGE=recipe-capabilities"
if exist "%S%\recipe\remove-capabilities.txt" (
  for /f "usebackq eol=# delims=" %%c in ("%S%\recipe\remove-capabilities.txt") do (
    call :try dism /English /Image:%W%\ %DISMX% /Remove-Capability /CapabilityName:%%c
  )
)

set "STAGE=recipe-features"
if exist "%S%\recipe\disable-features.txt" (
  for /f "usebackq eol=# delims=" %%f in ("%S%\recipe\disable-features.txt") do (
    call :try dism /English /Image:%W%\ %DISMX% /Disable-Feature /FeatureName:%%f
  )
)

rem Paths are relative to the Windows partition root. Owned by
rem TrustedInstaller, so take ownership first (as Tiny11 does).
set "STAGE=recipe-delete"
rem What is installed under Program Files (x86)\Microsoft (Edge, EdgeCore,
rem EdgeUpdate, EdgeWebView differ by build), for writing delete-paths.txt.
>> "%LOG%" echo [%TIME%] [recipe-delete] contents of Program Files (x86)\Microsoft:
dir /b "%W%\Program Files (x86)\Microsoft" >> "%LOG%" 2>&1
if exist "%S%\recipe\delete-paths.txt" (
  for /f "usebackq eol=# delims=" %%x in ("%S%\recipe\delete-paths.txt") do (
    if exist "%W%\%%x" (
      rem One line per file otherwise (1600+ for Edge); keep errors only.
      takeown /f "%W%\%%x" /r /d y >nul 2>>"%LOG%"
      icacls "%W%\%%x" /grant *S-1-5-32-544:F /t /c /q >nul 2>>"%LOG%"
      rd /s /q "%W%\%%x" >> "%LOG%" 2>&1 || del /f /q "%W%\%%x" >> "%LOG%" 2>&1
      call :log "deleted %%x"
    ) else (
      call :log "skip missing %%x"
    )
  )
)

rem .reg files address the offline hives as HKEY_LOCAL_MACHINE\zSEEMLESS_<HIVE>
rem (SOFTWARE, SYSTEM, DEFAULT, NTUSER).
set "STAGE=recipe-registry"
if exist "%S%\recipe\registry\*.reg" (
  reg load HKLM\zSEEMLESS_SOFTWARE "%W%\Windows\System32\config\SOFTWARE" >> "%LOG%" 2>&1
  reg load HKLM\zSEEMLESS_SYSTEM "%W%\Windows\System32\config\SYSTEM" >> "%LOG%" 2>&1
  reg load HKLM\zSEEMLESS_DEFAULT "%W%\Windows\System32\config\DEFAULT" >> "%LOG%" 2>&1
  reg load HKLM\zSEEMLESS_NTUSER "%W%\Users\Default\NTUSER.DAT" >> "%LOG%" 2>&1
  for %%r in ("%S%\recipe\registry\*.reg") do call :try reg import "%%~fr"
  reg unload HKLM\zSEEMLESS_NTUSER >> "%LOG%" 2>&1
  reg unload HKLM\zSEEMLESS_DEFAULT >> "%LOG%" 2>&1
  reg unload HKLM\zSEEMLESS_SYSTEM >> "%LOG%" 2>&1
  reg unload HKLM\zSEEMLESS_SOFTWARE >> "%LOG%" 2>&1
)

rem What the image holds after the recipe, so every build shows what the
rem recipe really removed (compare with inventory-*.txt).
if "%SL_INVENTORY%"=="1" if exist "%S%\recipe\*.txt" (
  set "STAGE=inventory-after"
  dism /English /Image:%W%\ %DISMX% /Get-ProvisionedAppxPackages > "%R%\after-appx.txt" 2>&1
  dism /English /Image:%W%\ %DISMX% /Get-Capabilities > "%R%\after-capabilities.txt" 2>&1
  dism /English /Image:%W%\ %DISMX% /Get-Features > "%R%\after-features.txt" 2>&1
  call :log "after-recipe inventory written"
)

rem ---------------------------------------------------------------- drivers, agent
set "STAGE=drivers"
dir /s /b "%S%\drivers\*.inf" >nul 2>&1 && (
  call :run dism /English /Image:%W%\ /Add-Driver /Driver:"%S%\drivers" /Recurse || goto :eof
)

set "STAGE=agent"
if exist "%S%\agent\*" (
  if not exist "%W%\Program Files\Seemless" mkdir "%W%\Program Files\Seemless"
  call :run xcopy "%S%\agent" "%W%\Program Files\Seemless" /e /i /h /y || goto :eof
)

rem ---------------------------------------------------------------- first boot
set "STAGE=unattend"
if not exist "%W%\Windows\Panther" mkdir "%W%\Windows\Panther"
call :run copy /y "%S%\unattend.xml" "%W%\Windows\Panther\unattend.xml" || goto :eof
if not exist "%W%\Windows\Setup\Scripts" mkdir "%W%\Windows\Setup\Scripts"
call :run copy /y "%S%\SetupComplete.cmd" "%W%\Windows\Setup\Scripts\SetupComplete.cmd" || goto :eof
call :run copy /y "%S%\firstboot.cmd" "%W%\Windows\Setup\Scripts\firstboot.cmd" || goto :eof
if not exist "%W%\ProgramData\Seemless" mkdir "%W%\ProgramData\Seemless"
call :run copy /y "%S%\guest\SeemlessLauncher.ps1" "%W%\ProgramData\Seemless\SeemlessLauncher.ps1" || goto :eof
call :run copy /y "%S%\guest\register-launcher.ps1" "%W%\ProgramData\Seemless\register-launcher.ps1" || goto :eof
call :run copy /y "%S%\guest\setup-account.ps1" "%W%\ProgramData\Seemless\setup-account.ps1" || goto :eof
rem Experimental WacOS shell (docs/03 "Optional: WacOS"): only on payloads
rem of VMs set up with it. firstboot.cmd registers its logon task.
if exist "%S%\wacos\install-wacos.ps1" (
  call :run xcopy "%S%\wacos" "%W%\ProgramData\Seemless\wacos" /e /i /h /y || goto :eof
)

rem ---------------------------------------------------------------- boot
set "STAGE=bootloader"
call :run bcdboot %W%\Windows /s S: /f UEFI || goto :eof
if "%SL_TESTSIGNING%"=="1" (
  call :run bcdedit /store S:\EFI\Microsoft\Boot\BCD /set {default} testsigning on || goto :eof
)

if exist "%SCRATCH%" rd /s /q "%SCRATCH%"

set "STAGE=done"
call :log "apply finished with !WARNINGS! warning(s); rebooting into Windows"
echo APPLIED> "%R%\status.txt"
wpeutil reboot
goto :eof

rem ==========================================================================
:run
rem Run a command, log it and its output; on failure record it and power off.
>> "%LOG%" echo [%TIME%] [%STAGE%] ^> %*
%* >> "%LOG%" 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  call :fail "%STAGE%: exit %RC%: %*"
  exit /b 1
)
exit /b 0

:try
rem Like :run, but a failure is logged as a warning and the install goes on.
rem Recipe entries use it: an entry missing from a given build must not stop
rem the install (image/recipes/README.md). 3010 = success, restart pending.
>> "%LOG%" echo [%TIME%] [%STAGE%] ^> %*
%* >> "%LOG%" 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" if not "%RC%"=="3010" (
  >> "%LOG%" echo [%TIME%] [%STAGE%] WARNING exit %RC%, continuing
  set /a WARNINGS+=1
)
exit /b 0

:log
>> "%LOG%" echo [%TIME%] [%STAGE%] %~1
exit /b 0

:fail
>> "%LOG%" echo [%TIME%] [%STAGE%] ERROR %~1
> "%R%\status.txt" echo ERROR %STAGE% %~1
wpeutil shutdown
exit /b 1
