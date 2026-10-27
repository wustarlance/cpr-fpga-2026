@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

rem =============================================================
rem  一键生成 bit 流（TD 6.2.1 命令行脚本流程）
rem
rem  用法：
rem     build_bit.bat              依次构建 top、top_adc（默认）
rem     build_bit.bat top          只构建 top
rem     build_bit.bat top_adc      只构建 top_adc
rem
rem  可选环境变量：
rem     TD_HOME       TD 安装目录，默认 D:\ANLU\TD_6.2.1
rem     CPR_FORCE     设 1 则跳过"残留 TD 进程"检查（不推荐）
rem     CPR_NO_PAUSE  设 1 则结束时不停顿
rem
rem  流程：elaborate -> gate -> legalize -> place -> route ->
rem        update_timing -> 时序守卫 -> bitgen（都在 build.tcl 里）。
rem        不要走 GUI 的 DefaultFlow：那条路的 drHoldFix 会往加密核内部的
rem        复位网插 hold buffer，落点不可布线，phy_1 必失败（PHY-8023）。
rem
rem  产物：build\<顶层>\<顶层>.bit
rem        构建前旧位流备份为 <顶层>.bit.prev（构建失败时还能回去用）
rem  日志：build_<顶层>.log（完整 TD 输出）
rem =============================================================

if not defined TD_HOME set "TD_HOME=D:\ANLU\TD_6.2.1"
set "TD_BIN=%TD_HOME%\bin\td_commands_prompt.exe"

if not exist "%TD_BIN%" (
    echo [X] 找不到 TD 命令行工具：%TD_BIN%
    echo     用  set TD_HOME=你的TD安装目录  后再运行。
    goto :fail
)
if not exist "project.al" (
    echo [X] 当前目录下没有 project.al：%CD%
    goto :fail
)
if not exist "build.tcl" (
    echo [X] 当前目录下没有 build.tcl：%CD%
    goto :fail
)

rem ---------- 检查是否有上次残留的 TD 进程 ----------
rem 残留会锁住 build_<顶层>.log 与 build\<顶层>\ 里的文件，
rem 表现为 "The process cannot access the file because it is being used by another process."
rem 然后 TD 根本没启动。必须挡在启动之前。
if /i "%CPR_FORCE%"=="1" goto :skip_busy_check
tasklist /fi "IMAGENAME eq td_commands_prompt.exe" /nh 2>nul | find /i "td_commands_prompt" >nul
if not errorlevel 1 goto :busy
:skip_busy_check

set "TARGETS=%~1"
if "%TARGETS%"=="" set "TARGETS=top top_adc"

echo.
echo 音频扇区表（rtl\audio\wav_track_select.v）：
findstr /C:"PICTURE_" "rtl\audio\wav_track_select.v" | findstr /C:"32'd"

rem TD 打开工程时会写回运行态字段，先备份，结束时还原
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
    echo              旧位流备份在 build\^<顶层^>\^<顶层^>.bit.prev
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
    echo [X] 未知顶层 "%T%"，只能 top 或 top_adc。
    endlocal & set "FAILED=1"
    exit /b 1
)

set "LOG=build_%T%.log"
set "BIT=build\%T%\%T%.bit"
set "TS=build\%T%\timing_status.rpt"

rem 日志先写到本次运行独有的临时文件，跑完再改名成 build_<顶层>.log。
rem 这样即使有进程残留占着旧的 build_<顶层>.log，本次也不会写不进去。
set "LOGTMP=.build_%T%_%RANDOM%%RANDOM%.tmp.log"
del /q "%LOGTMP%" >nul 2>nul

echo.
echo ============================================================
echo  构建 %T%      %DATE% %TIME%
echo ============================================================

rem 旧位流挪成 .prev：保证最后报出来的 bit 一定是这次生成的，
rem 而不是上次留下的旧文件（那种"假通过"最坑）
if exist "%BIT%" (
    if exist "%BIT%.prev" del /q "%BIT%.prev" >nul 2>nul
    move /y "%BIT%" "%BIT%.prev" >nul
    echo   旧位流已备份：build\%T%\%T%.bit.prev
)

set "CPR_TOP=%T%"
set "CPR_STAGE=full"
"%TD_BIN%" "build.tcl" > "%LOGTMP%" 2>&1
set "RC=%ERRORLEVEL%"

rem 收编日志（旧文件若被占，保留临时文件并告知）
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
echo     旧位流仍在 %BIT%.prev
endlocal & set "FAILED=1"
exit /b 1

rem -------------------------------------------------------------
:busy
echo.
echo [X] 检测到还有 td_commands_prompt.exe 在运行：
tasklist /fi "IMAGENAME eq td_commands_prompt.exe" /nh
echo.
echo     它会锁住日志和 build 目录，导致本次构建直接失败
echo     （报 "The process cannot access the file..."）。
echo.
echo     处理：把上次那个黑窗口按 Ctrl+C 结束掉，或直接关掉那个窗口，
echo     等 tasklist 里看不到 td_commands_prompt.exe 再重新运行本脚本。
echo     确实要强来：set CPR_FORCE=1 后再运行（不建议）。
echo.
echo [i] 注意：现在 build 目录里的位流是上一次成功构建的，本身可用，
echo     时间早于任何 RTL 改动就不用急着重建。
goto :fail

rem -------------------------------------------------------------
:fail
if /i not "%CPR_NO_PAUSE%"=="1" pause
exit /b 1
