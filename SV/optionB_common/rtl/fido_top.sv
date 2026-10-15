//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL, shared by SYRAX (P1) and CARAXES (P2)
// File      : rtl/fido_top.sv
// Module    : fido_top
// Content   : one RTL, configured by parameters
//               MODE  : 0 BASE, 1 CG, 2 PG, 3 CG+PG, 4 CG+PG+ML  (fido_pkg MODE_*)
//               GRAIN : 0 FINE, 1 COARSE
//             core + memories + event queue + PMU + gating fabric
//
//   fido_top
//   |-- u_imem   imem           instruction memory (always on)
//   |-- u_core   rv32im_core    5-stage RV32IM core (CORE, EX, ALU_HI, MUL, DIV, RF_HI leaves)
//   |-- u_dmem   dmem_banked    4 data-memory banks (BANK0..3 leaves)
//   |-- u_evq    event_queue    peripheral event queue (always on)
//   |-- u_cnt    aon_counters   mcycle / minstret (always on)
//   |-- u_sense  pm_sense       busy / demand per clock net
//   `-- u_pmu    pmu_top        domain controllers, ML policy, ICGs (always on)
//
//   Project innovations (SYRAX / CARAXES) and UPF are not part of the shared
//   code (README section 11).
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module fido_top
  import fido_pkg::*;
#(
  parameter int MODE     = MODE_BASE,  // 0 BASE, 1 CG, 2 PG, 3 CG+PG, 4 CG+PG+ML
  parameter int GRAIN    = GRAIN_FINE, // 0 FINE, 1 COARSE
  parameter int THR_CG   = 8,          // idle cycles before clock gating
  parameter int THR_PG   = 16,         // idle cycles before power gating
  parameter int WAKE_PG  = 4,          // power-switch settle cycles
  parameter int BE       = 8,          // break-even: wake earlier than this = mispredict
  parameter int HYST     = 8,          // lock-ON cycles after a mispredict
  parameter int BANK_MAP = 0           // 0 address range, 1 word interleave
) (
  input  wire          clk,
  input  wire          rst_n,
  // instruction-memory load port (testbench)
  input  wire          prog_we,
  input  wire   [9:0]  prog_addr,
  input  wire  [31:0]  prog_data,
  // peripheral events (testbench models), 4 sources x 8 bit
  input  wire   [3:0]  ev_valid,
  input  wire  [31:0]  ev_data,
  // ML test hook (MODE 4 only, tie to 0 otherwise):
  //   0 model decides, 1 force confident power-gate requests,
  //   2 force confidence 0, 3 reactive policy (training-trace mode)
  input  wire   [1:0]  ml_force,
  // status
  output logic         tohost_we,
  output logic [31:0]  tohost_data,
  output logic         wfi_sleep,
  // retirement trace
  output logic         rvfi_valid,
  output logic [31:0]  rvfi_pc,
  output logic [31:0]  rvfi_insn,
  output logic  [4:0]  rvfi_rd,
  output logic [31:0]  rvfi_wdata,
  output logic         rvfi_mem_we,
  output logic [31:0]  rvfi_mem_addr,
  output logic [31:0]  rvfi_mem_wdata,
  output logic  [3:0]  rvfi_mem_strb,
  // power-management observation (32 domain slots, unused slots read ON)
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
  // ML feature vectors of the power domains, 8 slots x 32 bit (MODE 4, else 0)
  output logic [255:0] ml_feat
);
  //------------------------------------------------------------ gating fabric
  wire [17:0]  gclk_cn;
  wire [17:0]  rdy_cn;
  wire [17:0]  on_cn;
  wire [17:0]  ret_cn;
  wire [17:0]  init_cn;
  wire [17:0]  iso_cn;
  wire [17:0]  cn_we;
  wire [17:0]  cn_dem;
  wire  [2:0]  occ;

  //------------------------------------------------------------ core <-> units
  wire [31:0]  imem_rdata;
  wire [31:0]  imem_addr;
  wire  [7:0]  dm_idx;
  wire  [3:0]  dm_we;
  wire  [3:0]  dm_strb;
  wire [31:0]  dm_wdata;
  wire [127:0] dm_rdata;
  wire         evq_pop;
  wire         evq_cfg_we;
  wire  [3:0]  evq_cfg_wdata;
  wire  [3:0]  evq_count;
  wire  [9:0]  evq_head;
  wire         evq_ovf;
  wire         evq_irq;
  wire         evq_busy;
  wire [31:0]  mcycle;
  wire [31:0]  minstret;

  //------------------------------------------------------------ PMU sensing
  wire         we_add;
  wire         we_logic;
  wire         we_shift;
  wire         we_cmp;
  wire         we_mul;
  wire         we_div;
  wire         we_idex;
  wire         we_core;
  wire         we_exmem;
  wire         we_memwb;
  wire         rfh_we;
  wire  [3:0]  bank_dem;
  wire         rfh_dem;
  wire         id_vld;
  wire  [2:0]  id_unit;
  wire         ex_vld;
  wire  [2:0]  ex_unit;
  wire         mul_busy;
  wire         div_busy;
  wire         exmem_vld;
  wire         memwb_vld;

  //------------------------------------------------------------ instruction memory
  imem u_imem (
    .clk   (clk),
    .we    (prog_we),
    .waddr (prog_addr),
    .wdata (prog_data),
    .addr  (imem_addr),
    .rdata (imem_rdata)
  );

  //------------------------------------------------------------ core
  rv32im_core #(.BANK_MAP(BANK_MAP)) u_core (
    .gclk_cn       (gclk_cn),
    .rst_n         (rst_n),
    .on_cn         (on_cn),
    .ret_cn        (ret_cn),
    .init_cn       (init_cn),
    .iso_cn        (iso_cn),
    .rdy_cn        (rdy_cn),
    .imem_rdata    (imem_rdata),
    .imem_addr     (imem_addr),
    .dm_idx        (dm_idx),
    .dm_we         (dm_we),
    .dm_strb       (dm_strb),
    .dm_wdata      (dm_wdata),
    .dm_rdata      (dm_rdata),
    .evq_pop       (evq_pop),
    .evq_cfg_we    (evq_cfg_we),
    .evq_cfg_wdata (evq_cfg_wdata),
    .evq_count     (evq_count),
    .evq_head      (evq_head),
    .evq_ovf       (evq_ovf),
    .evq_irq       (evq_irq),
    .mcycle        (mcycle),
    .minstret      (minstret),
    .rv_valid      (rvfi_valid),
    .rv_pc         (rvfi_pc),
    .rv_insn       (rvfi_insn),
    .rv_rd         (rvfi_rd),
    .rv_wdata      (rvfi_wdata),
    .rv_mem_we     (rvfi_mem_we),
    .rv_mem_addr   (rvfi_mem_addr),
    .rv_mem_wdata  (rvfi_mem_wdata),
    .rv_mem_strb   (rvfi_mem_strb),
    .tohost_we     (tohost_we),
    .tohost_data   (tohost_data),
    .we_add        (we_add),
    .we_logic      (we_logic),
    .we_shift      (we_shift),
    .we_cmp        (we_cmp),
    .we_mul        (we_mul),
    .we_div        (we_div),
    .we_idex       (we_idex),
    .we_core       (we_core),
    .we_exmem      (we_exmem),
    .we_memwb      (we_memwb),
    .rfh_we        (rfh_we),
    .bank_dem      (bank_dem),
    .rfh_dem       (rfh_dem),
    .id_vld_o      (id_vld),
    .id_unit_o     (id_unit),
    .ex_vld_o      (ex_vld),
    .ex_unit_o     (ex_unit),
    .mul_busy      (mul_busy),
    .div_busy      (div_busy),
    .exmem_vld_o   (exmem_vld),
    .memwb_vld_o   (memwb_vld),
    .wfi_sleep     (wfi_sleep),
    .trap_win      (trap_win),
    .pg_stall      (pg_stall)
  );

  //------------------------------------------------------------ data memory
  dmem_banked u_dmem (
    .clk_bank (gclk_cn[CN_BANK3:CN_BANK0]),
    .rst_n    (rst_n),
    .pd_on    (on_cn[CN_BANK3:CN_BANK0]),
    .pd_ret   (ret_cn[CN_BANK3:CN_BANK0]),
    .iso      (iso_cn[CN_BANK3:CN_BANK0]),
    .idx      (dm_idx),
    .we       (dm_we),
    .strb     (dm_strb),
    .wdata    (dm_wdata),
    .rdata    (dm_rdata)
  );

  //------------------------------------------------------------ event queue
  event_queue u_evq (
    .clk       (gclk_cn[CN_EVQ]),
    .rst_n     (rst_n),
    .ev_valid  (ev_valid),
    .ev_data   (ev_data),
    .pop       (evq_pop),
    .cfg_we    (evq_cfg_we),
    .cfg_wdata (evq_cfg_wdata),
    .count     (evq_count),
    .head      (evq_head),
    .ovf       (evq_ovf),
    .irq       (evq_irq),
    .busy      (evq_busy)
  );

  //------------------------------------------------------------ always-on counters
  aon_counters u_cnt (
    .clk      (clk),
    .rst_n    (rst_n),
    .retire   (rvfi_valid),
    .mcycle   (mcycle),
    .minstret (minstret)
  );

  //------------------------------------------------------------ activity sensing
  pm_sense u_sense (
    .we_add    (we_add),
    .we_logic  (we_logic),
    .we_shift  (we_shift),
    .we_cmp    (we_cmp),
    .we_mul    (we_mul),
    .we_div    (we_div),
    .we_idex   (we_idex),
    .we_exmem  (we_exmem),
    .we_memwb  (we_memwb),
    .dm_we     (dm_we),
    .rfh_we    (rfh_we),
    .evq_busy  (evq_busy),
    .we_core   (we_core),
    .id_vld    (id_vld),
    .id_unit   (id_unit),
    .ex_vld    (ex_vld),
    .ex_unit   (ex_unit),
    .mul_busy  (mul_busy),
    .div_busy  (div_busy),
    .exmem_vld (exmem_vld),
    .memwb_vld (memwb_vld),
    .bank_dem  (bank_dem),
    .rfh_dem   (rfh_dem),
    .wfi_sleep (wfi_sleep),
    .evq_irq   (evq_irq),
    .cn_we     (cn_we),
    .cn_dem    (cn_dem),
    .occ       (occ)
  );

  //------------------------------------------------------------ PMU + gating fabric
  pmu_top #(
    .MODE    (MODE),
    .GRAIN   (GRAIN),
    .THR_CG  (THR_CG),
    .THR_PG  (THR_PG),
    .WAKE_PG (WAKE_PG),
    .BE      (BE),
    .HYST    (HYST)
  ) u_pmu (
    .clk          (clk),
    .rst_n        (rst_n),
    .cn_we        (cn_we),
    .cn_dem       (cn_dem),
    .trap_win     (trap_win),
    .wfi_sleep    (wfi_sleep),
    .occ          (occ),
    .evq_count    (evq_count),
    .ml_force     (ml_force),
    .gclk_cn      (gclk_cn),
    .rdy_cn       (rdy_cn),
    .on_cn        (on_cn),
    .ret_cn       (ret_cn),
    .init_cn      (init_cn),
    .iso_cn       (iso_cn),
    .pm_state_bus (pm_state_bus),
    .dom_clk_en   (dom_clk_en),
    .dom_iso      (dom_iso),
    .dom_ret      (dom_ret),
    .dom_pwr      (dom_pwr),
    .dom_ack      (dom_ack),
    .dom_busy     (dom_busy),
    .dom_ready    (dom_ready),
    .dom_mispred  (dom_mispred),
    .ml_feat      (ml_feat)
  );
endmodule : fido_top

`default_nettype wire
