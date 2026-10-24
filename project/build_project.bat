@echo off
REM ============================================================================
REM  build_project.bat -- build project.al (top module "top") -> bitstream
REM
REM  Just double-click this file. It MUST stay in the project root directory,
REM  because relative paths inside project.al are resolved against the process
REM  current working directory. %~dp0 is exactly the project root.
REM
REM  Optional stage argument (default: bit):
REM    build_project.bat gate     synthesis only, fast resource/timing check
REM    build_project.bat place    synthesis + place
REM    build_project.bat route    synthesis + place + route + final timing
REM    build_project.bat bit      full flow, generates top.bit
REM
REM  Output: build_project\top.bit
REM ============================================================================
setlocal enabledelayedexpansion

set TD_BIN=D:\ANLU\TD_6.2.1\bin\td_commands_prompt.exe
set STAGE=%~1
if "%STAGE%"=="" set STAGE=bit

REM Switch to the directory of this bat (= project root). Critical step.
cd /d "%~dp0"

echo ============================================================
echo  PROJECT : %CD%
echo  STAGE   : %STAGE%
echo  TD      : %TD_BIN%
echo ============================================================
echo.

if not exist "%TD_BIN%" (
    echo [FAIL] TD command line tool not found: %TD_BIN%
    echo        Check the installation path or edit TD_BIN in this file.
    if not defined BV_NO_PAUSE pause
    exit /b 1
)
if not exist "project.al" (
    echo [FAIL] project.al not found. Put this bat in the project root.
    if not defined BV_NO_PAUSE pause
    exit /b 1
)

set BP_STAGE=%STAGE%
REM Use forward slashes: TD's Tcl accepts them, and they survive being launched
REM from Git Bash where backslashes get eaten as escape sequences.
set BITFILE=build_project/top.bit
set BITTIME=
if exist "%BITFILE%" for %%F in ("%BITFILE%") do set BITTIME=%%~tF

"%TD_BIN%" "scripts/build_project.tcl"
set RC=%errorlevel%

echo.
echo ============================================================
if /i not "%STAGE%"=="bit" (
    echo  DONE stage=%STAGE%  ^(no bitstream for this stage^)
) else (
    if exist "%BITFILE%" (
        echo  BITSTREAM : %CD%\%BITFILE%
        call :showbit "%BITFILE%"
        set AFTER=
        for %%F in ("%BITFILE%") do set AFTER=%%~tF
        if "!BITTIME!"=="!AFTER!" echo  [WARN] top.bit NOT regenerated ^(stale copy above^)
    ) else (
        echo  [WARN] top.bit not found, check the log above.
    )
)
echo ============================================================
echo.
echo If timing is violated, inspect:
echo   build_project/route_timing_status.rpt
echo.

REM Double-click keeps the window open; set BV_NO_PAUSE=1 to skip in scripts.
if not defined BV_NO_PAUSE pause
exit /b %RC%

:showbit
for %%F in (%1) do (
    echo  SIZE      : %%~zF bytes
    echo  TIME      : %%~tF
)
goto :eof
