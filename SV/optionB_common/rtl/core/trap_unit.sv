//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/trap_unit.sv
// Module    : trap_unit
// Content   : trap entry / exit and WFI: interrupt take, exception / mret / WFI / branch flush and target, WFI sleep flag (retention flop), core-asleep and trap-window signals
// Hierarchy : fido_top > u_core (rv32im_core) > u_trap
// Power leaf: CORE (clock net CORE)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module trap_unit (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        pd_on,
  input  wire        pd_ret,
  input  wire        pd_init,
  // CSR state
  input  wire        st_mie,
  input  wire        mie_meie,
  input  wire [31:0] mtvec,
  input  wire [31:0] mepc,
  input  wire        evq_irq,
  // EX
  input  wire        ex_vld,
  input  wire        ex_exc,
  input  wire        ex_mret,
  input  wire        ex_wfi,
  input  wire        ex_redirect,
  input  wire [31:0] ex_target,
  input  wire [31:0] ex_pc,
  input  wire        ex_mdu_started,
  input  wire        ex_adv,
  // pipeline occupancy
  input  wire        ifid_vld,
  input  wire        exmem_vld,
  input  wire        memwb_vld,
  output logic        irq_take,
  output logic        trap,          // EX instruction traps (exception or interrupt)
  output logic        trap_en,       // trap taken this cycle
  output logic        mret_en,       // mret taken this cycle
  output logic        flush,
  output logic [31:0] flush_target,
  output logic        wfi_flag,
  output logic        wfi_en,        // WFI flag written
  output logic        sleep,         // core asleep: WFI and pipeline drained
  output logic        trap_win       // trap / mret in EX (no new gating)
);
  logic wake_cond;
  logic wfi_set;
  logic wfi_clr;

  assign irq_take  = st_mie && mie_meie && evq_irq && !ex_mdu_started;
  assign trap      = ex_vld && (ex_exc || irq_take);
  assign trap_en   = ex_adv && trap;
  assign mret_en   = ex_adv && ex_mret && !trap;
  assign wake_cond = mie_meie && evq_irq;
  assign wfi_set   = ex_adv && ex_wfi && !trap && !wake_cond;
  assign wfi_clr   = wfi_flag && wake_cond;
  assign wfi_en    = wfi_set || wfi_clr;
  assign flush     = ex_adv && (trap || ex_mret || ex_wfi || ex_redirect);

  assign flush_target = trap    ? {mtvec[31:2], 2'b00} :
                        ex_mret ? mepc :
                        ex_wfi  ? (ex_pc + 32'd4) : ex_target;

  pg_dff #(.W(1), .RV(1'b0), .RET(1)) u_wfi (
    .clk     (clk),
    .rst_n   (rst_n),
    .pd_on   (pd_on),
    .pd_ret  (pd_ret),
    .pd_init (pd_init),
    .en      (wfi_en),
    .d       (wfi_set),
    .q       (wfi_flag)
  );

  assign sleep    = wfi_flag && !ifid_vld && !ex_vld && !exmem_vld && !memwb_vld;
  assign trap_win = ex_vld && (trap || ex_mret);
endmodule : trap_unit

`default_nettype wire
