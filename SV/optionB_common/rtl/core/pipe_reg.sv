//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/pipe_reg.sv
// Module    : pipe_reg
// Content   : generic pipeline stage register: valid flop + data flops (pg_dff, X while powered off); separate enables for valid and data
// Hierarchy : used for IF/ID (if_stage), ID/EX (ex_stage), EX/MEM (mem_stage), MEM/WB (wb_stage)
// Power leaf: the leaf of its stage
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module pipe_reg #(
  parameter int unsigned W = 32
) (
  input  wire          clk,
  input  wire          rst_n,
  input  wire          pd_on,
  input  wire          pd_ret,
  input  wire          pd_init,
  input  wire          vld_en,
  input  wire          vld_d,
  input  wire          data_en,
  input  wire  [W-1:0] d,
  output logic         vld_q,
  output logic [W-1:0] q
);
  pg_dff #(.W(1)) u_vld (
    .clk     (clk),
    .rst_n   (rst_n),
    .pd_on   (pd_on),
    .pd_ret  (pd_ret),
    .pd_init (pd_init),
    .en      (vld_en),
    .d       (vld_d),
    .q       (vld_q)
  );

  pg_dff #(.W(W)) u_data (
    .clk     (clk),
    .rst_n   (rst_n),
    .pd_on   (pd_on),
    .pd_ret  (pd_ret),
    .pd_init (pd_init),
    .en      (data_en),
    .d       (d),
    .q       (q)
  );
endmodule : pipe_reg

`default_nettype wire
