@echo off
rem ==========================================================================
rem Seemless guest tools: install or update everything on this volume
rem (docs/06 "Guest tools ISO"). Run as an administrator or SYSTEM.
rem
rem   install.cmd            install / reinstall (double-click from the CD)
rem   install.cmd /update    started by the agent service for UpdateTools:
rem                          waits a moment so the service's reply reaches
rem                          the Mac before the service is stopped
rem
rem agent\install.cmd swaps the agent in place and restarts its service.
rem drivers\ (when present) goes through pnputil; a driver that needs a
rem reboot is reported in the log, never forced (exit code 3010).
rem ==========================================================================
setlocal EnableExtensions
set "ROOT=%~dp0"
echo ==== %DATE% %TIME% Seemless tools from %ROOT%
if exist "%ROOT%version.txt" type "%ROOT%version.txt"
if /i "%~1"=="/update" ping -n 3 127.0.0.1 >nul

set "RC=0"
if exist "%ROOT%drivers\" (
  pnputil /add-driver "%ROOT%drivers\*.inf" /subdirs /install
  if errorlevel 3010 (echo drivers: a reboot is needed to finish) else if errorlevel 1 (echo drivers: pnputil failed & set "RC=1")
)
call "%ROOT%agent\install.cmd" || (echo agent: install failed & exit /b 1)
echo ==== done (%RC%)
exit /b %RC%
