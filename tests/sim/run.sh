#!/usr/bin/env bash
#=============================================================================
# projects/sim/run.sh  --  一键仿真脚本
#
# 用法:
#   ./run.sh                       # 默认跑 tb_eg_phy_adc_stub
#   ./run.sh tb_peak_detect        # 跑指定 testbench
#   ./run.sh tb_peak_detect wave   # 跑完顺手用 gtkwave 打开波形
#   ./run.sh tb_xxx vvp "extra args"
#
# 它做什么:
#   1. 把 stubs/ 下所有 .v (安路原语的行为桩) + tb/<名字>.v 一起编译
#   2. 运行, 并检查输出里有没有 [FAIL]
#   3. 波形输出到 waves/<名字>.vcd
#
# 为什么单独用脚本而不是每次敲 iverilog:
#   避免"忘了带某个桩"导致一堆无意义的 module not found;
#   并且把"判成功失败"变成标准动作(有 FAIL 就返回非零退出码)。
#=============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TB_NAME="${1:-tb_eg_phy_adc_stub}"
ACTION="${2:-run}"

TB_FILE="$HERE/tb/${TB_NAME}.v"
STUBS=$(ls "$HERE"/stubs/*.v 2>/dev/null)
BUILD="$HERE/build"
WAVES="$HERE/waves"
VVPOUT="$BUILD/${TB_NAME}.vvp"

mkdir -p "$BUILD" "$WAVES"

if [ ! -f "$TB_FILE" ]; then
    echo "[错误] 找不到 testbench: $TB_FILE"
    echo "       现有 testbench:"
    ls "$HERE/tb"/*.v 2>/dev/null | sed 's|.*/|         |'
    exit 2
fi

if ! command -v iverilog >/dev/null 2>&1; then
    echo "[错误] 找不到 iverilog。它在 oss-cad-suite 里, 记得先 source 环境或用全路径。"
    exit 2
fi

echo "======================================================================"
echo " 编译  : $TB_NAME"
echo " 桩文件: $(echo "$STUBS" | wc -w) 个"
echo "======================================================================"

# shellcheck disable=SC2086
iverilog -g2012 -Wall -o "$VVPOUT" $STUBS "$TB_FILE" 2>&1 | tee "$BUILD/${TB_NAME}.compile.log"
RC=${PIPESTATUS[0]}

if [ "$RC" -ne 0 ] || [ ! -f "$VVPOUT" ]; then
    echo ""
    echo "[失败] 编译不通过, 退出码 $RC"
    echo "       完整日志: $BUILD/${TB_NAME}.compile.log"
    exit 1
fi

echo ""
echo "======================================================================"
echo " 运行"
echo "======================================================================"
( cd "$HERE" && vvp "$VVPOUT" ) 2>&1 | tee "$BUILD/${TB_NAME}.run.log"
RUNRC=${PIPESTATUS[0]}

echo ""
if grep -q '\[FAIL\]' "$BUILD/${TB_NAME}.run.log"; then
    echo "[失败] 仿真报告中有 [FAIL] 项 -> 逻辑有问题, 去看上面的输出"
    exit 1
elif grep -q 'TIMEOUT' "$BUILD/${TB_NAME}.run.log"; then
    echo "[失败] 仿真超时 -> 大概率是握手/状态机卡死了"
    exit 1
elif [ "$RUNRC" -ne 0 ]; then
    echo "[失败] vvp 退出码 $RUNRC"
    exit "$RUNRC"
else
    echo "[成功] 编译与自检全部通过"
fi

if [ -f "$WAVES/${TB_NAME}.vcd" ]; then
    echo "       波形: $WAVES/${TB_NAME}.vcd"
fi

if [ "$ACTION" = "wave" ] && command -v gtkwave >/dev/null 2>&1; then
    echo "       打开 gtkwave ..."
    gtkwave "$WAVES/${TB_NAME}.vcd" >/dev/null 2>&1 &
fi

exit 0
