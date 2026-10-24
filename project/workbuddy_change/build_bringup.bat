@echo off
REM ============================================================================
REM build_bringup.bat —— 双击生成 bring-up 位流（数码管 + 蜂鸣器，不依赖加密 IP）
REM 产物：build_bringup\audio_board_bringup_top.bit / .bin
REM ============================================================================
setlocal
set TD_BIN=D:\ANLU\TD_6.2.1\bin\td_commands_prompt.exe
cd /d "%~dp0"

set AB_PROJ=bringup
set AB_STAGE=full

echo ---- 开始综合/布局/布线/bitgen ----
"%TD_BIN%" scripts\build_board.tcl
if errorlevel 1 (
    echo.
    echo [FAIL] 见上面的 AUDIO_BOARD_FAIL 行
    pause
    exit /b 1
)

echo.
echo ---- 时序 ----
type build_bringup\route_timing_status.rpt
echo.
echo ---- 产物 ----
dir /b build_bringup\*.bit build_bringup\*.bin
echo.
echo 下载：TD 打开 audio_bringup.al -^> Tools -^> Download
pause
