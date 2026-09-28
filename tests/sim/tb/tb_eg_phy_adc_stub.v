//=============================================================================
// tb_eg_phy_adc_stub.v  --  ADC 行为桩的自检式 testbench
//=============================================================================
// 自检式 testbench 的要点(和"人眼看波形"的区别):
//   1. 每个检查点自己判断对错, 打印 [ ok ] / [FAIL]
//   2. 结束时给出 PASS/FAIL 总结, 让脚本能判断成败
//   3. 关键时序(如 eoc 出现在第几拍)用**数值**断言, 不靠目测
//
// ⚠️ 中文陷阱: 不要把中文当字符串传进 task 的 input 参数
//    (Verilog 里字符串会打包成位向量, UTF-8 多字节会被截断/错位 -> 乱码)
//    正确做法: 中文用 $display 直接打印, task 只接收判定条件。
//
// 运行:  cd projects/sim && ./run.sh
//=============================================================================
`timescale 1ns / 1ps

module tb_eg_phy_adc_stub;

  // ---- 与桩保持一致的参数 ----
  localparam CONV_CLK = 18;

  // ---- 信号 ----
  reg         clk = 0, pd = 0, soc = 0;
  reg  [2:0]  s   = 0;
  wire        eoc;
  wire [11:0] dout;

  integer errors = 0;
  integer checks = 0;

  // ADC 工作时钟上限定为 16 MHz (官方手册表 2)
  always #31.25 clk = ~clk;          // 半周期 31.25ns -> 周期 62.5ns = 16MHz

  EG_PHY_ADC #(
      .CONV_CLK (CONV_CLK),
      .CH1      ("ENABLE")
  ) u_adc (
      .clk (clk), .pd (pd), .s (s), .soc (soc),
      .eoc (eoc), .dout (dout)
  );

  //------------------------------------------------------------------
  // 工具任务  (只接收判定条件, 不接收中文)
  //------------------------------------------------------------------
  task check;
    input cond;
    begin
      checks = checks + 1;
      if (!cond) begin
        errors = errors + 1;
        $display("       ^^^ [FAIL]");
      end else begin
        $display("       ^^^ [ ok ]");
      end
    end
  endtask

  // 发一次转换请求
  task do_soc;
    input [2:0] ch;
    begin
      @(posedge clk);
      s   = ch;
      soc = 1'b1;
      @(posedge clk);
      soc = 1'b0;
    end
  endtask

  // 等 eoc 上升, 返回等待拍数与结果值
  task wait_eoc;
    output integer waited;
    output [11:0]  val;
    integer n;
    begin
      n = 0;
      while (!eoc && n < 200) begin
        @(posedge clk);
        n = n + 1;
      end
      waited = n;
      val    = dout;
    end
  endtask

  integer    w;
  reg [11:0] v;

  //------------------------------------------------------------------
  // 主激励
  //------------------------------------------------------------------
  initial begin
    $dumpfile("waves/tb_eg_phy_adc_stub.vcd");
    $dumpvars(0, tb_eg_phy_adc_stub);

    $display("");
    $display("======================================================================");
    $display(" 测试 1: 上电初始状态");
    $display("======================================================================");
    #200;
    $display("  上电后 eoc 应为 0");
    check(eoc === 1'b0);
    $display("  上电后 dout 应为 0");
    check(dout === 12'd0);

    $display("");
    $display("======================================================================");
    $display(" 测试 2: 单次转换的协议时序");
    $display("======================================================================");
    u_adc.chan_val[1] = 12'h8AB;      // 注入通道 1 的值(层次引用)
    do_soc(3'd1);
    wait_eoc(w, v);
    $display("  等待 %0d 拍后 eoc 拉高, dout = 0x%03h (%0d)", w, v, v);
    $display("  eoc 应在 %0d 拍后出现", CONV_CLK);
    check(w == CONV_CLK);
    $display("  dout 应等于注入的通道值 0x8AB");
    check(v == 12'h8AB);

    $display("");
    $display("======================================================================");
    $display(" 测试 3: 换通道应拿到新值");
    $display("======================================================================");
    u_adc.chan_val[2] = 12'h123;
    do_soc(3'd2);
    wait_eoc(w, v);
    $display("  通道 2 -> dout = 0x%03h, 应为 0x123", v);
    check(v == 12'h123);

    u_adc.chan_val[1] = 12'h456;
    do_soc(3'd1);
    wait_eoc(w, v);
    $display("  通道 1 -> dout = 0x%03h, 应为 0x456", v);
    check(v == 12'h456);

    $display("");
    $display("======================================================================");
    $display(" 测试 4: PD 掉电应清状态");
    $display("======================================================================");
    u_adc.chan_val[0] = 12'hFFF;
    do_soc(3'd0);
    @(posedge clk); @(posedge clk);   // 转换进行中
    pd = 1'b1;
    @(posedge clk); @(posedge clk);
    $display("  PD 拉高后 eoc 应为 0");
    check(eoc === 1'b0);
    $display("  PD 拉高后 dout 应为 0");
    check(dout === 12'd0);
    pd = 1'b0;
    @(posedge clk);

    $display("");
    $display("======================================================================");
    $display(" 测试 5: 采样间隔 vs 官方建议 (>= 100 kHz)");
    $display("======================================================================");
    // 方案 §10.5 用的是 1kHz 采样, 而官方手册 §5 明确写:
    //   "建议 SOC 采样间隔要小于 10us, 即采样频率不要低于 100Khz;
    //    若需要大间隔的采样, 需要在 SOC 到来 5 个时钟周期前拉高一下 PD 脚"
    // 注意: 这是模拟/电源层面的行为, **数字行为桩无法仿真它**, 只能在此提示。
    $display("  方案当前: 间隔 1000.0 us = 1.0 kHz");
    $display("");
    $display("  !! 间隔 > 10us, 按官方 §5 需要【在 SOC 前 5 个时钟周期先拉高 PD】");
    $display("     两种改法:");
    $display("       (a) 连续以 >=100kHz 采样, 逻辑里抽稀到 1kHz      <<< 推荐, 不改模拟电路");
    $display("       (b) 保持 1kHz, 但每次 SOC 前加一个 PD 脉冲");
    $display("");
    $display("  数字桩无法验证这一条 —— 它属于器件模拟特性, 必须上板实测。");
    $display("  这正是【行为桩的边界】: 桩验证你们的逻辑, 不验证厂商器件的模拟行为。");

    $display("");
    $display("======================================================================");
    if (errors == 0)
      $display(" 全部通过: %0d/%0d 项检查 OK", checks, checks);
    else
      $display(" 有失败: %0d 项检查中 %0d 项 FAIL", checks, errors);
    $display("======================================================================");
    $display("");
    $finish;
  end

  // 总超时保护
  initial begin
    #2_000_000;
    $display("!! TIMEOUT !!");
    $finish;
  end

endmodule
