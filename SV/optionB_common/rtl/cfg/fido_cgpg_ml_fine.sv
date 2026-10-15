//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL, configuration top
// File      : rtl/cfg/fido_cgpg_ml_fine.sv
// Module    : fido_cgpg_ml_fine
// Content   : Clock + power gating + ML, fine grain (15 clock + 8 power domains)
//             Thin configuration wrapper around the shared RTL
//             (fido_top, MODE=4 MODE_CGPG_ML, GRAIN=0 GRAIN_FINE).
// Hierarchy : fido_cgpg_ml_fine > u_top (fido_top)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module fido_cgpg_ml_fine
  import fido_pkg::*;
#(
  parameter int THR_CG   = 8,
  parameter int THR_PG   = 16,
  parameter int WAKE_PG  = 4,
  parameter int BE       = 8,
  parameter int HYST     = 8,
  parameter int BANK_MAP = 0
) (
  input  wire          clk,
  input  wire          rst_n,
  input  wire          prog_we,
  input  wire   [9:0]  prog_addr,
  input  wire  [31:0]  prog_data,
  input  wire   [3:0]  ev_valid,
  input  wire  [31:0]  ev_data,
  input  wire   [1:0]  ml_force,
  output logic         tohost_we,
  output logic [31:0]  tohost_data,
  output logic         wfi_sleep,
  output logic         rvfi_valid,
  output logic [31:0]  rvfi_pc,
  output logic [31:0]  rvfi_insn,
  output logic  [4:0]  rvfi_rd,
  output logic [31:0]  rvfi_wdata,
  output logic         rvfi_mem_we,
  output logic [31:0]  rvfi_mem_addr,
  output logic [31:0]  rvfi_mem_wdata,
  output logic  [3:0]  rvfi_mem_strb,
  output logic [95:0]  pm_state_bus,
  output logic [31:0]  dom_clk_en,
  output logic [31:0]  dom_iso,
  output logic [31:0]  dom_ret,
  output logic [31:0]  dom_pwr,
  output logic [31:0]  dom_ack,
  output logic [31:0]  dom_busy,
  output logic [31:0]  dom_ready,
  output logic [31:0]  dom_mispred,
  output logic         trap_win,
  output logic         pg_stall,
  output logic [255:0] ml_feat
);
  fido_top #(
    .MODE     (MODE_CGPG_ML),
    .GRAIN    (GRAIN_FINE),
    .THR_CG   (THR_CG),
    .THR_PG   (THR_PG),
    .WAKE_PG  (WAKE_PG),
    .BE       (BE),
    .HYST     (HYST),
    .BANK_MAP (BANK_MAP)
  ) u_top (
    .clk            (clk),
    .rst_n          (rst_n),
    .prog_we        (prog_we),
    .prog_addr      (prog_addr),
    .prog_data      (prog_data),
    .ev_valid       (ev_valid),
    .ev_data        (ev_data),
    .ml_force       (ml_force),
    .tohost_we      (tohost_we),
    .tohost_data    (tohost_data),
    .wfi_sleep      (wfi_sleep),
    .rvfi_valid     (rvfi_valid),
    .rvfi_pc        (rvfi_pc),
    .rvfi_insn      (rvfi_insn),
    .rvfi_rd        (rvfi_rd),
    .rvfi_wdata     (rvfi_wdata),
    .rvfi_mem_we    (rvfi_mem_we),
    .rvfi_mem_addr  (rvfi_mem_addr),
    .rvfi_mem_wdata (rvfi_mem_wdata),
    .rvfi_mem_strb  (rvfi_mem_strb),
    .pm_state_bus   (pm_state_bus),
    .dom_clk_en     (dom_clk_en),
    .dom_iso        (dom_iso),
    .dom_ret        (dom_ret),
    .dom_pwr        (dom_pwr),
    .dom_ack        (dom_ack),
    .dom_busy       (dom_busy),
    .dom_ready      (dom_ready),
    .dom_mispred    (dom_mispred),
    .trap_win       (trap_win),
    .pg_stall       (pg_stall),
    .ml_feat        (ml_feat)
  );
endmodule : fido_cgpg_ml_fine

`default_nettype wire
