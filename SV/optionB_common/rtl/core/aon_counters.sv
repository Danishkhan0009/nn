//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/aon_counters.sv
// Module    : aon_counters
// Content   : always-on performance counters mcycle / minstret (read by the
//             CSR unit; they keep counting while the core is gated).
// Hierarchy : fido_top > u_cnt
// Power leaf: always on (raw clock)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module aon_counters (
  input  wire         clk,
  input  wire         rst_n,
  input  wire         retire,
  output logic [31:0] mcycle,
  output logic [31:0] minstret
);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mcycle   <= 32'd0;
      minstret <= 32'd0;
    end else begin
      mcycle <= mcycle + 32'd1;
      if (retire) minstret <= minstret + 32'd1;
    end
  end
endmodule : aon_counters

`default_nettype wire
