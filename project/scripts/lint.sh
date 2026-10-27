#!/usr/bin/env bash
# =============================================================================
#  lint.sh —— 用 Verilator 对整个工程做跨文件静态检查（不综合、不出位流）
#
#  为什么需要它：
#    VS Code 的 Verilog 扩展是「verilator --lint-only <当前文件>」，它只编译
#    一个文件、看不到别处的 module 定义，于是 sd_card_bmp / sd_card_top /
#    HDMI 加密核这些定义在别的目录的模块全被判"未定义"，满屏红线。
#    这个脚本喂给它【完整文件列表 project/filelist.f】，所以跨文件端口/位宽
#    连接是真的会检查的。
#
#  用法：
#      ./project/scripts/lint.sh                # 默认：顶层 top，只报错误 + 高信号告警
#      ./project/scripts/lint.sh --top top_adc  # 检查 ADC 版
#      ./project/scripts/lint.sh --strict       # 不压制任何告警（首次审计用）
#      ./project/scripts/lint.sh --widths       # 只看位宽类告警（真错的常见来源）
#      ./project/scripts/lint.sh --fail-on-warn # 有告警就返回非 0（以后接 CI 用）
#
#  退出码：0 = 无错误；1 = 有 %Error 或 Verilator 运行失败；2 = --fail-on-warn 且有告警
#
#  已知边界（不是脚本问题，是工程本身）：
#    9 个模块是加密核 / TD IP，Verilator 解析不了，用 -Wno-MODMISSING 变成隐式
#    黑盒：hdmi_1_4b_transmitter_core_wrapper、sdr_as_ram、sdr_wrrd、sdr_init_ref、
#    sys_pll、video_pll、PLL_HDMI_AUDIO、rfifo_32_32_512、wfifo_32_32_512，
#    外加 EG_PHY_SDRAM_2M_32 / EG_LOGIC_ODDR 两个原语。
#    也就是说【这些实例上的端口连接不参与检查】，其余全部参与。
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$HERE/.." && pwd)"
FILELIST="$PROJECT/filelist.f"

TOP=top
STRICT=0
WIDTHS=0
FAIL_ON_WARN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --top)          TOP="${2:-}"; shift 2 ;;
        --strict)       STRICT=1; shift ;;
        --widths)       WIDTHS=1; shift ;;
        --fail-on-warn) FAIL_ON_WARN=1; shift ;;
        -h|--help)      sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "未知参数: $1（--help 看用法）" >&2; exit 1 ;;
    esac
done

case "$TOP" in top|top_adc) ;; *) echo "--top 只能是 top 或 top_adc，收到: $TOP" >&2; exit 1 ;; esac

[ -f "$FILELIST" ] || { echo "[FAIL] 缺少 $FILELIST" >&2; exit 1; }

# filelist.f 由 project.al 生成；不同步就会"检查了旧清单还显示通过"，所以先核对。
if command -v python3 >/dev/null 2>&1; then
    python3 "$PROJECT/scripts/gen_filelist.py" --check || \
        echo "  ↑ 上面这些问题不影响本次结果，但本次 lint 可能漏掉新文件。" >&2
elif command -v python >/dev/null 2>&1; then
    python "$PROJECT/scripts/gen_filelist.py" --check || true
else
    echo "（没找到 python，跳过 filelist.f 新鲜度检查）" >&2
fi

VERILATOR_BIN="${VERILATOR:-}"
if [ -z "$VERILATOR_BIN" ]; then
    if command -v verilator >/dev/null 2>&1; then VERILATOR_BIN="$(command -v verilator)"
    elif [ -x /home/starlance/code/oss_cad_suite/oss-cad-suite/bin/verilator ]; then
        VERILATOR_BIN=/home/starlance/code/oss_cad_suite/oss-cad-suite/bin/verilator
    fi
fi
if [ -z "$VERILATOR_BIN" ] || [ ! -x "$VERILATOR_BIN" ]; then
    cat >&2 <<'EOF'
[FAIL] 找不到 verilator。
  Linux : apt install verilator              （或装 oss-cad-suite）
  Windows: 用 oss-cad-suite 的 Windows 版（自带 verilator），或 MSYS2 里 pacman -S verilator
  也可以用环境变量指定：VERILATOR=/path/to/verilator ./project/scripts/lint.sh
EOF
    exit 1
fi

# 默认压制：纯风格/厂商噪声，永远不指向真错的那些
#   EOFNEWLINE       文件末尾没有换行             （9 条）
#   DECLFILENAME     模块名和文件名不一致         （3 条，厂商 IP 包装）
#   TIMESCALEMOD     部分厂商文件没写 `timescale  （4 条）
#   GENUNNAMED       未命名的 generate 块         （8 条）
#   UNUSEDPARAM      参数声明了没用               （11 条）
#   UNUSEDSIGNAL     信号声明了没用               （85 条，厂商代码里最多）
#   PINCONNECTEMPTY  显式留空的端口（.level()）   （38 条，故意的）
SUPPRESS=(
    -Wno-EOFNEWLINE -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-GENUNNAMED
    -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY
)
if [ "$STRICT" = "1" ]; then SUPPRESS=(); fi

ARGS=(--lint-only -Wall -Wno-fatal -Wno-MODMISSING --top-module "$TOP"
      ${SUPPRESS[@]+"${SUPPRESS[@]}"} -f "$FILELIST")
if [ "$WIDTHS" = "1" ]; then ARGS+=(--error-limit 100000); fi

# filelist.f 里的路径是相对 project/ 的（和 project.al 一致），必须先切进去。
cd "$PROJECT" || { echo "[FAIL] 进不去 $PROJECT" >&2; exit 1; }

echo "============================================================"
echo "  Verilator : $("$VERILATOR_BIN" --version | head -1)"
echo "  顶层      : $TOP"
echo "  源文件    : $(grep -vc '^-I' "$FILELIST") 个（project/filelist.f）"
echo "  模式      : $([ "$STRICT" = 1 ] && echo 严格（不压制告警） || echo 默认（压制风格噪声）)"
echo "============================================================"
echo

OUT="$("$VERILATOR_BIN" "${ARGS[@]}" 2>&1)"
RC=$?
printf '%s\n' "$OUT"

echo
echo "-------------------- 汇总 --------------------"
if printf '%s' "$OUT" | grep -q '%Error'; then
    printf '错误   : %s 条\n' "$(printf '%s' "$OUT" | grep -c '%Error')"
else
    echo "错误   : 0"
fi
printf '告警   : %s 条\n' "$(printf '%s' "$OUT" | grep -cE '%Warning' || true)"

if [ "$WIDTHS" = "1" ] || [ "$STRICT" = "1" ]; then
    echo
    echo "按类别："
    printf '%s\n' "$OUT" | grep -oE '%Warning-[A-Z0-9_]+' | sed 's/%Warning-//' \
        | sort | uniq -c | sort -rn | sed 's/^/   /'
    echo
    echo "按文件（前 10，只看我们自己的 rtl/ 与 vendor/SD/）："
    printf '%s\n' "$OUT" | grep -E '%Warning' | sed -E 's/^%Warning-[A-Z0-9_]+: ([^:]+):.*/\1/' \
        | grep -E '^(rtl/|vendor/SD/)' | sort | uniq -c | sort -rn | head -10 | sed 's/^/   /'
fi

echo
if [ "$RC" -ne 0 ]; then
    echo "结论：有错误，必须修（错误几乎都是端口/位宽/未定义信号级别的真问题）。"
    exit 1
fi
if [ "$FAIL_ON_WARN" = "1" ] && printf '%s' "$OUT" | grep -q '%Warning'; then
    echo "结论：无错误，但有告警（--fail-on-warn 生效，返回 2）。"
    exit 2
fi
echo "结论：无错误。加 --strict 看全部告警，--widths 专看位宽类。"
exit 0
