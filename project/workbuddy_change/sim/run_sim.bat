@echo off
rem ===========================================================================
rem run_sim.bat —— ModelSim 侧的两项检查
rem   1) lint：编译 TD 用的同一份 13 文件 + elaborate audio_tmg_top
rem   2) wave：wave_painter 逐列回归（16 帧，含静音段）
rem 用法：双击，或 run_sim.bat [lint^|wave^|all]
rem ===========================================================================
setlocal
cd /d "%~dp0.."

set MODE=%1
if "%MODE%"=="" set MODE=all

set MS_BIN=D:\Program Files\Mentor Graphics ModelSim SE-64 10.6e\win64
set MGLS_LICENSE_FILE=D:\Program Files\Mentor Graphics ModelSim SE-64 10.6e\win64\LICENSE.TXT
set LM_LICENSE_FILE=%MGLS_LICENSE_FILE%
set PATH=%MS_BIN%;%PATH%

if not exist "%MS_BIN%\vsim.exe" (
    echo [ERROR] 找不到 ModelSim：%MS_BIN%
    pause
    exit /b 1
)

cd sim

if /i "%MODE%"=="all"   goto :lint
if /i "%MODE%"=="lint"  goto :lint
if /i "%MODE%"=="wave"  goto :wave
echo 用法: run_sim.bat [lint^|wave^|all]
pause
exit /b 1

:lint
echo ============================================================
echo  [1/2] lint：13 文件编译 + elaborate
echo ============================================================
vsim -c -l lint_log.txt -do "do lint.do; quit -f"
findstr /C:"LINT_ELAB_PASS" /C:"Errors:" lint_log.txt
if /i "%MODE%"=="lint" goto :end

:wave
echo.
echo ============================================================
echo  [2/2] wave_painter 逐列回归
echo ============================================================
vsim -c -l wave_log.txt -do "do run_wave.do; quit -f"
findstr /C:"受检" /C:"PASS" /C:"FAIL" /C:"Errors:" wave_log.txt

:end
cd ..
echo.
echo 日志：sim\lint_log.txt / sim\wave_log.txt
pause
