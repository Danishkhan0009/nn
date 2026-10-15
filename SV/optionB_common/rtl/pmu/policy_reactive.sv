//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/pmu/policy_reactive.sv
// Module    : policy_reactive
// Content   : idle-counter threshold policy (existing-work baseline,
//             #080 stall-driven CG / #079 idle-threshold PG).
//             req_class : 0 none, 1 CG, 2 PG_RET, 3 PG_OFF
// Hierarchy : pmu_top > pm_domain > u_policy
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module policy_reactive
  import fido_pkg::*;
#(
  parameter int MODE = MODE_CG,   // MODE_CG: request CG, MODE_PG: request PG
  parameter int THR  = 8          // idle cycles before the request
) (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        busy,
  input  wire        live,
  output logic [1:0] req_class
);
  localparam logic [7:0] T8 = 8'(THR);

  logic [7:0] idle;
  logic       hit;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)             idle <= 8'd0;
    else if (busy)          idle <= 8'd0;
    else if (idle != 8'hFF) idle <= idle + 8'd1;
  end

  assign hit       = (idle >= T8);
  assign req_class = (!hit)           ? RQ_NONE   :
                     (MODE == MODE_CG) ? RQ_CG     :
                     (live)            ? RQ_PG_RET : RQ_PG_OFF;
endmodule : policy_reactive

`default_nettype wire
