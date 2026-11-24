@echo off
rem ==========================================================================
rem Seemless first boot (docs/03 stage 6). Runs as SYSTEM from SetupComplete.cmd.
rem
rem Records success on the payload disk and shuts down, so the host knows the
rem install has finished. Later stages (runtimes, agent service, seal) are
rem added here as they are built.
rem
rem S4 (build 26300): this runs BEFORE OOBE. It must not delete
rem Panther\unattend.xml: OOBE still needs it for auto-logon. A SYSTEM task
rem registered by setup-account.ps1 deletes it at the first logon.
rem
rem The user account is created HERE (setup-account.ps1), not by OOBE: OOBE
rem on build 26300 ignored the answer file's Administrators group.
rem ==========================================================================
setlocal EnableExtensions
set "P="
for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
  if not defined P if exist "%%d:\seemless\SEEMLESS.MARK" set "P=%%d:"
)

rem The local administrator account. Without it the VM is unusable, so a
rem failure is reported as the build result instead of FIRSTBOOT_OK.
rem It reads the payload disk's answer file: Setup rewrites the passwords in
rem its cached Panther copy.
set "ACCOUNT_OK="
echo creating account
if not defined P (
  echo setup-account skipped: payload disk not found
) else (
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ProgramData%\Seemless\setup-account.ps1" -AnswerFile "%P%\seemless\unattend.xml"
  if errorlevel 1 (echo setup-account failed) else set "ACCOUNT_OK=1"
)

rem Fast Startup off (docs/spikes/S6b-hibernate-resume-crash.md). With it on,
rem every "shut down" (the ACPI power button that `vm stop` presses, Start >
rem Shut down) is a hibernate, and the next start is a resume. Resume crashed
rem Windows on HVF (bugcheck 0x1E reading ERRIDR_EL1, fixed by
rem patches/qemu/0002) and with viogpu3d it does not restore the display. A
rem resume also breaks after `vm set` changes CPUs, memory or devices. So
rem shutdown must be a real shutdown. Hibernation itself stays on (S6 uses it).
set "FASTSTARTUP_OK="
echo disabling fast startup
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f
if errorlevel 1 (echo fast startup: reg add failed) else set "FASTSTARTUP_OK=1"

rem "Open in Seemless" launcher (image/guest): logon task for every user.
echo registering launcher
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ProgramData%\Seemless\register-launcher.ps1" -Source "%ProgramData%\Seemless"
echo register-launcher exit %ERRORLEVEL%

if defined P (
  set "R=%P%\seemless\result"
  ver > "%P%\seemless\result\firstboot.txt"
  echo %DATE% %TIME% >> "%P%\seemless\result\firstboot.txt"
  copy /y "%WINDIR%\Setup\Scripts\firstboot.log" "%P%\seemless\result\" >nul 2>&1
  copy /y "%WINDIR%\Panther\setupact.log" "%P%\seemless\result\" >nul 2>&1
  if not defined ACCOUNT_OK (
    echo ERROR account setup-account.ps1 failed, see firstboot.log> "%P%\seemless\result\status.txt"
  ) else if not defined FASTSTARTUP_OK (
    echo ERROR faststartup HiberbootEnabled not set, see firstboot.log> "%P%\seemless\result\status.txt"
  ) else (
    echo FIRSTBOOT_OK> "%P%\seemless\result\status.txt"
  )
)

shutdown /s /t 5 /c "Seemless: first boot finished"
