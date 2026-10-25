


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

// Keep this frequency consistent with sys_pll.ipc and sys_pll.v.
// At 40 MHz, the 180-degree SDRAM phase gives 12.5 ns in each direction.
`define   SDR_CLK_FREQ_HZ                40000000
`define   SDR_CLK_PERIOD                 (1000000000 / `SDR_CLK_FREQ_HZ)
// Budget 60 ms of the 64 ms retention limit, leaving controller/clock margin.
// The counter includes zero, so its terminal value is the cycle count minus 1.
// Parenthesize the entire expression: the old nested division expanded to 0.
`define   SELF_REFRESH_INTERVAL          ((((`SDR_CLK_FREQ_HZ / 1000) * 60) / (1 << `ROW_WIDTH)) - 1)

