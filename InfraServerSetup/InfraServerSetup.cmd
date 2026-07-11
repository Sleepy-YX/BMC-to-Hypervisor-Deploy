@echo off
rem InfraServerSetup launcher - double-click to start the dashboard.
rem Any arguments are passed through, e.g.:
rem   InfraServerSetup.cmd -DeployRepo .\sample -Port 8475
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-InfraServerSetup.ps1" %*
pause
