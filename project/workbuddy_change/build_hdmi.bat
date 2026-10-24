@echo off
REM ============================================================================
REM build_hdmi.bat —— 生成 HDMI 版位流（彩条 + HDMI 音频）
REM 前提：TD 必须是 6.2.1 SP1 (6.2.178840) 或更高，否则加密的 HDMI 核解析不了
REM       （现象：HDL-8007 unexpected non-printable character ... .enc.v）
REM 产物：build_board\audio_board_top.bit
REM ============================================================================
setlocal
set TD_BIN=D:\ANLU\TD_6.2.1\bin\td_commands_prompt.exe
cd /d "%~dp0"

set AB_PROJ=board
set AB_STAGE=full

"%TD_BIN%" scripts\build_board.tcl
if errorlevel 1 (
    echo.
    echo [FAIL] 若是 HDL-8007 / 加密核报错，说明当前 TD 版本不够，需要 SP1。
    pause
    exit /b 1
)

echo.
echo ---- 时序 ----
type build_board\route_timing_status.rpt
echo.
dir /b build_board\*.bit
pause
