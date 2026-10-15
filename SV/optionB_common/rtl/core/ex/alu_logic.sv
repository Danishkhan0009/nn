//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/ex/alu_logic.sv
// Module    : alu_logic
// Content   : LOGIC (XOR/OR/AND) low 16-bit half: own operand registers (clock net LOGIC_LO)
// Hierarchy : fido_top > u_core > u_ex > u_logic
// Power leaf: EX (clock net LOGIC_LO)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module alu_logic (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        pd_on,
  input  wire        pd_ret,
  input  wire        pd_init,
  input  wire        we,
  input  wire [15:0] a_d,
  input  wire [15:0] b_d,
  input  wire        a_fwd,
  input  wire [15:0] a_fwd_val,
  input  wire        b_fwd,
  input  wire [15:0] b_fwd_val,
  input  wire  [2:0] f3,
  output logic [15:0] res_lo
);
  wire  [15:0] a_q;
  wire  [15:0] b_q;
  logic [15:0] a;
  logic [15:0] b;

  pg_dff #(.W(32)) u_ops (
    .clk     (clk),
    .rst_n   (rst_n),
    .pd_on   (pd_on),
    .pd_ret  (pd_ret),
    .pd_init (pd_init),
    .en      (we),
    .d       ({a_d, b_d}),
    .q       ({a_q, b_q})
  );

  assign a      = a_fwd ? a_fwd_val : a_q;
  assign b      = b_fwd ? b_fwd_val : b_q;
  assign res_lo = (f3 == 3'b100) ? (a ^ b) :
                  (f3 == 3'b110) ? (a | b) : (a & b);
endmodule : alu_logic

`default_nettype wire
