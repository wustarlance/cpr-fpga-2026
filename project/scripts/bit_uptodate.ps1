# build_bit_fast.bat 的"是否需要重建"判定。
#
# 退出码即答案，调用方（bat）只看这个：
#   0 = 所有目标顶层的位流都比 rtl\、constraints\、project.al 新 -> 可以不建
#   1 = 有位流缺失，或某个 RTL/约束/工程文件比位流新          -> 必须建
#   2 = 判定失败（PowerShell 异常等）                        -> 当作必须建，宁可多跑一次
#
# 用法（cwd 一般是 project 目录）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\bit_uptodate.ps1 top
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\bit_uptodate.ps1 top top_adc

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Targets
)

$ErrorActionPreference = 'Stop'

try {
    if (-not $Targets -or $Targets.Count -eq 0) { $Targets = @('top') }

    # 本脚本在 <project>\scripts\ 下，工程根目录是它的上一层
    $root = Split-Path -Parent $PSScriptRoot
    if (-not (Test-Path (Join-Path $root 'project.al'))) {
        Write-Host "[i] 找不到 $root\project.al，跳过判定。"
        exit 2
    }

    $sources = @()
    $sources += Get-ChildItem (Join-Path $root 'rtl')         -Recurse -File -ErrorAction SilentlyContinue
    $sources += Get-ChildItem (Join-Path $root 'constraints') -Recurse -File -ErrorAction SilentlyContinue
    $sources += Get-Item      (Join-Path $root 'project.al')  -ErrorAction SilentlyContinue
    # 构建脚本改了（改了 set_param / 流程）也必须重建，否则会守着旧位流
    $sources += Get-Item      (Join-Path $root 'build_fast.tcl') -ErrorAction SilentlyContinue
    $sources += Get-Item      (Join-Path $root 'build.tcl')      -ErrorAction SilentlyContinue
    $sources  = $sources | Sort-Object LastWriteTime -Descending

    foreach ($t in $Targets) {
        $bit = Join-Path $root "build\$t\$t.bit"
        if (-not (Test-Path $bit)) {
            Write-Host "[i] build\$t\$t.bit 不存在，需要构建 $t。"
            exit 1
        }
        $bt = (Get-Item $bit).LastWriteTime
        $newer = $sources | Where-Object { $_.LastWriteTime -gt $bt }
        if ($newer) {
            $f = $newer[0]
            Write-Host ("[i] {0}: 位流 {1:yyyy/MM/dd HH:mm}，但 {2} 改于 {3:yyyy/MM/dd HH:mm}，需要构建。" -f `
                        $t, $bt, $f.Name, $f.LastWriteTime)
            exit 1
        }
        Write-Host ("[i] {0}: 位流 {1:yyyy/MM/dd HH:mm} 已包含全部 RTL/约束改动。" -f $t, $bt)
    }

    exit 0
}
catch {
    Write-Host ("[i] 判定异常，按需要构建处理：" + $_.Exception.Message)
    exit 2
}
