//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/pmu/policy_ml_wrap.sv
// Module    : policy_ml_wrap
// Content   : selects the power-gating request of one power domain in MODE 4
//             from the exported ML model, with the ml_force test hook:
//               ml_force 0 : model decides {conf, class}
//               ml_force 1 : force a confident PG_OFF request
//               ml_force 2 : force confidence 0 (shell refuses every PG request)
//               ml_force 3 : reactive policy (training-trace mode)
//             The model can only request; the safety shell decides.
// Hierarchy : pmu_top > pm_domain > g_ml.u_ml
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module policy_ml_wrap
  import fido_pkg::*;
(
  input  wire  [1:0] ml_force,
  input  wire  [1:0] r_class,     // reactive policy request
  input  wire  [2:0] model_dec,   // {confidence, class} from ml_models_*
  output logic [1:0] req_class,
  output logic       conf
);
  assign req_class = (ml_force == 2'd3) ? r_class   :
                     (ml_force == 2'd1) ? RQ_PG_OFF : model_dec[1:0];
  assign conf      = (ml_force == 2'd3) || (ml_force == 2'd1) ||
                     ((ml_force == 2'd0) && model_dec[2]);
endmodule : policy_ml_wrap

`default_nettype wire
