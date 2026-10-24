@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" -ParallelBuilds 3
exit /b %ERRORLEVEL%