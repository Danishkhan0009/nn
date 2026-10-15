//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/mem/imem.sv
// Module    : imem
// Content   : 1024 x 32 instruction memory (always on), testbench load port,
//             asynchronous read; addresses above 4 KB read as 0.
// Hierarchy : fido_top > u_imem
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module imem (
  input  wire        clk,
  input  wire        we,
  input  wire  [9:0] waddr,
  input  wire [31:0] wdata,
  input  wire [31:0] addr,
  output logic [31:0] rdata
);
  logic [31:0] mem [1024];
  logic [31:0] word;

  always_ff @(posedge clk) begin
    if (we) mem[waddr] <= wdata;
  end

  assign word  = mem[addr[11:2]];
  assign rdata = (addr[31:12] == 20'd0) ? word : 32'd0;
endmodule : imem

`default_nettype wire
