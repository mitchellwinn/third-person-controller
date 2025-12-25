@echo off
title Local Multiplayer Test
setlocal enabledelayedexpansion

:: ============================================
:: Starts 1 headless server + 2 clients for local testing
:: ============================================
set PROJECT_PATH=%~dp0
set PROJECT_PATH=%PROJECT_PATH:~0,-1%
set SERVER_PORT=7777

:: Auto-detect Godot executable
set GODOT_PATH=

:: 1. Check environment variable first (useful for CI/CD)
if defined GODOT_PATH_ENV (
    if exist "!GODOT_PATH_ENV!" (
        set GODOT_PATH=!GODOT_PATH_ENV!
        goto :godot_found
    )
)

:: 2. Check for godot.cfg file in project root (local config, gitignored)
if exist "%PROJECT_PATH%\godot.cfg" (
    for /f "usebackq tokens=*" %%i in ("%PROJECT_PATH%\godot.cfg") do (
        if exist "%%i" (
            set GODOT_PATH=%%i
            goto :godot_found
        )
    )
)

:: 3. Check array of developer paths - ADD YOUR PATH HERE!
set "GODOT_PATHS[0]=F:\personal\development\tools\godot\4.3\Godot_v4.3-stable_win64.exe"
set "GODOT_PATHS[1]=G:\tools\engines\godot\v4.3\Godot_v4.3-stable_win64.exe"
:: Add more paths below as needed:
:: set "GODOT_PATHS[2]=C:\Your\Path\To\Godot\Godot_v4.3-stable_win64.exe"
:: set "GODOT_PATHS[3]=D:\Another\Path\Godot_v4.3-stable_win64.exe"

:: Find first existing path in array
set MAX_INDEX=1
for /L %%i in (0,1,!MAX_INDEX!) do (
    call set "TEST_PATH=%%GODOT_PATHS[%%i]%%"
    if exist "!TEST_PATH!" (
        set GODOT_PATH=!TEST_PATH!
        goto :godot_found
    )
)

:: Godot not found
echo ERROR: Godot executable not found!
echo.
echo Please do one of the following:
echo   1. Add your Godot path to the GODOT_PATHS array in this script (around line 30)
echo   2. Set GODOT_PATH_ENV environment variable to your Godot executable
echo   3. Create a godot.cfg file in the project root with the path to Godot
echo.
pause
exit /b 1

:godot_found
echo Found Godot at: %GODOT_PATH%

echo ============================================
echo Starting Local Multiplayer Test
echo ============================================
echo This will launch:
echo   - 1 Headless Server
echo   - 2 Game Clients
echo ============================================
echo.

:: Start server in background
echo Starting server...
start "Server" /min "%GODOT_PATH%" --headless --path "%PROJECT_PATH%" --server --port %SERVER_PORT%

:: Wait for server to initialize
timeout /t 2 /nobreak > nul

:: Start clients (they will show title menu)
:: Windows will place them on your primary monitor
:: To force specific positions, add: --position X,Y (where X,Y are screen coordinates)
echo Starting client 1...
start "Client 1" "%GODOT_PATH%" --path "%PROJECT_PATH%" --resolution 800x600

timeout /t 1 /nobreak > nul

echo Starting client 2...
start "Client 2" "%GODOT_PATH%" --path "%PROJECT_PATH%" --resolution 800x600

echo.
echo All instances started!
echo Close this window to continue (servers/clients will keep running)
pause

