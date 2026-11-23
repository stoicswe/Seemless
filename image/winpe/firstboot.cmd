@echo off
rem ==========================================================================
rem Seemless first boot (docs/03 stage 6). Runs as SYSTEM from SetupComplete.cmd.
rem
rem Records success on the payload disk, removes the answer file (it holds
rem the encoded account password) and shuts down, so the host knows the
rem install has finished. Later stages (runtimes, agent service, seal) are
rem added here as they are built.
rem
rem UNTESTED until spike S4.
rem ==========================================================================
setlocal EnableExtensions
set "P="
for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
  if not defined P if exist "%%d:\seemless\SEEMLESS.MARK" set "P=%%d:"
)

del /f /q "%WINDIR%\Panther\unattend.xml" 2>nul
del /f /q "%WINDIR%\Panther\unattend-original.xml" 2>nul

if defined P (
  set "R=%P%\seemless\result"
  ver > "%P%\seemless\result\firstboot.txt"
  echo %DATE% %TIME% >> "%P%\seemless\result\firstboot.txt"
  copy /y "%WINDIR%\Setup\Scripts\firstboot.log" "%P%\seemless\result\" >nul 2>&1
  copy /y "%WINDIR%\Panther\setupact.log" "%P%\seemless\result\" >nul 2>&1
  echo FIRSTBOOT_OK> "%P%\seemless\result\status.txt"
)

shutdown /s /t 5 /c "Seemless: first boot finished"
