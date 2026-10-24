`timescale 1ns/1ps
// input_filter 的基线契约：
//  1) 复位释放后第一拍只把当前电平取作基线，绝不能把"上电时已经按下"的
//     输入伪造成一次按键事件（否则接错线/少上拉会让主模式每次上电跳一级）；
//  2) 短于 STABLE_MS 的毛刺不产生上升沿；
//  3) 真实按下只产生一个上升沿，按住不放不重复触发，松开不产生上升沿。
module tb_input_filter;
    localparam integer CLK_PER_MS = 25000;      // 25 MHz，与 video_clk 一致
    localparam integer STABLE_MS = 3;

    reg clk = 0;
    always #20 clk = ~clk;

    reg rst_n = 0;
    reg [3:0] raw = 4'b1010;                    // 上电时 bit3/bit1 已是"按下"电平
    wire [3:0] level, rise;

    // 1 ms 周期节拍。真实系统里 tick_ms 由 timebase 在同一个 rst_n 下产生，
    // 复位释放后整 1 ms 才来第一拍，同步链早已稳定；这里同样与复位对齐。
    reg [15:0] tcnt = 0;
    reg tick_ms = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            tcnt <= 0;
            tick_ms <= 1'b0;
        end else if (tcnt == CLK_PER_MS - 1) begin
            tcnt <= 0;
            tick_ms <= 1'b1;
        end else begin
            tcnt <= tcnt + 1'b1;
            tick_ms <= 1'b0;
        end
    end

    input_filter #(.WIDTH(4), .STABLE_MS(STABLE_MS)) dut (
        .clk(clk), .rst_n(rst_n), .tick_ms(tick_ms),
        .raw(raw), .level(level), .rise(rise));

    // 每个通道各记上升沿个数
    integer rises [0:3];
    integer i;
    initial for (i = 0; i < 4; i = i + 1) rises[i] = 0;
    always @(posedge clk) begin
        for (i = 0; i < 4; i = i + 1) if (rise[i]) rises[i] = rises[i] + 1;
    end

    task wait_ms(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) repeat (CLK_PER_MS) @(posedge clk);
        end
    endtask

    task expect_level(input [3:0] want, input [255:0] why);
        begin
            if (level !== want)
                $fatal(1, "%0s: level=%b want %b", why, level, want);
        end
    endtask

    task expect_rises(input integer b0, input integer b1,
                      input integer b2, input integer b3, input [255:0] why);
        begin
            if (rises[0] != b0 || rises[1] != b1 || rises[2] != b2 || rises[3] != b3)
                $fatal(1, "%0s: rise counts %0d/%0d/%0d/%0d want %0d/%0d/%0d/%0d",
                       why, rises[0], rises[1], rises[2], rises[3], b0, b1, b2, b3);
        end
    endtask

    initial begin
        // ---- 1) 上电基线：bit3/bit1 上电即"按下"，不许冒充按键事件 ----
        wait_ms(3);                              // 复位保持
        rst_n = 1'b1;
        wait_ms(6);
        expect_level(4'b1010, "baseline adopts power-up level");
        expect_rises(0, 0, 0, 0, "no rise from power-up level");

        // ---- 2) bit3 松开、bit2 按下：只有 bit2 一个上升沿 ----
        raw = 4'b0110;
        wait_ms(6);
        expect_level(4'b0110, "level follows raw");
        expect_rises(0, 0, 1, 0, "only the newly pressed bit rises");

        // ---- 3) 毛刺：短于 STABLE_MS 的按下不算按键 ----
        raw[0] = 1'b1;
        wait_ms(1);
        raw[0] = 1'b0;
        wait_ms(6);
        expect_level(4'b0110, "glitch rejected");
        expect_rises(0, 0, 1, 0, "glitch produces no rise");

        // ---- 4) 真实按下：一个上升沿；按住期间不重复触发 ----
        raw[0] = 1'b1;
        wait_ms(6);
        expect_level(4'b0111, "press latched");
        expect_rises(1, 0, 1, 0, "press yields one rise");
        wait_ms(10);                             // 继续按住
        expect_rises(1, 0, 1, 0, "held key must not repeat");

        // ---- 5) 松开：回到 0，上升沿计数不变 ----
        raw[0] = 1'b0;
        wait_ms(6);
        expect_level(4'b0110, "release latched");
        expect_rises(1, 0, 1, 0, "release is not a rise");

        // ---- 6) 复位后再次上电基线：此时 bit2 是"按下"，同样不许冒充 ----
        rst_n = 1'b0;
        wait_ms(2);
        rst_n = 1'b1;
        wait_ms(6);
        expect_level(4'b0110, "re-baseline adopts current level");
        expect_rises(1, 0, 1, 0, "reset release yields no rise");

        $display("PASS: input_filter baseline/press semantics");
        $finish;
    end
endmodule
