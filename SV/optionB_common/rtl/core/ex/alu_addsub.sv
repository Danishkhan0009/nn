//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/ex/alu_addsub.sv
// Module    : alu_addsub
// Content   : ADD/SUB low 16-bit half: own operand registers (clock net ADD_LO), forwarding select, adder; carry out goes to the high half in alu_hi_unit
// Hierarchy : fido_top > u_core > u_ex > u_addsub
// Power leaf: EX (clock net ADD_LO)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module alu_addsub (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        pd_on,
  input  wire        pd_ret,
  input  wire        pd_init,
  input  wire        we,            // load operand registers (instruction issued to ADD)
  input  wire [15:0] a_d,
  input  wire [15:0] b_d,
  input  wire        a_fwd,
  input  wire [15:0] a_fwd_val,
  input  wire        b_fwd,
  input  wire [15:0] b_fwd_val,
  input  wire        sub,
  output logic [16:0] sum_lo        // {carry, sum[15:0]}
);
  wire  [15:0] a_q;
  wire  [15:0] b_q;
  logic [15:0] a;
  logic [15:0] b;
  logic [15:0] bx;

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
  assign bx     = sub ? ~b : b;
  assign sum_lo = {1'b0, a} + {1'b0, bx} + {16'd0, sub};
endmodule : alu_addsub

`default_nettype wire
