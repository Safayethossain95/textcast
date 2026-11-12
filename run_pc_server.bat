@echo off
title TextCast Clipboard Sync Server
cd /d "%~dp0pc_server\dist"
if exist "clipboard_server.exe" (
    echo Starting TextCast Server...
    start "" "clipboard_server.exe"
    echo TextCast is running in the background in your system tray (notification area).
    echo You can close this window.
) else (
    echo Compiled EXE not found, falling back to python script...
    cd /d "%~dp0pc_server"
    python clipboard_server.py --show
)
timeout /t 3 >nul
