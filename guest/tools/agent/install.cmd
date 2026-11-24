@echo off
rem ==========================================================================
rem Installs (or reinstalls) the Seemless guest agent service (docs/06).
rem Run as an administrator or SYSTEM, from the folder that holds
rem seemless-agent-svc.exe and seemless-agent.exe. Idempotent.
rem
rem Files go to %ProgramFiles%\Seemless (copied unless already there). The
rem service "SeemlessAgent" runs as LocalSystem, starts automatically and is
rem restarted by the SCM if it dies. It starts the session agent itself.
rem Log: %ProgramData%\Seemless\logs\agent-svc.log
rem
rem In-place update (WP4.3): the running binaries are renamed to *.old
rem (Windows allows renaming a running .exe) and the new ones copied in, so
rem a session agent that has not exited yet cannot block the update. The
rem *.old files are removed on the next run.
rem ==========================================================================
setlocal EnableExtensions
set "SRC=%~dp0"
set "DST=%ProgramFiles%\Seemless"
set "SVC=SeemlessAgent"

if not exist "%SRC%seemless-agent-svc.exe" (
  echo install.cmd: seemless-agent-svc.exe not found next to this script
  exit /b 1
)

sc query %SVC% >nul 2>&1 && (
  sc stop %SVC% >nul 2>&1
  call :waitstopped
)

if /i not "%SRC%"=="%DST%\" (
  if not exist "%DST%" mkdir "%DST%"
  for %%f in (seemless-agent-svc.exe seemless-agent.exe) do (
    if exist "%SRC%%%f" call :replace %%f || exit /b 1
  )
  for %%f in (version.txt install.cmd uninstall.cmd) do (
    if exist "%SRC%%%f" copy /y "%SRC%%%f" "%DST%\%%f" >nul || (echo install.cmd: copy %%f failed & exit /b 1)
  )
)

sc query %SVC% >nul 2>&1 || (
  sc create %SVC% binPath= "\"%DST%\seemless-agent-svc.exe\"" start= auto obj= LocalSystem DisplayName= "Seemless Agent" || exit /b 1
)
sc config %SVC% binPath= "\"%DST%\seemless-agent-svc.exe\"" start= auto >nul
sc description %SVC% "Connects this Windows to Seemless on the Mac (virtio-serial) and starts the session agent." >nul
sc failure %SVC% reset= 86400 actions= restart/2000/restart/5000/restart/30000 >nul
sc start %SVC% >nul 2>&1
sc query %SVC% | findstr /i "STATE"
if exist "%DST%\version.txt" type "%DST%\version.txt"
exit /b 0

rem Up to 30 s for the service (and the session agent it ends) to stop.
:waitstopped
for /l %%i in (1,1,30) do (
  sc query %SVC% | findstr /i "STOPPED" >nul && exit /b 0
  ping -n 2 127.0.0.1 >nul
)
echo install.cmd: %SVC% did not stop within 30 s; replacing its files anyway
exit /b 0

rem Replaces %DST%\%1: rename the old file aside, copy the new one, and put
rem the old one back if the copy fails.
:replace
if exist "%DST%\%~1.old" del /f /q "%DST%\%~1.old" >nul 2>&1
if exist "%DST%\%~1" (
  move /y "%DST%\%~1" "%DST%\%~1.old" >nul || (echo install.cmd: cannot move %~1 aside & exit /b 1)
)
copy /y "%SRC%%~1" "%DST%\%~1" >nul && exit /b 0
echo install.cmd: copy %~1 failed
if exist "%DST%\%~1.old" move /y "%DST%\%~1.old" "%DST%\%~1" >nul
exit /b 1
