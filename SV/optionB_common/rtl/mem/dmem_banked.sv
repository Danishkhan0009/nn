//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/mem/dmem_banked.sv
// Module    : dmem_banked
// Content   : 4 KB data memory as 4 independent banks (one clock net and one
//             power leaf each). Bank select / interleave is done by the LSU
//             (mem_stage, parameter BANK_MAP).
// Hierarchy : fido_top > u_dmem
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module dmem_banked (
  input  wire   [3:0] clk_bank,
  input  wire         rst_n,
  input  wire   [3:0] pd_on,
  input  wire   [3:0] pd_ret,
  input  wire   [3:0] iso,
  input  wire   [7:0] idx,
  input  wire   [3:0] we,
  input  wire   [3:0] strb,
  input  wire  [31:0] wdata,
  output logic [127:0] rdata
);
  wire [127:0] rd;

  genvar b;
  for (b = 0; b < 4; b = b + 1) begin : g_bank
    dmem_bank u_bank (
      .clk    (clk_bank[b]),
      .rst_n  (rst_n),
      .pd_on  (pd_on[b]),
      .pd_ret (pd_ret[b]),
      .iso    (iso[b]),
      .idx    (idx),
      .we     (we[b]),
      .strb   (strb),
      .wdata  (wdata),
      .rdata  (rd[32*b +: 32])
    );
  end

  assign rdata = rd;
endmodule : dmem_banked

`default_nettype wire
