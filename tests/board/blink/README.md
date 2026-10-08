# blink —— 上板首日自检

**用途**：板子到手后第一次下载，确认「USB 供电 → JTAG 识别 → 位流下载 → FPGA 运行」整条链路通。
不依赖 TF 卡、显示器、扩展口 —— 插一根 USB 线就能看见结果（也听得见）。

## 构建

```bash
cd tests/board/blink
td blink.tcl                 # 全命令行，不出 GUI；产物 blink.bit
```

## 下载

```bash
# HX4S20C 用 USB-B 口（下载 + 供电同一根线）
openFPGALoader -c anlogicCable tests/board/blink/blink.bit
```

默认写 SRAM，**掉电即丢**（bring-up 阶段这样更安全）。要固化再查 `openFPGALoader` 的 flash 写选项。

## 现象

| 现象 | 说明 |
|---|---|
| 4 个独立 LED 以 1 Hz 二进制计数 0→15 | 板子活着且逻辑在跑 |
| 每次加 1 时蜂鸣器「嘀」一声（80 ms） | **SW5 拨下**才接通蜂鸣器 |
| 按 KEY1 复位 | 计数归零 |

> LED 极性未知（高电平点亮 or 低电平点亮）。两种接法都能看到**有规律的计数**：
> 若看到的值是反的，说明是低电平点亮 —— 据此即可确定极性，不用查原理图。

## 与 `.tools/selftest` 的区别

`.tools/selftest/selftest.bit` 也能下载，但它的 `led[3:0]` 接在 **C15/C16/B6/A5**，
那是**数码管 / 双色 LED 复用**的引脚（受 SW6 切换），**烧进去可能什么都看不见**。
它只适合验证"工具链能出位流"，不适合验证"板子活着"。本工程用的是真正的 4 个独立 LED。
