# -*- coding: utf-8 -*-
"""作品名称 / 作品简介 字数核算（表单按含换行符计 500 字上限）。
用法：python3 count.py [briefs.json ...]
不带参数则核算本目录下所有 briefs*.json。
"""
import re, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))

NAMES = {
    "应急避险电子明白卡（新方向）": [
        "基层应急避险电子明白卡",
        "电子明白卡：基层应急避险终端",
        "基层应急避险电子明白卡终端",
        "应急避险电子明白卡终端",
        "电子明白卡·应急避险终端",
        "断路断网断电也能亮的避险屏",
        "断网断电也能亮的应急避险屏",
        "极端条件下可用的应急避险终端",
        "不依赖网络的基层应急避险终端",
        "秒启低功耗应急避险信息屏",
        "小快轻智应急避险终端",
        "村级应急避险声画终端",
        "声画避险电子明白卡",
        "基层避险明白卡数字终端",
        "一屏讲清怎么躲的应急终端",
    ],
    "声画长卷数字展陈（备选）": [
        "声画长卷交互式数字展陈终端",
        "长卷式交互数字展陈终端",
        "声画长卷·数字展陈终端",
        "可换展的声画长卷终端",
        "无需换硬件的声画长卷",
        "长卷式无障碍数字展陈终端",
        "事件驱动的声画长卷展陈终端",
        "声画长卷数字展陈终端",
        "一芯长卷数字展陈终端",
        "可换内容的长卷展陈终端",
        "长卷分众数字展陈终端",
        "声画长卷·基层展陈终端",
    ],
}


def report_names():
    for group, names in NAMES.items():
        print("=== 作品名称 · %s（上限 15 字）===" % group)
        for n in names:
            print("%3d  %-18s %s" % (len(n), n, "OK" if len(n) <= 15 else "TOO LONG"))
        print()


def report_briefs(path):
    briefs = json.load(open(path, encoding="utf-8"))
    print("=== 作品简介 · %s（上限 500 字，含换行）===" % os.path.basename(path))
    allok = True
    for k, v in briefs.items():
        nows = len(re.sub(r"\s", "", v))
        paras = len([p for p in v.split("\n") if p.strip()])
        ok = len(v) <= 500 and nows <= 500
        allok = allok and ok
        print("--- %s ---" % k)
        print("  总长(含换行) = %d" % len(v))
        print("  去空白       = %d" % nows)
        print("  换行数       = %d   段落数 = %d" % (v.count("\n"), paras))
        print("  判定         = %s" % ("OK" if ok else "OVER by %d" % (len(v) - 500)))
    print()
    return allok


if __name__ == "__main__":
    report_names()
    targets = sys.argv[1:] or sorted(
        f for f in os.listdir(HERE) if f.startswith("briefs") and f.endswith(".json")
    )
    bad = [t for t in targets if not report_briefs(os.path.join(HERE, t))]
    print("全部通过" if not bad else "超出上限: %s" % bad)
