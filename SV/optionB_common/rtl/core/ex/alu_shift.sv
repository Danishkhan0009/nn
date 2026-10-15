//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/ex/alu_shift.sv
// Module    : alu_shift
// Content   : barrel shifter SLL/SRL/SRA: own operand registers (clock net SHIFT)
// Hierarchy : fido_top > u_core > u_ex > u_shift
// Power leaf: EX (clock net SHIFT)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module alu_shift (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        pd_on,
  input  wire        pd_ret,
  input  wire        pd_init,
  input  wire        we,
  input  wire [31:0] a_d,
  input  wire  [4:0] b_d,
  input  wire        a_fwd,
  input  wire [31:0] a_fwd_val,
  input  wire        b_fwd,
  input  wire  [4:0] b_fwd_val,
  input  wire  [2:0] f3,
  input  wire        sra,           // arithmetic right shift (SRA / SRAI)
  output logic [31:0] res
);
  wire  [31:0] a_q;
  wire  [4:0]  b_q;
  logic [31:0] a;
  logic [4:0]  b;
  logic [31:0] r_sra;

  pg_dff #(.W(37)) u_ops (
    .clk     (clk),
    .rst_n   (rst_n),
    .pd_on   (pd_on),
    .pd_ret  (pd_ret),
    .pd_init (pd_init),
    .en      (we),
    .d       ({a_d, b_d}),
    .q       ({a_q, b_q})
  );

  assign a     = a_fwd ? a_fwd_val : a_q;
  assign b     = b_fwd ? b_fwd_val : b_q;
  assign r_sra = $signed(a) >>> b;
  assign res   = (f3 == 3'b001) ? (a << b) :
                 sra            ? r_sra    : (a >> b);
endmodule : alu_shift

`default_nettype wire
