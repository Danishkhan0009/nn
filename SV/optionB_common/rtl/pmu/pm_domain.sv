//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/pmu/pm_domain.sv
// Module    : pm_domain
// Content   : power-management controller of ONE domain:
//               u_policy  policy_reactive  (idle threshold)
//               g_ml      policy_ml_wrap   (POLICY_ML = 1: ML request + ml_force)
//               u_shell   safety_shell     (order / timing / confidence gate)
//               g_sw      pwr_switch_model (power-gating domains only)
//             SH_MODE = MODE_CG : clock-gating domain (no switch, ack = 1)
//             SH_MODE = MODE_PG : power-gating domain (header switch)
// Hierarchy : fido_top > u_pmu (pmu_top) > g_*.g_*[d].u_dom (pm_domain)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module pm_domain
  import fido_pkg::*;
#(
  parameter int SH_MODE   = MODE_CG,
  parameter int THR       = 8,
  parameter int BE        = 8,
  parameter int HYST      = 8,
  parameter int WAKE_PG   = 4,
  parameter int POLICY_ML = 0       // 1 = ML model decides power gating (MODE 4)
) (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        busy,
  input  wire        live,
  input  wire        trap_win,
  input  wire  [1:0] ml_force,
  input  wire  [2:0] model_dec,     // {confidence, class}; unused unless POLICY_ML
  output logic       clk_en,
  output logic       iso,
  output logic       ret,
  output logic       pwr_req,
  output logic       init,
  output logic       ready,
  output logic       ack,
  output logic       pd_on,
  output logic [2:0] pm_state,
  output logic       mispredict
);
  wire [1:0] r_class;
  wire [1:0] req;
  wire       conf;

  policy_reactive #(.MODE(SH_MODE), .THR(THR)) u_policy (
    .clk       (clk),
    .rst_n     (rst_n),
    .busy      (busy),
    .live      (live),
    .req_class (r_class)
  );

  if (POLICY_ML != 0) begin : g_ml
    policy_ml_wrap u_ml (
      .ml_force  (ml_force),
      .r_class   (r_class),
      .model_dec (model_dec),
      .req_class (req),
      .conf      (conf)
    );
  end else begin : g_re
    assign req  = r_class;
    assign conf = 1'b1;
  end

  safety_shell #(.MODE(SH_MODE), .BE(BE), .HYST(HYST)) u_shell (
    .clk        (clk),
    .rst_n      (rst_n),
    .busy       (busy),
    .live       (live),
    .trap_win   (trap_win),
    .req_class  (req),
    .conf       (conf),
    .ack_pwr    (ack),
    .clk_en     (clk_en),
    .iso        (iso),
    .ret        (ret),
    .pwr_req    (pwr_req),
    .init       (init),
    .ready      (ready),
    .pm_state   (pm_state),
    .mispredict (mispredict)
  );

  if (SH_MODE == MODE_PG) begin : g_sw
    pwr_switch_model #(.WAKE(WAKE_PG)) u_switch (
      .clk     (clk),
      .rst_n   (rst_n),
      .pwr_req (pwr_req),
      .ack     (ack),
      .pd_on   (pd_on)
    );
  end else begin : g_nosw
    assign ack   = 1'b1;
    assign pd_on = 1'b1;
  end
endmodule : pm_domain

`default_nettype wire
