@echo off
rem ===========================================================================
rem build.bat —— 一键跑音频链综合 / 布局 / 布线 / 时序
rem
rem 用法：双击，或在命令行里 build.bat [gate^|place^|route]
rem      默认 route（跑完布线，拿最终时序）
rem
rem 注意：必须在 workbuddy_change 目录下执行。TD 命令行对 .al 里的相对路径
rem       是按「进程 CWD」解析的，换个目录就会 "analyzed 0/13 files" +
rem       HIER-1013 找不到顶层。
rem ===========================================================================
setlocal
cd /d "%~dp0"

set STAGE=%1
if "%STAGE%"=="" set STAGE=route
set AT_STAGE=%STAGE%

set TD_BIN=D:\ANLU\TD_6.2.1\bin\td_commands_prompt.exe
if not exist "%TD_BIN%" (
    echo [ERROR] 找不到 TD：%TD_BIN%
    pause
    exit /b 1
)

echo ============================================================
echo  stage = %STAGE%
echo  cwd   = %CD%
echo ============================================================

"%TD_BIN%" scripts\flow.tcl > build_flow.log 2>&1

echo.
echo ---- 阶段检查 ----
findstr /C:"##########" /C:"FAIL" /C:"DONE" build_flow.log
echo.
echo ---- 结果 ----
if exist build\route_timing_status.rpt (
    type build\route_timing_status.rpt
) else if exist build\gate_timing_status.rpt (
    type build\gate_timing_status.rpt
)
echo 详细报告见 build\ ，完整日志见 build_flow.log
pause
