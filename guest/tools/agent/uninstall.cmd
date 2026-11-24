@echo off
rem Removes the Seemless guest agent service (docs/06). Run as an administrator.
rem Leaves %ProgramFiles%\Seemless and the logs in place.
setlocal
sc stop SeemlessAgent >nul 2>&1
ping -n 3 127.0.0.1 >nul
sc delete SeemlessAgent
exit /b 0
