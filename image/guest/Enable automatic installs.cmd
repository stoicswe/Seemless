@echo off
rem For VMs installed before "Open in Seemless" existed: registers the
rem launcher so later installers start by themselves. Asks for elevation.
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0register-launcher.ps1" -Source "%~dp0."
if errorlevel 1 (echo Could not register the launcher. & pause & exit /b 1)
schtasks /run /tn "\Seemless\Launcher" >nul 2>&1
echo Seemless launcher registered. Installers you open in Seemless will now start by themselves.
pause
