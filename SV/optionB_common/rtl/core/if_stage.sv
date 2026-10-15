//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/if_stage.sv
// Module    : if_stage
// Content   : IF stage: PC (retention flop) and the IF/ID register; fetch stops while the core sleeps in WFI
// Hierarchy : fido_top > u_core (rv32im_core) > u_if
// Power leaf: CORE (clock net CORE)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module if_stage (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        pd_on,
  input  wire        pd_ret,
  input  wire        pd_init,
  input  wire        flush,          // redirect from EX (branch, jump, trap, mret, wfi)
  input  wire [31:0] flush_target,
  input  wire        id_issue,       // IF/ID content moves to ID/EX this cycle
  input  wire        wfi_flag,       // core asleep: no fetch
  input  wire [31:0] imem_rdata,
  output logic [31:0] pc,
  output logic        ifid_vld,
  output logic [31:0] ifid_pc,
  output logic [31:0] ifid_insn,
  output logic        we             // any IF register written (clock-gating busy)
);
  logic        fetch_ok;
  logic        ifid_free;
  logic        pc_en;
  logic [31:0] pc_d;
  logic        ifid_vld_en;
  logic        ifid_vld_d;
  logic        ifid_data_en;

  assign fetch_ok     = !wfi_flag;
  assign ifid_free    = !ifid_vld || id_issue;
  assign pc_en        = flush || (ifid_free && fetch_ok);
  assign pc_d         = flush ? flush_target : (pc + 32'd4);
  assign ifid_vld_en  = flush || (ifid_free && (fetch_ok || ifid_vld));
  assign ifid_vld_d   = !flush && fetch_ok;
  assign ifid_data_en = !flush && ifid_free && fetch_ok;

  pg_dff #(.W(32), .RV(32'd0), .RET(1)) u_pc (
    .clk     (clk),
    .rst_n   (rst_n),
    .pd_on   (pd_on),
    .pd_ret  (pd_ret),
    .pd_init (pd_init),
    .en      (pc_en),
    .d       (pc_d),
    .q       (pc)
  );

  pipe_reg #(.W(64)) u_ifid (
    .clk     (clk),
    .rst_n   (rst_n),
    .pd_on   (pd_on),
    .pd_ret  (pd_ret),
    .pd_init (pd_init),
    .vld_en  (ifid_vld_en),
    .vld_d   (ifid_vld_d),
    .data_en (ifid_data_en),
    .d       ({pc, imem_rdata}),
    .vld_q   (ifid_vld),
    .q       ({ifid_pc, ifid_insn})
  );

  assign we = pc_en || ifid_vld_en || ifid_data_en;
endmodule : if_stage

`default_nettype wire
