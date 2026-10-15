//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/ex/fwd_unit.sv
// Module    : fwd_unit
// Content   : operand forwarding EX/MEM -> EX and MEM/WB -> EX (youngest wins)
// Hierarchy : fido_top > u_core > u_ex > u_fwd
// Power leaf: EX (combinational)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module fwd_unit (
  input  wire        urs1,          // instruction in EX uses rs1
  input  wire        urs2,          // instruction in EX uses rs2
  input  wire  [4:0] rs1,
  input  wire  [4:0] rs2,
  input  wire        exmem_vld,
  input  wire        exmem_wen,     // writes rd and is not a load
  input  wire  [4:0] exmem_rd,
  input  wire [31:0] exmem_res,
  input  wire        memwb_vld,
  input  wire        memwb_wen,
  input  wire  [4:0] memwb_rd,
  input  wire [31:0] memwb_wdata,
  output logic        fa,           // forward operand A
  output logic        fb,           // forward operand B
  output logic [31:0] fa_val,
  output logic [31:0] fb_val
);
  logic fa_mem;
  logic fa_wb;
  logic fb_mem;
  logic fb_wb;

  assign fa_mem = urs1 && (rs1 != 5'd0) && exmem_vld && exmem_wen && (exmem_rd == rs1);
  assign fa_wb  = urs1 && (rs1 != 5'd0) && memwb_vld && memwb_wen && (memwb_rd == rs1);
  assign fb_mem = urs2 && (rs2 != 5'd0) && exmem_vld && exmem_wen && (exmem_rd == rs2);
  assign fb_wb  = urs2 && (rs2 != 5'd0) && memwb_vld && memwb_wen && (memwb_rd == rs2);

  assign fa     = fa_mem | fa_wb;
  assign fb     = fb_mem | fb_wb;
  assign fa_val = fa_mem ? exmem_res : memwb_wdata;
  assign fb_val = fb_mem ? exmem_res : memwb_wdata;
endmodule : fwd_unit

`default_nettype wire
