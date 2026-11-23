@echo off
rem Run by Windows as SYSTEM at the end of setup, before the first logon.
rem Hands over to firstboot.cmd so its output is logged.
call "%~dp0firstboot.cmd" > "%WINDIR%\Setup\Scripts\firstboot.log" 2>&1
