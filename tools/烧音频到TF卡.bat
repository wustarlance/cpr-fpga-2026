@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion
cd /d "%~dp0.."
set PYTHONUTF8=1

rem ============================================================
rem  把 WAV 裸写进 TF 卡指定扇区（扇区由 RTL 决定，不手填）
rem
rem  双击即可：会自己申请管理员权限，然后列盘、选段、二次确认。
rem  想跳过"选文件"：在【已经提权的】cmd 里跑
rem      tools\烧音频到TF卡.bat "D:\某个.wav"
rem  （直接拖文件到图标上不行：提权会重启一份新进程，拖进来的参数会丢。）
rem
rem  对应脚本：tools\burn_wav.py
rem  为什么必须管理员：裸写 \\.\PhysicalDriveN 要提权，否则打不开设备。
rem ============================================================

rem ---- 提权：没有管理员就自己重启一份 ----
rem  用 fltmc 判断而不是 net session：后者依赖 Server 服务，服务停着时
rem  连管理员也会被判成"没权限"，于是会无限重启自己。
rem  文件名带中文没关系：cmd 传给子进程的命令行是 Unicode，不走代码页。
fltmc >nul 2>nul
if errorlevel 1 (
    echo 需要管理员权限，正在重新启动...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" 2>nul
    if errorlevel 1 (
        echo [X] 提权失败（可能点了"否"）。请右键本文件，选"以管理员身份运行"。
        pause
    )
    exit /b
)

rem ---- 找一个能用的 Python ----
set "PY="
py -3 -c "import sys" >nul 2>nul && set "PY=py -3"
if not defined PY (
    python -c "import sys" >nul 2>nul && set "PY=python"
)
if not defined PY (
    if exist "C:\Users\miao\.workbuddy\binaries\python\versions\3.13.12\python.exe" set "PY=C:\Users\miao\.workbuddy\binaries\python\versions\3.13.12\python.exe"
)
if not defined PY (
    if exist "D:\code\python\python.exe" set "PY=D:\code\python\python.exe"
)
if not defined PY (
    echo [X] 没找到 Python 3。装一个，或把 python.exe 的完整路径加进上面的判断。
    pause
    exit /b 1
)

echo ============================================================
echo   写音频到 TF 卡的裸扇区
echo ============================================================
echo   脚本：tools\burn_wav.py
echo   Python：%PY%
echo.

rem ---- 列盘（只读，用来找盘号）----
%PY% "tools\burn_wav.py" --list
if errorlevel 1 (
    echo [X] 列盘失败，看上面的报错。
    pause
    exit /b 1
)
echo.

rem ==================== 1. 选盘 ====================
set "DISK="
set /p "DISK=物理盘号（上面第一列，例如 1）："
set "DISK=%DISK: =%"
if not defined DISK goto :badisk
set "BAD="
for /f "delims=0123456789" %%a in ("%DISK%") do set "BAD=1"
if defined BAD goto :badisk

rem ==================== 2. 选文件 ====================
set "FILE=%~1"
if not defined FILE call :pick_file
if not defined FILE (
    echo.
    echo [X] 没拿到文件，退出。
    pause
    exit /b 1
)
set "FILE=%FILE:"=%"
if not exist "!FILE!" (
    echo.
    echo [X] 文件不存在：!FILE!
    pause
    exit /b 1
)
rem 本脚本只吃 WAV（产品侧也只认 PCM WAV），mp3 请先转码
if /i "!FILE:~-4!"==".mp3" (
    echo.
    echo [X] 这是 MP3，本脚本只吃 WAV。先转码：
    echo     ffmpeg -i 输入.mp3 -ar 48000 -ac 2 -c:a pcm_s16le 输出.wav
    pause
    exit /b 1
)

rem ==================== 3. 选段 ====================
echo.
echo 写到哪一段（这些数字来自 rtl\audio\wav_track_select.v，不用记）：
echo     [1] 12000     PICTURE_1  第 1 页
echo     [2] 123000    PICTURE_2  第 2 页
echo     [3] 250000    PICTURE_3  第 3 页
echo     [4] 370000    PICTURE_4  第 4 页
echo     [5] 500000    FREE_SONG  自动展播共用
echo.
set "SLOT="
set /p "SLOT=输入 1~5，或直接输入 LBA 数字："
set "SLOT=%SLOT: =%"
if not defined SLOT goto :badslot
set "BAD="
for /f "delims=0123456789" %%a in ("%SLOT%") do set "BAD=1"
if defined BAD goto :badslot

set "TRACK="
set "RAWLBA="
if "%SLOT%"=="1" set "TRACK=1"
if "%SLOT%"=="2" set "TRACK=2"
if "%SLOT%"=="3" set "TRACK=3"
if "%SLOT%"=="4" set "TRACK=4"
if "%SLOT%"=="5" set "TRACK=5"
if defined TRACK goto :slotok
rem 不是 1~5 就当成裸 LBA
set /a "LBA_N=%SLOT%" >nul 2>nul
if not defined LBA_N goto :badslot
if %LBA_N% LSS 2048 (
    echo.
    echo [X] %SLOT% 太小：0~2047 是分区表和文件系统引导区，写进去这张卡就废了。
    pause
    exit /b 1
)
set "RAWLBA=%SLOT%"
echo   提示：%RAWLBA% 不在五段之内，RTL 里没有指向它的参数，板子不会去这里读。
:slotok

echo.
echo ------------------------------------------------------------
echo   盘号 !DISK! / 文件 !FILE!
if defined TRACK  echo   目标：第 %TRACK% 段（--track %TRACK%，扇区由 RTL 给）
if defined RAWLBA echo   目标：裸扇区 LBA %RAWLBA%（--sector，不校验 RTL）
echo ------------------------------------------------------------
echo.

rem ==================== 4. 预检（不写盘）====================
set "ARGS="
if defined TRACK set "ARGS=--track %TRACK%"
if defined RAWLBA set "ARGS=--sector %RAWLBA%"

%PY% "tools\burn_wav.py" --device \\.\PhysicalDrive%DISK% %ARGS% --wav "!FILE!" --dry-run
if errorlevel 1 (
    echo.
    echo [X] 预检没过，一个字节都没写。按上面提示改。
    pause
    exit /b 1
)

rem ==================== 5. 写入 ====================
echo.
echo ------------------------------------------------------------
echo   预检通过。写入不可撤销，写错盘那块盘上的数据全没。
echo ------------------------------------------------------------
set "GO="
set /p "GO=确认写入？(y/N)："
if /i not "%GO%"=="y" (
    echo.
    echo 已取消，未写盘。
    pause
    exit /b 1
)

%PY% "tools\burn_wav.py" --device \\.\PhysicalDrive%DISK% %ARGS% --wav "!FILE!" --confirm
set "RC=%ERRORLEVEL%"

echo.
echo ------------------------------------------------------------
if not "%RC%"=="0" (
    echo [X] 写入报错。若已经写了一部分，请把这首完整重写一遍。
    pause
    exit /b 1
)
echo 上面必须看到"回读首扇区 / 末扇区：一致"才算写对。
if defined TRACK (
    echo 本次落点：第 %TRACK% 段
)
if defined RAWLBA (
    echo 本次落点：LBA %RAWLBA%
)
echo 卡插回电脑会提示"需要格式化"（分区表被覆盖的扇区碰到时）——别点格式化。
echo.
echo 上板自检：
echo   1) 第 1~4 页要各烧一次，否则四页听起来一样
echo   2) 第 5 段只在「自动展播」模式（app_mode=1）被选中
echo   3) 听不到就查：卡是否识别、这一段是否真在目标扇区
echo.
pause
exit /b 0

rem ============================================================
rem  子程序：列桌面音频并选编号
rem ============================================================
:pick_file
echo.
echo 桌面上的音频（WAV 才可直接烧）：
set "IDX=0"
if exist "%USERPROFILE%\Desktop\*.wav" for %%F in ("%USERPROFILE%\Desktop\*.wav") do call :add "%%~fF"
if exist "%USERPROFILE%\OneDrive\Desktop\*.wav" for %%F in ("%USERPROFILE%\OneDrive\Desktop\*.wav") do call :add "%%~fF"
if "%IDX%"=="0" (
    echo     （桌面上没找到 .wav）
    echo.
    set /p "FILE=手输完整路径（可右键粘贴）："
    exit /b
)
echo     [0] 手输完整路径
echo.
set "PICK="
set /p "PICK=输入编号："
if not defined PICK exit /b
if "%PICK%"=="0" (
    echo.
    set /p "FILE=完整路径："
    exit /b
)
if defined F%PICK% set "FILE=!F%PICK%!"
if defined FILE echo   已选：!FILE!
exit /b

:add
set /a IDX+=1
set "F%IDX%=%~1"
echo     [!IDX!] %~nx1
exit /b

:badisk
echo.
echo [X] 盘号必须是纯数字（上面第一列那个），不要写 \\.\PhysicalDrive1 或 C:。
pause
exit /b 1

:badslot
echo.
echo [X] 段号必须是纯数字（1~5 或一个 LBA 值），不要写 0x、逗号或单位。
pause
exit /b 1
