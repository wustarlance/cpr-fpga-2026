@echo off
REM ============================================================================
REM  lint.bat -- Windows 版全工程 Verilator 静态检查（不综合、不出位流）
REM
REM  为什么需要它：
REM    VS Code 的 Verilog 扩展是「verilator --lint-only 当前文件」，只看一个
REM    文件、看不到别处的 module 定义，于是 sd_card_bmp / sd_card_top / HDMI
REM    加密核这些定义在别的目录的模块全被判"未定义"，满屏红线。
REM    本脚本喂给 Verilator 完整文件列表 project\filelist.f，跨文件端口/位宽
REM    连接是真的会检查的。
REM
REM  用法：
REM      lint.bat                 默认：顶层 top，压制纯风格噪声
REM      lint.bat top_adc         检查 ADC 版
REM      lint.bat top strict      不压制任何告警（首次审计用）
REM      lint.bat top widths      只看位宽类告警
REM
REM  前置：Windows 上 Verilator 建议用 oss-cad-suite 自带的那份（含 MinGW
REM        预处理环境）。装好后把 bin 目录加进 PATH，或者：
REM            set VERILATOR=D:\oss-cad-suite\bin\verilator.exe
REM        如果 Verilator 报预处理/preprocessor 相关错误，就在 oss-cad-suite
REM        自己的终端里跑本脚本，或改用 WSL 跑 project/scripts/lint.sh。
REM
REM  退出码：0 = 无错误；1 = 有 Error 或 Verilator 没跑起来
REM ============================================================================
setlocal enabledelayedexpansion

set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "PROJECT=%%~fI"
set "FILELIST=%PROJECT%\filelist.f"

set "TOP=%~1"
if "%TOP%"=="" set "TOP=top"
set "MODE=%~2"
if "%MODE%"=="" set "MODE=default"

if /i not "%TOP%"=="top" if /i not "%TOP%"=="top_adc" (
    echo [FAIL] 顶层只能是 top 或 top_adc，收到: %TOP%
    if not defined BV_NO_PAUSE pause
    exit /b 1
)

if not exist "%FILELIST%" (
    echo [FAIL] 缺少 %FILELIST%
    if not defined BV_NO_PAUSE pause
    exit /b 1
)

REM ---- filelist.f 新鲜度：由 project.al 生成，不同步会"检查旧清单还说通过" ----
set "PY="
where python >nul 2>&1 && set "PY=python"
if not defined PY where python3 >nul 2>&1 && set "PY=python3"
if defined PY (
    %PY% "%PROJECT%\scripts\gen_filelist.py" --check
) else (
    echo （没找到 python，跳过 filelist.f 新鲜度检查）
)

REM ---- 找 verilator ----
set "VLT="
if defined VERILATOR if exist "%VERILATOR%" set "VLT=%VERILATOR%"
if not defined VLT for /f "delims=" %%P in ('where verilator 2^>nul') do if not defined VLT set "VLT=%%P"
if not defined VLT for %%P in (
        "D:\oss-cad-suite\bin\verilator.exe"
        "%USERPROFILE%\oss-cad-suite\bin\verilator.exe"
        "C:\oss-cad-suite\bin\verilator.exe"
    ) do if not defined VLT if exist %%P set "VLT=%%~P"
if not defined VLT (
    echo [FAIL] 找不到 verilator.exe
    echo        装 oss-cad-suite 的 Windows 版，把 bin 目录加进 PATH，
    echo        或先 set VERILATOR=...\verilator.exe 再运行本脚本。
    if not defined BV_NO_PAUSE pause
    exit /b 1
)

REM ---- 参数 ----
set "EXTRA=-Wno-EOFNEWLINE -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-GENUNNAMED -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY"
if /i "%MODE%"=="strict" set "EXTRA="
if /i "%MODE%"=="widths" set "EXTRA=%EXTRA%"

echo ============================================================
echo  Verilator : %VLT%
echo  顶层      : %TOP%
echo  模式      : %MODE%
echo  文件列表  : %FILELIST%
echo ============================================================
echo.

cd /d "%PROJECT%"
"%VLT%" --lint-only -Wall -Wno-fatal -Wno-MODMISSING --top-module %TOP% ^
    %EXTRA% -f "%FILELIST%" > "%TEMP%\cpr_lint.txt" 2>&1
set "RC=%ERRORLEVEL%"

type "%TEMP%\cpr_lint.txt"

echo.
echo -------------------- 汇总 --------------------
findstr /C:"%Error" "%TEMP%\cpr_lint.txt" >nul
if errorlevel 1 (
    echo 错误   : 0
) else (
    echo 错误   : 有（见上面的 %%Error 行）
)

echo.
if not "%RC%"=="0" (
    echo 结论：有错误，必须修。
    del "%TEMP%\cpr_lint.txt" >nul 2>&1
    if not defined BV_NO_PAUSE pause
    exit /b 1
)
echo 结论：无错误。把第 2 个参数换成 strict 看全部告警，widths 专看位宽类。
del "%TEMP%\cpr_lint.txt" >nul 2>&1
if not defined BV_NO_PAUSE pause
exit /b 0
