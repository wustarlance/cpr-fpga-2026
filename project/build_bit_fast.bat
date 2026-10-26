@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

rem =============================================================
rem  精简版出 bit：默认只构建 top（不再两个顶层都跑），走 build_fast.tcl
rem
rem  用法：
rem     build_bit_fast.bat              只构建 top（约 4 分钟）
rem     build_bit_fast.bat top_adc      只构建 top_adc（约 4 分 50 秒）
rem     build_bit_fast.bat both         两个都跑（约 9 分钟，旧行为）
rem
rem  可选环境变量：
rem     TD_HOME       TD 安装目录，默认 D:\ANLU\TD_6.2.1
rem     CPR_REPORT    设 1 则额外生成 qor / timing_summary 等完整报告
rem     CPR_FORCE     设 1 则跳过"残留 TD 进程"检查（不推荐）
rem     CPR_NO_PAUSE  设 1 则结束时不停顿
rem
rem  与 build.tcl 的区别：不生成 export_db（gate.db 11 MB + route.db 15 MB）、
rem  report_qor ×3、report_area ×2、timing_summary/check/clock/exception。
rem  时序守卫（SWNS/STNS/HWNS/HTNS 任一为负就不出 bit）完整保留。
rem  产物：build\<顶层>\<顶层>.bit     日志：build_<顶层>.log
rem =============================================================

if not defined TD_HOME set "TD_HOME=D:\ANLU\TD_6.2.1"
set "TD_BIN=%TD_HOME%\bin\td_commands_prompt.exe"
set "TCL=build_fast.tcl"

if not exist "%TD_BIN%" (
    echo [X] 找不到 TD 命令行工具：%TD_BIN%
    echo     用  set TD_HOME=你的TD安装目录  后再运行。
    goto :fail
)
if not exist "%TCL%" (
    echo [X] 找不到 %TCL%：%CD%
    goto :fail
)
if not exist "project.al" (
    echo [X] 当前目录下没有 project.al：%CD%
    goto :fail
)

rem ---------- 残留 TD 进程会让日志和 build 目录被占用，必须挡在启动前 ----------
if /i "%CPR_FORCE%"=="1" goto :skip_busy_check
tasklist /fi "IMAGENAME eq td_commands_prompt.exe" /nh 2>nul | find /i "td_commands_prompt" >nul
if not errorlevel 1 goto :busy
:skip_busy_check

set "TARGETS=%~1"
if "%TARGETS%"=="" set "TARGETS=top"
if /i "%TARGETS%"=="both" set "TARGETS=top top_adc"

rem 位流是否已包含当前 RTL：只做提示，不拦人
echo.
echo 音频扇区表（rtl\audio\wav_track_select.v）：
findstr /C:"PICTURE_" "rtl\audio\wav_track_select.v" | findstr /C:"32'd"
echo.
for /f "delims=" %%F in ('dir /b /s /a-d /o-d rtl 2^>nul') do (
    echo RTL 最新改动：%%~tF  %%~nxF
    goto :rtl_shown
)
:rtl_shown
for %%F in ("build\top\top.bit" "build\top_adc\top_adc.bit") do if exist "%%~fF" echo 现有位流：%%~tF  %%~nxF
echo     位流时间晚于 RTL 改动 = 现有 bit 已包含全部改动，可以直接烧，不必重建。
echo.

rem ---------- 位流已包含最新 RTL 就不重建：整轮 P&R 约 5 分钟，慢的时候 20 分钟 ----------
rem   scripts\bit_uptodate.ps1 退出码：0=不必建 1=必须建 2=判定失败（按必须建处理）
rem   CPR_FORCE=1 可强制重建
set "UPCHK=1"
if /i "%CPR_FORCE%"=="1" set "UPCHK=0"
if "%UPCHK%"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\bit_uptodate.ps1" %TARGETS%
    if errorlevel 1 set "UPCHK=0"
)
if "%UPCHK%"=="1" (
    echo [i] 位流已是最新，本次不重建。确实要重建：set CPR_FORCE=1 后再跑一次。
    echo     位流位置见上方的位流列表。
    if /i not "%CPR_NO_PAUSE%"=="1" pause
    exit /b 0
)

copy /y "project.al" "project.al.cprbak" >nul

set "FAILED="
for %%T in (%TARGETS%) do call :build_one %%T

fc /b "project.al" "project.al.cprbak" >nul 2>nul
if errorlevel 1 (
    copy /y "project.al.cprbak" "project.al" >nul
    echo [i] project.al 被 TD 改写，已还原为构建前的版本。
)
del /q "project.al.cprbak" >nul 2>nul

echo.
if defined FAILED (
    echo ============ 有顶层构建失败，别用这次的 bit ============
    goto :fail
)
echo ============ 全部通过 ============
if /i not "%CPR_NO_PAUSE%"=="1" pause
exit /b 0

rem -------------------------------------------------------------
:build_one
setlocal
set "T=%~1"
if /i not "%T%"=="top" if /i not "%T%"=="top_adc" (
    echo [X] 未知顶层 "%T%"，只能 top / top_adc / both。
    endlocal & set "FAILED=1"
    exit /b 1
)

set "LOG=build_%T%.log"
set "BIT=build\%T%\%T%.bit"
set "TS=build\%T%\timing_status.rpt"
set "LOGTMP=.build_%T%_%RANDOM%%RANDOM%.tmp.log"
del /q "%LOGTMP%" >nul 2>nul

echo.
echo ============================================================
echo  构建 %T%（精简流程）      %DATE% %TIME%
echo ============================================================

if exist "%BIT%" (
    if exist "%BIT%.prev" del /q "%BIT%.prev" >nul 2>nul
    move /y "%BIT%" "%BIT%.prev" >nul
    echo   旧位流已备份：build\%T%\%T%.bit.prev
)

set "CPR_TOP=%T%"
set "CPR_STAGE=full"
"%TD_BIN%" "%TCL%" > "%LOGTMP%" 2>&1
set "RC=%ERRORLEVEL%"

copy /y "%LOGTMP%" "%LOG%" >nul 2>nul
if errorlevel 1 (
    echo [i] 无法写入 %LOG%（可能被占用），完整日志在：%CD%\%LOGTMP%
    set "LOG=%LOGTMP%"
) else (
    del /q "%LOGTMP%" >nul 2>nul
)

if "%RC%"=="-1073741510" (
    echo [X] %T% 被 Ctrl+C 中断，本次没有生成位流。
    echo     日志末尾：%CD%\%LOG%
    endlocal & set "FAILED=1"
    exit /b 1
)
if not "%RC%"=="0" (
    echo [X] %T% 构建失败（退出码 %RC%）
    findstr /C:"CPR_BUILD_FAIL" "%LOG%"
    findstr /C:"ERROR" "%LOG%"
    echo     完整日志：%CD%\%LOG%
    endlocal & set "FAILED=1"
    exit /b 1
)
findstr /C:"CPR_BUILD_PASS" "%LOG%" >nul
if errorlevel 1 (
    echo [!] 日志里没有 CPR_BUILD_PASS，检查 %CD%\%LOG%
    endlocal & set "FAILED=1"
    exit /b 1
)

findstr /C:"CPR_BUILD_PASS" "%LOG%"
if exist "%TS%" (
    echo   时序：
    type "%TS%"
)
if exist "%BIT%" (
    for %%F in ("%BIT%") do echo   位流：%%~fF   %%~zF 字节   %%~tF
    echo   日志：%CD%\%LOG%
    endlocal
    exit /b 0
)
echo [!] 构建报告通过，但没找到位流：%BIT%
endlocal & set "FAILED=1"
exit /b 1

rem -------------------------------------------------------------
:busy
echo.
echo [X] 检测到还有 td_commands_prompt.exe 在运行：
tasklist /fi "IMAGENAME eq td_commands_prompt.exe" /nh
echo.
echo     它会锁住日志和 build 目录，导致本次构建失败。
echo     等它结束（或关掉那个窗口）再重新运行本脚本。
echo.
goto :fail

rem -------------------------------------------------------------
:fail
if /i not "%CPR_NO_PAUSE%"=="1" pause
exit /b 1
