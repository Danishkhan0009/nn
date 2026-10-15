//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/ex/alu_cmp.sv
// Module    : alu_cmp
// Content   : comparator: SLT/SLTU result and branch condition; own operand registers (clock net CMP)
// Hierarchy : fido_top > u_core > u_ex > u_cmp
// Power leaf: EX (clock net CMP)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module alu_cmp (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        pd_on,
  input  wire        pd_ret,
  input  wire        pd_init,
  input  wire        we,
  input  wire [31:0] a_d,
  input  wire [31:0] b_d,
  input  wire        a_fwd,
  input  wire [31:0] a_fwd_val,
  input  wire        b_fwd,
  input  wire [31:0] b_fwd_val,
  input  wire  [2:0] f3,
  output logic        slt_bit,
  output logic        br_cond
);
  wire  [31:0] a_q;
  wire  [31:0] b_q;
  logic [31:0] a;
  logic [31:0] b;
  logic        c_eq;
  logic        c_lt;
  logic        c_ltu;

  pg_dff #(.W(64)) u_ops (
    .clk     (clk),
    .rst_n   (rst_n),
    .pd_on   (pd_on),
    .pd_ret  (pd_ret),
    .pd_init (pd_init),
    .en      (we),
    .d       ({a_d, b_d}),
    .q       ({a_q, b_q})
  );

  assign a       = a_fwd ? a_fwd_val : a_q;
  assign b       = b_fwd ? b_fwd_val : b_q;
  assign c_eq    = (a == b);
  assign c_lt    = ($signed(a) < $signed(b));
  assign c_ltu   = (a < b);
  assign slt_bit = (f3 == 3'b011) ? c_ltu : c_lt;

  always_comb begin
    case (f3)
      3'b000:  br_cond = c_eq;
      3'b001:  br_cond = ~c_eq;
      3'b100:  br_cond = c_lt;
      3'b101:  br_cond = ~c_lt;
      3'b110:  br_cond = c_ltu;
      3'b111:  br_cond = ~c_ltu;
      default: br_cond = 1'b0;
    endcase
  end
endmodule : alu_cmp

`default_nettype wire
