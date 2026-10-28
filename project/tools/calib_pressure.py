#!/usr/bin/env python3
"""按压盒标定计算器：把万用表量到的节点电压换算成 RTL 参数。

为什么要有它：正式位流 `top_adc` 的 ADC 域物理余量只有 +0.003 ns（hold），
再往里加"数码管显示原始码值"的调试逻辑会被 TD 判成 Too much hold violation
（11 条异常路径被跳过），调试位流出不来。所以标定先用万用表读电压，
再用这个脚本换算成 `top_tf_hdmi_audio.v` 里的 5 个参数。

用法（电压单位 V，全部对着 J2-30 GND 量 J2-35）：
    python3 project/tools/calib_pressure.py --vref 3.30 \
        --empty 3.28 --noise 0.01 --at5cm 0.60 --at6cm 0.61
"""
from __future__ import annotations

import argparse


def code(volts: float, vref: float) -> int:
    """电压 → 12 位 ADC 码值（线性、按满量程 vref 换算）。"""
    v = max(0.0, min(volts, vref))
    return int(round(v / vref * 4095.0))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vref", type=float, default=3.30, help="ADC 参考电压（实测 J2-29 电压）")
    ap.add_argument("--empty", type=float, required=True, help="空载时节点电压")
    ap.add_argument("--noise", type=float, default=0.005, help="空载电压波动峰峰值")
    ap.add_argument("--at5cm", type=float, required=True, help="5 cm 垫块保持时的电压")
    ap.add_argument("--at6cm", type=float, required=True, help="6 cm 垫块保持时的电压")
    ap.add_argument("--falling", type=int, default=1, choices=(0, 1),
                    help="1 = 越压码值越小（当前工程默认）")
    args = ap.parse_args()

    c_empty = code(args.empty, args.vref)
    c_noise = code(args.noise, args.vref)            # 峰峰值折算成码值
    c5 = code(args.at5cm, args.vref)
    c6 = code(args.at6cm, args.vref)

    def norm(c: int) -> int:
        return max(c_empty - c, 0) if args.falling else max(c - c_empty, 0)

    peak5, peak6 = norm(c5), norm(c6)
    trig = max(20, 3 * c_noise)                      # 噪声峰峰 ×3（至少 20）
    rel = max(10, 2 * c_noise)                       # 必须 < trigger
    lo = peak5 * 9 // 10                             # 5 cm 中位往下留 10% 余量
    hi = peak6 * 11 // 10                            # 6 cm 中位往上留 10% 余量

    print(f"VREF        = {args.vref:.3f} V")
    print(f"空载        = {args.empty:.3f} V → 码值 {c_empty}")
    print(f"噪声峰峰    = {args.noise:.3f} V → {c_noise} 码")
    print(f"5 cm        = {args.at5cm:.3f} V → 码值 {c5} → 归一化峰值 {peak5}")
    print(f"6 cm        = {args.at6cm:.3f} V → 码值 {c6} → 归一化峰值 {peak6}")
    print()
    print("建议写进 project/rtl/top/top_tf_hdmi_audio.v 的 module parameter：")
    print(f"    parameter [11:0] RELEASE_BASELINE = 12'd{c_empty};")
    print(f"    parameter [11:0] TRIGGER_LEVEL    = 12'd{trig};")
    print(f"    parameter [11:0] RELEASE_LEVEL    = 12'd{rel};")
    print(f"    parameter [11:0] TARGET_LOW       = 12'd{lo};")
    print(f"    parameter [11:0] TARGET_HIGH      = 12'd{hi};")
    print(f"    parameter FALLING_WITH_FORCE       = {args.falling};")
    print()
    if peak6 <= peak5:
        print("⚠ 6 cm 的归一化峰值没有比 5 cm 大：传感器可能已经饱和，")
        print("  建议把分压电阻改成 3.3 kΩ 或换更高量程的 FSR 再测。")
    elif peak5 < trig:
        print("⚠ 5 cm 峰值比触发阈值还小：分压或接线有问题（节点没接对/线断了）。")
    else:
        print("✓ 两档峰值单调且都在触发阈值以上，可以按上面的参数重建位流。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
