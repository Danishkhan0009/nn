//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/hazard_unit.sv
// Module    : hazard_unit
// Content   : pipeline hazards: load-use interlock, domain readiness (a gated unit must be awake before issue), EX hold, issue and gating-stall accounting
// Hierarchy : fido_top > u_core (rv32im_core) > u_hz
// Power leaf: CORE (combinational)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module hazard_unit
  import fido_pkg::*;
(
  input  wire        ifid_vld,
  input  wire        urs1,           // instruction in ID uses rs1
  input  wire        urs2,           // instruction in ID uses rs2
  input  wire  [4:0] rs1,
  input  wire  [4:0] rs2,
  input  wire  [2:0] unit,
  input  wire        uses_hi,
  input  wire        ex_vld,
  input  wire        ex_load,
  input  wire  [4:0] ex_rd,
  input  wire        ex_stall,       // EX busy with a MUL / DIV
  input  wire        mem_stall,      // MEM waits for a waking bank
  input  wire        flush,
  input  wire [17:0] cn_ready,       // per clock net: domain ready (not power-gated)
  output logic       ex_adv,         // EX instruction advances this cycle
  output logic       id_issue,       // ID instruction issues this cycle
  output logic       idex_vld_we,    // ID/EX valid flop must be written
  output logic       pg_stall        // stall cycle caused by gating
);
  logic unit_rdy;
  logic load_use;
  logic res_stall;      // the unit (or ID/EX, RF-HI) is not ready
  logic ex_hold;
  logic id_stall;

  assign load_use = ex_vld && ex_load && (ex_rd != 5'd0) &&
                    ((urs1 && (rs1 == ex_rd)) || (urs2 && (rs2 == ex_rd)));

  always_comb begin
    case (unit)
      FU_ADD:   unit_rdy = cn_ready[CN_ADD_LO] & cn_ready[CN_ADD_HI];
      FU_SHIFT: unit_rdy = cn_ready[CN_SHIFT];
      FU_LOGIC: unit_rdy = cn_ready[CN_LOGIC_LO] & cn_ready[CN_LOGIC_HI];
      FU_CMP:   unit_rdy = cn_ready[CN_CMP];
      FU_MUL:   unit_rdy = cn_ready[CN_MUL];
      FU_DIV:   unit_rdy = cn_ready[CN_DIV];
      default:  unit_rdy = 1'b1;
    endcase
  end

  assign res_stall   = !(unit_rdy && cn_ready[CN_IDEX] && (!uses_hi || cn_ready[CN_RFHI]));
  assign id_stall    = ifid_vld && (load_use || res_stall);
  assign ex_hold     = (ex_vld && ex_stall) || mem_stall;
  assign ex_adv      = ex_vld && !ex_hold;
  assign id_issue    = ifid_vld && !id_stall && !ex_hold && !flush;
  // ID/EX valid flop: write only when it can change (load a new instruction,
  // or clear a valid one). Writing 0 over 0 every cycle kept D_IDEX / D_EX
  // "busy" forever, so clock gating never engaged during WFI sleep.
  assign idex_vld_we = !ex_hold && (id_issue || ex_vld);
  assign pg_stall    = mem_stall || (ifid_vld && res_stall && !load_use && !ex_hold);
endmodule : hazard_unit

`default_nettype wire
