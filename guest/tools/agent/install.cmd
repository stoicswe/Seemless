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
  rem Give the service and its session agent a moment to exit.
  ping -n 3 127.0.0.1 >nul
)

if /i not "%SRC%"=="%DST%\" (
  if not exist "%DST%" mkdir "%DST%"
  for %%f in (seemless-agent-svc.exe seemless-agent.exe version.txt install.cmd uninstall.cmd) do (
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
exit /b 0
