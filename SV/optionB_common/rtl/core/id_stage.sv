//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/id_stage.sv
// Module    : id_stage
// Content   : ID stage: RV32IM decoder (fido_pkg::decode), immediate generator, register specifiers, RF-HI use flag
// Hierarchy : fido_top > u_core (rv32im_core) > u_id
// Power leaf: CORE (combinational)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module id_stage
  import fido_pkg::*;
(
  input  wire  [31:0] ifid_insn,
  output ctl_t        ctl,
  output logic [31:0] imm,
  output logic  [4:0] rs1,
  output logic  [4:0] rs2,
  output logic  [4:0] rd,
  output logic  [2:0] unit,
  output logic        uses_hi      // touches x16..x31 (RF-HI bank)
);
  assign ctl     = decode(ifid_insn);
  assign imm     = immgen(ifid_insn);
  assign rs1     = ifid_insn[19:15];
  assign rs2     = ifid_insn[24:20];
  assign rd      = ifid_insn[11:7];
  assign unit    = ctl.unit;
  assign uses_hi = (ctl.urs1 && rs1[4]) || (ctl.urs2 && rs2[4]) || (ctl.wen && rd[4]);
endmodule : id_stage

`default_nettype wire
