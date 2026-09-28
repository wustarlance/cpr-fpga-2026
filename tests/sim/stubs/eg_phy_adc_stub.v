//=============================================================================
// eg_phy_adc_stub.v  --  安路 EG_PHY_ADC 的行为桩
//=============================================================================
// 为什么需要这个文件
// ------------------
// 安路官方的仿真模型在 TD 安装目录下:
//     .tools/anlogic-td/<版本>/sim_release/eg4/eg_phy_adc.v
// 但它从第 325 行起是 `pragma protect begin_protected` 加密段(信封加密给
// Mentor/Synopsys/Cadence)，**iverilog / verilator 无法解密**，编译直接报
// syntax error。本桩提供等价的可仿真行为，用于验证「你们自己写的逻辑」。
//
// 引脚名、参数名与官方 EG_PHY_ADC 完全一致，因此:
//     仿真时   用本文件替换官方模型
//     综合上板 换回官方 IP
// 两边都不需要改例化代码。
//
// 官方规格(来源: _ref/手册摘录/ADC.txt，TN304 v1.3 表 2)
// ------------------------------------------------------
//   工作电压      : 3.3V 模拟(VDDA) + 3.3V 数字(VDDD)
//   最高时钟频率  : 16 MHz
//   最高采样速率  : 1 MHz
//   通道数        : 8
//   输出位宽      : 12 bit
//   ★ 有效精度    : 8 bit   (不是 12 bit! 低位是噪声)
//   ★ 采样范围    : 0.1*VREF ~ 0.9*VREF   (两端各 10% 不可用)
//   VREF 范围     : 0.5 ~ 1.0 x VDDA
//   ★ §5 注意事项 : SOC 采样间隔要小于 10us(即 >=100kHz);
//                   若需大间隔采样, 必须在 SOC 到来前 5 个时钟周期先拉高 PD
//
// 本桩的行为
// ----------
//   pd=1        -> 掉电, eoc=0, dout=0
//   soc 上升沿  -> 锁存通道号, 开始转换, 经 CONV_CLK 个时钟后
//                  eoc 拉高 1 拍, dout 输出该通道当前值
//   通道值来源  -> 内部数组 chan_val[0:7], 由 testbench 通过层次引用注入
//                  例: dut.u_adc.chan_val[1] = 12'h800;
//=============================================================================
`timescale 1ns / 1ps

module EG_PHY_ADC (clk, pd, s, soc, eoc, dout);

  input             clk;    // ADC 工作时钟, fmax = 16 MHz
  input             pd;     // 掉电控制, 高有效
  input      [2:0]  s;      // 通道选择 0~7
  input             soc;    // 开始转换, 高有效
  output reg        eoc;    // 转换完成, 高有效(1 拍)
  output reg [11:0] dout;   // 转换结果

  // --- 与官方一致的参数名(本桩不解析字符串, 仅为引脚/参数级兼容) ---
  parameter CH0 = "DISABLE";
  parameter CH1 = "DISABLE";
  parameter CH2 = "DISABLE";
  parameter CH3 = "DISABLE";
  parameter CH4 = "DISABLE";
  parameter CH5 = "DISABLE";
  parameter CH6 = "DISABLE";
  parameter CH7 = "DISABLE";
  parameter VREF = "DISABLE";

  // --- 本桩专有参数 ---
  // 转换耗时(时钟周期). ⚠️ 官方手册未给出确切周期数, 18 是常见 SAR 的估值,
  // 上板后应实测标定; 这个数只影响"多久出 eoc", 不影响你们的判定逻辑。
  parameter CONV_CLK = 18;

  // 通道使能掩码(对应官方 CH0~CH7 = ENABLE). 未使能的通道本桩也照常返回,
  // 因为你们目前只用一个通道; 若需要严格模拟, 可自行改这一行。
  parameter [7:0] CH_EN_MASK = 8'h01;

  // --- 可被 testbench 注入的通道值 ---
  reg [11:0] chan_val [0:7];

  // --- 转换状态机 ---
  localparam IDLE = 2'd0, CONV = 2'd1;
  reg [1:0]  state;
  reg [2:0]  ch_lat;
  integer    cnt;

  integer k;
  initial begin
    state = IDLE;  cnt = 0;  ch_lat = 3'd0;
    eoc = 1'b0;  dout = 12'd0;
    for (k = 0; k < 8; k = k + 1)
      chan_val[k] = 12'd0;
  end

  always @(posedge clk) begin
    if (pd) begin
      // 掉电: 立即清状态
      state <= IDLE;
      eoc   <= 1'b0;
      dout  <= 12'd0;
      cnt   <= 0;
    end
    else begin
      case (state)
        IDLE: begin
          eoc <= 1'b0;
          if (soc) begin
            ch_lat <= s;        // 锁存发起转换时的通道号
            cnt    <= 0;
            state  <= CONV;
          end
        end
        CONV: begin
          if (cnt >= CONV_CLK - 1) begin
            dout  <= chan_val[ch_lat];
            eoc   <= 1'b1;      // 只拉高 1 拍
            state <= IDLE;
          end
          else begin
            cnt <= cnt + 1;
          end
        end
      endcase
    end
  end

  // --- 便于 testbench 观察: 转换启动时提示 ---
`ifdef ADC_STUB_VERBOSE
  always @(posedge clk)
    if (soc && !pd && state == IDLE)
      $display("      [ADC桩] %0t: 启动转换 ch=%0d", $time, s);
`endif

endmodule
