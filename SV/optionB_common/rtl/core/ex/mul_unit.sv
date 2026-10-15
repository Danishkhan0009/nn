//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/ex/mul_unit.sv
// Module    : mul_unit
// Content   : 3-stage pipelined multiplier. op: 00 MUL, 01 MULH, 10 MULHSU, 11 MULHU. Stage 1 latches the sign-extended operands, stage 2 forms the 64-bit product, stage 3 selects the half; done = 1 three cycles after start. Outputs isolated (clamp 0).
// Hierarchy : fido_top > u_core > u_ex > u_mul
// Power leaf: MUL (clock net MUL, PD_MUL in PG FINE)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module mul_unit (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        pd_on,
  input  wire        pd_ret,
  input  wire        pd_init,
  input  wire        iso,
  input  wire        start,
  input  wire  [1:0] op,
  input  wire [31:0] a,
  input  wire [31:0] b,
  output logic        busy,
  output logic        done,
  output logic [31:0] res,
  output logic        we
);
  // state = {v1, a1[32:0], b1[32:0], op1[1:0], v2, p2[63:0], op2[1:0], v3, r3[31:0]}
  wire        v1;
  wire [32:0] a1;
  wire [32:0] b1;
  wire [1:0]  op1;
  wire        v2;
  wire [63:0] p2;
  wire [1:0]  op2;
  wire        v3;
  wire [31:0] r3;

  logic               a_sgn;
  logic               b_sgn;
  logic signed [65:0] prod;
  logic               n_v1;
  logic [32:0]        n_a1;
  logic [32:0]        n_b1;
  logic [1:0]         n_op1;
  logic               n_v2;
  logic [63:0]        n_p2;
  logic [1:0]         n_op2;
  logic               n_v3;
  logic [31:0]        n_r3;
  logic               en;

  assign a_sgn = (op == 2'b01) || (op == 2'b10);
  assign b_sgn = (op == 2'b01);
  assign prod  = $signed(a1) * $signed(b1);

  assign n_v1  = start;
  assign n_a1  = start ? {a_sgn & a[31], a} : a1;
  assign n_b1  = start ? {b_sgn & b[31], b} : b1;
  assign n_op1 = start ? op : op1;
  assign n_v2  = v1;
  assign n_p2  = v1 ? prod[63:0] : p2;
  assign n_op2 = v1 ? op1 : op2;
  assign n_v3  = v2;
  assign n_r3  = v2 ? ((op2 == 2'b00) ? p2[31:0] : p2[63:32]) : r3;
  assign en    = start | v1 | v2 | v3;

  pg_dff #(.W(169)) u_state (
    .clk     (clk),
    .rst_n   (rst_n),
    .pd_on   (pd_on),
    .pd_ret  (pd_ret),
    .pd_init (pd_init),
    .en      (en),
    .d       ({n_v1, n_a1, n_b1, n_op1, n_v2, n_p2, n_op2, n_v3, n_r3}),
    .q       ({v1, a1, b1, op1, v2, p2, op2, v3, r3})
  );

  // isolation cells on the MUL boundary
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_busy (.iso(iso), .d((v1 | v2 | v3)), .q(busy));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_done (.iso(iso), .d(v3), .q(done));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_res (.iso(iso), .d(r3), .q(res));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_we (.iso(iso), .d(en), .q(we));
endmodule : mul_unit

`default_nettype wire
