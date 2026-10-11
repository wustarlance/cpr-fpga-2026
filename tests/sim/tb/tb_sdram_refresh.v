`timescale 1ns/1ps
`include "global_def.v"

// Regression for the refresh macro's nested-division precedence bug.
// Check physical time, not just a copied expected counter constant.
module tb_sdram_refresh;
    localparam integer TERMINAL_COUNT = `SELF_REFRESH_INTERVAL;
    localparam integer INTERVAL_CYCLES = TERMINAL_COUNT + 1;
    localparam real ROW_DEADLINE_NS = 64000000.0 / (1 << `ROW_WIDTH);
    localparam real REQUEST_BUDGET_NS = 60000000.0 / (1 << `ROW_WIDTH);
    localparam real INTERVAL_NS = INTERVAL_CYCLES * 1000000000.0 / `SDR_CLK_FREQ_HZ;

    initial begin
        if (TERMINAL_COUNT <= 10 || TERMINAL_COUNT >= (1 << 14))
            $fatal(1, "[FAIL] refresh counter cannot reach valid request/ack windows");
        if (INTERVAL_NS > ROW_DEADLINE_NS)
            $fatal(1, "[FAIL] refresh interval exceeds the 64 ms / row deadline");
        if (INTERVAL_NS > REQUEST_BUDGET_NS ||
            REQUEST_BUDGET_NS - INTERVAL_NS > 1000000000.0 / `SDR_CLK_FREQ_HZ)
            $fatal(1, "[FAIL] refresh interval is incorrectly rounded or scaled");
        $display("[PASS] %0d cycles = %0.3f ns; deadline %0.3f ns",
                 INTERVAL_CYCLES, INTERVAL_NS, ROW_DEADLINE_NS);
        $finish;
    end
endmodule
