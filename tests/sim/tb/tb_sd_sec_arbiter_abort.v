`timescale 1ns/1ps
//=============================================================================
// tb_sd_sec_arbiter_abort.v —— 换页换曲时"挂起请求"的两条契约
//-----------------------------------------------------------------------------
// 回归对象（sd_sec_arbiter.v 2026-10-26 的改法）：
//   1) ch1 的 read 只在**上升沿**锁存进 wav_pend，不能按电平；
//   2) 请求方撤销（换曲 abort，ch1_read 落下）时，尚未发出的 wav_pend 必须
//      一起丢掉 —— 否则它会在 BMP 让出总线之后补发一整扇区，那一整套
//      512 字节 + end 会撞进新曲目的头部解析。
//
// 为什么必须单独一个 TB：tb_wav_page_switch 里 ch0 是接 0 的（"BMP 通道空着"），
// 于是 wav_pend 永远是"当拍锁存、下一拍就发出"，既不会挂着、也不会遇到撤销，
// 把仲裁器改回电平触发它照样 PASS（2026-10-26 实测确认）。这里把 BMP 真的
// 跑起来，才构造得出"挂起 + 撤销"这个窗口。
//
// 四条断言：
//   P1  ch1 独占总线：一次请求恰好换一次事务（不能被读两遍）
//   P2  BMP 占线时 ch1 的请求被 pending 吸收，BMP 让出后补发一次（抓过度修正）
//   P3  BMP 占线 + ch1 撤销：abort 之后**不得**再出现旧地址的事务（本次回归）
//   P4  撤销之后重新请求，仍能被正常服务（不能把 ch1 饿死）
//
// 说明：这里用 LEN=8 字节的"短扇区"。仲裁器只认 I_sd_end，不关心一扇区多少
// 字节，缩短长度只是让波形好读、仿真快；事务边界语义与 512 字节完全一致。
//=============================================================================
module tb_sd_sec_arbiter_abort;

    localparam integer LEN = 8;
    localparam [31:0]  A_WAV = 32'h0000_1000;   // ch1 的地址（换页前那一首）
    localparam [31:0]  A_BMP = 32'h0002_0000;   // ch0 的地址

    /* ---------------- 时钟 ---------------- */
    reg clk = 0;
    always #5 clk = ~clk;                        // 100 MHz，与 sd_card_clk 同频
    reg rst = 1;

    /* ---------------- SD 上游（模拟 sd_card_sec_read_write 的语义） -------- */
    reg         sd_ready = 1'b1;
    wire        sd_read;
    wire [31:0] sd_addr;
    reg  [7:0]  sd_data;
    reg         sd_valid = 1'b0;
    reg         sd_end   = 1'b0;

    /* ---------------- ch0：BMP 画面（优先，背靠背突发） ---------------- */
    wire        ch0_ready;
    reg         ch0_read = 1'b0;
    reg  [31:0] ch0_addr = A_BMP;
    wire [7:0]  ch0_data;
    wire        ch0_valid, ch0_end;

    /* ---------------- ch1：WAV 音频（让路，read 电平保持到 end） -------- */
    wire        ch1_ready;
    reg         ch1_read = 1'b0;
    reg  [31:0] ch1_addr = A_WAV;
    wire [7:0]  ch1_data;
    wire        ch1_valid, ch1_end;

    sd_sec_arbiter dut (
        .clk         (clk),
        .rst         (rst),
        .I_sd_ready  (sd_ready),
        .O_sd_read   (sd_read),
        .O_sd_addr   (sd_addr),
        .I_sd_data   (sd_data),
        .I_sd_valid  (sd_valid),
        .I_sd_end    (sd_end),
        .O_ch0_ready (ch0_ready),
        .I_ch0_read  (ch0_read),
        .I_ch0_addr  (ch0_addr),
        .O_ch0_data  (ch0_data),
        .O_ch0_valid (ch0_valid),
        .O_ch0_end   (ch0_end),
        .O_ch1_ready (ch1_ready),
        .I_ch1_read  (ch1_read),
        .I_ch1_addr  (ch1_addr),
        .O_ch1_data  (ch1_data),
        .O_ch1_valid (ch1_valid),
        .O_ch1_end   (ch1_end)
    );

    /*=========================================================================
     * 合成 SD：O_sd_read 是授权那一拍的脉冲；一旦开始，LEN 字节 + 一个 end
     * 必定发完，不理会请求是否已经撤销（vendor 状态机就是这样）。
     *=======================================================================*/
    reg        xfer  = 1'b0;
    reg        fin   = 1'b0;
    integer    xcnt  = 0;
    reg [31:0] xaddr = 32'd0;

    initial begin
        sd_data  = 8'h00;
        sd_valid = 1'b0;
        sd_end   = 1'b0;
    end

    always @(posedge clk) begin
        if (rst) begin
            xfer <= 1'b0; fin <= 1'b0; xcnt <= 0;
            sd_valid <= 1'b0; sd_end <= 1'b0;
        end
        else begin
            sd_end <= 1'b0;
            if (fin) begin
                fin      <= 1'b0;
                sd_end   <= 1'b1;
                sd_valid <= 1'b0;
            end
            else if (!xfer) begin
                sd_valid <= 1'b0;
                if (sd_read) begin
                    xfer  <= 1'b1;
                    xcnt  <= 0;
                    xaddr <= sd_addr;
                end
            end
            else begin
                sd_valid <= 1'b1;
                sd_data  <= xaddr[7:0] + xcnt[7:0];
                xcnt     <= xcnt + 1;
                if (xcnt == LEN-1) begin
                    xfer <= 1'b0;
                    fin  <= 1'b1;
                end
            end
        end
    end

    /*=========================================================================
     * ch0 驱动：只要还有预算就背靠背地读；每个扇区之间空一拍（真实状态机
     * 也有这一拍）。正是这一拍让 ch1 看见 ready 并把请求锁进 wav_pend。
     *=======================================================================*/
    reg     ch0_go     = 1'b0;
    reg     ch0_wait   = 1'b0;
    integer ch0_budget = 0;

    always @(posedge clk) begin
        if (rst) begin
            ch0_read <= 1'b0;
            ch0_wait <= 1'b0;
        end
        else begin
            ch0_read <= 1'b0;
            if (ch0_wait && ch0_end)
                ch0_wait <= 1'b0;
            else if (!ch0_go)
                ch0_wait <= 1'b0;
            else if (ch0_budget > 0 && !ch0_wait && ch0_ready) begin
                ch0_read   <= 1'b1;
                ch0_wait   <= 1'b1;
                ch0_budget <= ch0_budget - 1;
            end
        end
    end

    /*=========================================================================
     * ch1 驱动：与 wav_reader 一致 —— 看见 ready 就把 read 拉起来，并且
     * **一直保持到 end**（S_SEC_REQ → S_RECV 的语义）。ch1_kill 拉高 = abort。
     *=======================================================================*/
    reg     ch1_busy = 1'b0;
    integer ch1_req_left = 0;       // 还允许发起几次请求（1 = 单发）
    reg     ch1_kill = 1'b0;        // 1 = 撤销（换页 abort）

    always @(posedge clk) begin
        if (rst) begin
            ch1_read <= 1'b0;
            ch1_busy <= 1'b0;
        end
        else if (ch1_kill) begin
            ch1_read <= 1'b0;          // 撤销：请求作废
            ch1_busy <= 1'b0;
        end
        else if (!ch1_busy) begin
            if (ch1_req_left > 0 && ch1_ready) begin
                ch1_read     <= 1'b1;
                ch1_busy     <= 1'b1;
                ch1_req_left <= ch1_req_left - 1;
            end
        end
        else if (ch1_end) begin
            ch1_read <= 1'b0;
            ch1_busy <= 1'b0;
        end
    end

    /* ---------------- 观测 ---------------- */
    integer ch1_done    = 0;      // ch1 收完 end 的次数
    integer ch1_xfer    = 0;      // 以上来的 ch1 地址发起的事务总数
    integer stale_cnt   = 0;      // abort 之后仍以 ch1 地址发起的事务（= bug）
    integer bmp_xfer    = 0;      // ch0 事务数（只用于打印）
    reg     abort_flag  = 1'b0;
    integer cyc         = 0;

    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (!rst && ch1_end)
            ch1_done <= ch1_done + 1;
        if (!rst && sd_read) begin
            if (sd_addr == A_WAV) begin
                ch1_xfer <= ch1_xfer + 1;
                if (abort_flag)
                    stale_cnt <= stale_cnt + 1;
            end
            else if (sd_addr == A_BMP)
                bmp_xfer <= bmp_xfer + 1;
        end
    end

    integer errors = 0;
    integer t0     = 0;
    integer mark   = 0;

    initial begin
        rst = 1'b1;
        repeat (8) @(posedge clk);
        rst = 1'b0;
        repeat (8) @(posedge clk);

        /* ---------------- P1：ch1 独占，恰好一次事务 ---------------- */
        mark = ch1_xfer;
        ch1_req_left = 1;
        t0 = 0;
        while (ch1_done < 1 && t0 < 200) begin @(posedge clk); t0 = t0 + 1; end
        repeat (16) @(posedge clk);
        if (ch1_done != 1) begin
            errors = errors + 1;
            $display("FAIL P1: ch1 exclusive request not served");
        end
        else if (ch1_xfer - mark != 1) begin
            errors = errors + 1;
            $display("FAIL P1: one request caused %0d sector reads (expect 1)", ch1_xfer - mark);
        end
        else
            $display("[ ok ] P1 ch1 exclusive: 1 request -> 1 sector read");

        /* ---------------- P2：BMP 占线，pending 必须被吸收并补发 ---------------- */
        ch0_budget = 8;
        ch0_go     = 1'b1;
        t0 = 0;
        while (dut.owner != 2'd1 && t0 < 200) begin @(posedge clk); t0 = t0 + 1; end
        if (dut.owner != 2'd1) begin
            errors = errors + 1;
            $display("FAIL P2: BMP never got the bus");
        end

        ch1_req_left = 1;
        t0 = 0;
        while (!(dut.wav_pend === 1'b1) && t0 < 800) begin @(posedge clk); t0 = t0 + 1; end
        if (dut.wav_pend !== 1'b1) begin
            errors = errors + 1;
            $display("FAIL P2: ch1 request was not absorbed while BMP owned the bus");
        end

        ch0_budget = 0;                       // 本轮读完就停，让出总线
        t0 = 0;
        while (ch1_done < 2 && t0 < 800) begin @(posedge clk); t0 = t0 + 1; end
        if (ch1_done != 2) begin
            errors = errors + 1;
            $display("FAIL P2: pending request was not replayed after BMP released the bus");
        end
        else
            $display("[ ok ] P2 BMP blocked ch1, pending replayed once after release");

        /* ---------------- P3：挂起期间撤销，旧地址不得补发 ---------------- */
        ch1_kill = 1'b1;
        repeat (24) @(posedge clk);
        ch1_kill = 1'b0;
        ch0_budget = 10;
        ch0_go     = 1'b1;
        t0 = 0;
        while (dut.owner != 2'd1 && t0 < 200) begin @(posedge clk); t0 = t0 + 1; end

        ch1_req_left = 1;
        t0 = 0;
        while (!(dut.wav_pend === 1'b1) && t0 < 800) begin @(posedge clk); t0 = t0 + 1; end
        if (dut.wav_pend !== 1'b1) begin
            errors = errors + 1;
            $display("FAIL P3: could not set up a pending request");
        end

        mark       = ch1_xfer;
        abort_flag = 1'b1;
        ch1_kill   = 1'b1;                    // 换页 abort：请求撤销
        repeat (4) @(posedge clk);
        ch1_kill   = 1'b0;
        ch0_budget = 4;                       // 让 BMP 再多读几个扇区再走

        t0 = 0;
        while (dut.owner != 2'd0 && t0 < 800) begin @(posedge clk); t0 = t0 + 1; end
        repeat (200) @(posedge clk);          // 留足时间给"补发"发生

        if (stale_cnt != 0) begin
            errors = errors + 1;
            $display("FAIL P3: aborted request was replayed %0d time(s) with stale address 0x%08x",
                     stale_cnt, A_WAV);
        end
        else if (ch1_xfer != mark) begin
            errors = errors + 1;
            $display("FAIL P3: %0d stale sector read(s) after abort", ch1_xfer - mark);
        end
        else
            $display("[ ok ] P3 abort dropped the pending request, no stale sector read");

        abort_flag = 1'b0;

        /* ---------------- P4：撤销后重新请求，仍能被服务 ---------------- */
        repeat (24) @(posedge clk);
        mark = ch1_done;
        ch1_req_left = 1;
        t0 = 0;
        while (ch1_done < mark + 1 && t0 < 800) begin @(posedge clk); t0 = t0 + 1; end
        if (ch1_done != mark + 1) begin
            errors = errors + 1;
            $display("FAIL P4: ch1 starved after abort");
        end
        else
            $display("[ ok ] P4 ch1 served again after abort");

        /* ---------------- 汇总 ---------------- */
        $display("       sectors: ch1=%0d ch0=%0d stale=%0d cycles=%0d",
                 ch1_xfer, bmp_xfer, stale_cnt, cyc);
        if (errors == 0)
            $display("PASS: sd_sec_arbiter_abort");
        else
            $display("FAIL: sd_sec_arbiter_abort (%0d errors)", errors);
        $finish;
    end

endmodule
