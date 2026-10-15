//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog testbench top
// File      : tb/tb_cgpg_ml_fine.sv
// Module    : tb_cgpg_ml_fine
// Content   : Clock + power gating + ML, fine grain (15 clock + 8 power domains)
//             REF = fido_top MODE=BASE (no gating), DUT = fido_cgpg_ml_fine;
//             checking is done by the shared environment fido_tb_env.
//
//   tb_cgpg_ml_fine
//   |-- u_ref  fido_top (MODE_BASE)        reference core, never gated
//   |-- u_dut  fido_cgpg_ml_fine           design under test
//   `-- u_env  fido_tb_env                 driver, scoreboard, monitor, tests
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_cgpg_ml_fine;
  import fido_pkg::*;

  localparam int WAKE_PG = 4;

  wire          clk;
  wire          rst_n;
  wire          prog_we;
  wire  [9:0]   prog_addr;
  wire [31:0]   prog_data;
  wire  [3:0]   ref_ev_valid;
  wire [31:0]   ref_ev_data;
  wire  [3:0]   dut_ev_valid;
  wire [31:0]   dut_ev_data;
  wire  [1:0]   ml_force;

  // REF outputs
  wire          r_tohost_we;
  wire [31:0]   r_tohost_data;
  wire          r_wfi;
  wire          r_valid;
  wire [31:0]   r_pc;
  wire [31:0]   r_insn;
  wire  [4:0]   r_rd;
  wire [31:0]   r_wdata;
  wire          r_mem_we;
  wire [31:0]   r_mem_addr;
  wire [31:0]   r_mem_wdata;
  wire  [3:0]   r_mem_strb;
  wire [95:0]   r_pm_state;
  wire [31:0]   r_clk_en;
  wire [31:0]   r_iso;
  wire [31:0]   r_ret;
  wire [31:0]   r_pwr;
  wire [31:0]   r_ack;
  wire [31:0]   r_busy;
  wire [31:0]   r_ready;
  wire [31:0]   r_mispred;
  wire          r_trap_win;
  wire          r_pg_stall;
  wire [255:0]  r_ml_feat;

  // DUT outputs
  wire          d_tohost_we;
  wire [31:0]   d_tohost_data;
  wire          d_wfi;
  wire          d_valid;
  wire [31:0]   d_pc;
  wire [31:0]   d_insn;
  wire  [4:0]   d_rd;
  wire [31:0]   d_wdata;
  wire          d_mem_we;
  wire [31:0]   d_mem_addr;
  wire [31:0]   d_mem_wdata;
  wire  [3:0]   d_mem_strb;
  wire [95:0]   d_pm_state;
  wire [31:0]   d_clk_en;
  wire [31:0]   d_iso;
  wire [31:0]   d_ret;
  wire [31:0]   d_pwr;
  wire [31:0]   d_ack;
  wire [31:0]   d_busy;
  wire [31:0]   d_ready;
  wire [31:0]   d_mispred;
  wire          d_trap_win;
  wire          d_pg_stall;
  wire [255:0]  d_ml_feat;

  fido_top #(.MODE(MODE_BASE), .GRAIN(GRAIN_FINE)) u_ref (
    .clk            (clk),
    .rst_n          (rst_n),
    .prog_we        (prog_we),
    .prog_addr      (prog_addr),
    .prog_data      (prog_data),
    .ev_valid       (ref_ev_valid),
    .ev_data        (ref_ev_data),
    .ml_force       (2'b00),
    .tohost_we      (r_tohost_we),
    .tohost_data    (r_tohost_data),
    .wfi_sleep      (r_wfi),
    .rvfi_valid     (r_valid),
    .rvfi_pc        (r_pc),
    .rvfi_insn      (r_insn),
    .rvfi_rd        (r_rd),
    .rvfi_wdata     (r_wdata),
    .rvfi_mem_we    (r_mem_we),
    .rvfi_mem_addr  (r_mem_addr),
    .rvfi_mem_wdata (r_mem_wdata),
    .rvfi_mem_strb  (r_mem_strb),
    .pm_state_bus   (r_pm_state),
    .dom_clk_en     (r_clk_en),
    .dom_iso        (r_iso),
    .dom_ret        (r_ret),
    .dom_pwr        (r_pwr),
    .dom_ack        (r_ack),
    .dom_busy       (r_busy),
    .dom_ready      (r_ready),
    .dom_mispred    (r_mispred),
    .trap_win       (r_trap_win),
    .pg_stall       (r_pg_stall),
    .ml_feat        (r_ml_feat)
  );

  fido_cgpg_ml_fine #(.WAKE_PG(WAKE_PG)) u_dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .prog_we        (prog_we),
    .prog_addr      (prog_addr),
    .prog_data      (prog_data),
    .ev_valid       (dut_ev_valid),
    .ev_data        (dut_ev_data),
    .ml_force       (ml_force),
    .tohost_we      (d_tohost_we),
    .tohost_data    (d_tohost_data),
    .wfi_sleep      (d_wfi),
    .rvfi_valid     (d_valid),
    .rvfi_pc        (d_pc),
    .rvfi_insn      (d_insn),
    .rvfi_rd        (d_rd),
    .rvfi_wdata     (d_wdata),
    .rvfi_mem_we    (d_mem_we),
    .rvfi_mem_addr  (d_mem_addr),
    .rvfi_mem_wdata (d_mem_wdata),
    .rvfi_mem_strb  (d_mem_strb),
    .pm_state_bus   (d_pm_state),
    .dom_clk_en     (d_clk_en),
    .dom_iso        (d_iso),
    .dom_ret        (d_ret),
    .dom_pwr        (d_pwr),
    .dom_ack        (d_ack),
    .dom_busy       (d_busy),
    .dom_ready      (d_ready),
    .dom_mispred    (d_mispred),
    .trap_win       (d_trap_win),
    .pg_stall       (d_pg_stall),
    .ml_feat        (d_ml_feat)
  );

  fido_tb_env #(
    .MODE    (MODE_CGPG_ML),
    .GRAIN   (GRAIN_FINE),
    .WAKE_PG (WAKE_PG),
    .CFG     ("CGPG_ML_FINE")
  ) u_env (
    .clk           (clk),
    .rst_n         (rst_n),
    .prog_we       (prog_we),
    .prog_addr     (prog_addr),
    .prog_data     (prog_data),
    .ref_ev_valid  (ref_ev_valid),
    .ref_ev_data   (ref_ev_data),
    .dut_ev_valid  (dut_ev_valid),
    .dut_ev_data   (dut_ev_data),
    .ml_force      (ml_force),
    .ref_valid     (r_valid),
    .ref_pc        (r_pc),
    .ref_insn      (r_insn),
    .ref_rd        (r_rd),
    .ref_wdata     (r_wdata),
    .ref_mem_we    (r_mem_we),
    .ref_mem_addr  (r_mem_addr),
    .ref_mem_wdata (r_mem_wdata),
    .ref_mem_strb  (r_mem_strb),
    .ref_wfi       (r_wfi),
    .dut_valid     (d_valid),
    .dut_pc        (d_pc),
    .dut_insn      (d_insn),
    .dut_rd        (d_rd),
    .dut_wdata     (d_wdata),
    .dut_mem_we    (d_mem_we),
    .dut_mem_addr  (d_mem_addr),
    .dut_mem_wdata (d_mem_wdata),
    .dut_mem_strb  (d_mem_strb),
    .dut_wfi       (d_wfi),
    .pm_state_bus  (d_pm_state),
    .dom_clk_en    (d_clk_en),
    .dom_iso       (d_iso),
    .dom_ret       (d_ret),
    .dom_pwr       (d_pwr),
    .dom_ack       (d_ack),
    .dom_busy      (d_busy),
    .dom_ready     (d_ready),
    .dom_mispred   (d_mispred),
    .dut_trap_win  (d_trap_win),
    .dut_pg_stall  (d_pg_stall),
    .ml_feat       (d_ml_feat)
  );
endmodule : tb_cgpg_ml_fine

`default_nettype wire
