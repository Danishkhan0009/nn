//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/ex/mdu_ctrl.sv
// Module    : mdu_ctrl
// Content   : MUL/DIV sequencing in EX: start pulse, result capture, started/finished flags (clock net IDEX), EX stall while the M-unit works
// Hierarchy : fido_top > u_core > u_ex > u_mdu
// Power leaf: EX (clock net IDEX)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module mdu_ctrl (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        pd_on,
  input  wire        pd_ret,
  input  wire        pd_init,
  input  wire        q_vld,         // ID/EX holds a valid instruction
  input  wire        is_mul,
  input  wire        is_div,
  input  wire        take_trap,
  input  wire        ex_adv,
  input  wire        mul_done,
  input  wire [31:0] mul_res,
  input  wire        div_done,
  input  wire [31:0] div_res,
  output logic        start_mdu,
  output logic        mdu_started,
  output logic        flags_en,
  output logic [31:0] mdu_out,
  output logic        stall
);
  wire  [31:0] mdu_res_q;
  wire         started_q;
  wire         fin_q;
  logic        is_mdu;
  logic        mdu_done;
  logic [31:0] mdu_ures;
  logic        cap;
  logic        n_started;
  logic        n_fin;

  assign is_mdu    = is_mul | is_div;
  assign start_mdu = q_vld && is_mdu && !started_q && !fin_q && !take_trap;
  assign mdu_done  = is_mul ? mul_done : div_done;
  assign mdu_ures  = is_mul ? mul_res : div_res;
  assign cap       = q_vld && is_mdu && started_q && mdu_done && !fin_q;
  assign flags_en  = ex_adv | start_mdu | cap;
  assign n_started = ex_adv ? 1'b0 : (start_mdu ? 1'b1 : started_q);
  assign n_fin     = ex_adv ? 1'b0 : (cap ? 1'b1 : fin_q);

  pg_dff #(.W(2)) u_flags (
    .clk     (clk),
    .rst_n   (rst_n),
    .pd_on   (pd_on),
    .pd_ret  (pd_ret),
    .pd_init (pd_init),
    .en      (flags_en),
    .d       ({n_started, n_fin}),
    .q       ({started_q, fin_q})
  );

  pg_dff #(.W(32)) u_res (
    .clk     (clk),
    .rst_n   (rst_n),
    .pd_on   (pd_on),
    .pd_ret  (pd_ret),
    .pd_init (pd_init),
    .en      (cap),
    .d       (mdu_ures),
    .q       (mdu_res_q)
  );

  assign mdu_started = started_q;
  assign mdu_out     = fin_q ? mdu_res_q : mdu_ures;
  assign stall       = q_vld && is_mdu && !fin_q && !cap && !take_trap;
endmodule : mdu_ctrl

`default_nettype wire
