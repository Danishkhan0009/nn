//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/wb_stage.sv
// Module    : wb_stage
// Content   : WB stage: MEM/WB register (clock net MEMWB), register write-back
//             enable and the retirement trace (RVFI-style) of every
//             instruction that leaves the pipeline.
// Hierarchy : fido_top > u_core (rv32im_core) > u_wb
// Power leaf: CORE (clock net MEMWB)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module wb_stage (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        pd_on,
  input  wire        pd_ret,
  input  wire        pd_init,
  // from MEM
  input  wire        mem_stall,
  input  wire        mem_go,
  input  wire        exmem_vld,
  input  wire [31:0] exmem_pc,
  input  wire [31:0] exmem_insn,
  input  wire  [4:0] exmem_rd,
  input  wire        exmem_wen,
  input  wire [31:0] wb_val,
  input  wire        exmem_store,
  input  wire [31:0] exmem_addr,
  input  wire [31:0] st_data,
  input  wire  [3:0] st_strb,
  // MEM/WB register contents
  output logic        memwb_vld,
  output logic  [4:0] memwb_rd,
  output logic        memwb_wen,
  output logic [31:0] memwb_wdata,
  // write-back
  output logic        wb_we,
  // retirement trace
  output logic        rv_valid,
  output logic [31:0] rv_pc,
  output logic [31:0] rv_insn,
  output logic  [4:0] rv_rd,
  output logic [31:0] rv_wdata,
  output logic        rv_mem_we,
  output logic [31:0] rv_mem_addr,
  output logic [31:0] rv_mem_wdata,
  output logic  [3:0] rv_mem_strb,
  output logic        we             // MEM/WB register written (clock-gating busy)
);
  wire [31:0] memwb_pc;
  wire [31:0] memwb_insn;
  wire        memwb_mwe;
  wire [31:0] memwb_maddr;
  wire [31:0] memwb_mwdata;
  wire  [3:0] memwb_mstrb;
  logic       memwb_vld_en;

  assign memwb_vld_en = !mem_stall && (memwb_vld || exmem_vld);

  // 32+32+5+1+32+1+32+32+4 = 171 bits
  pipe_reg #(.W(171)) u_memwb (
    .clk     (clk),
    .rst_n   (rst_n),
    .pd_on   (pd_on),
    .pd_ret  (pd_ret),
    .pd_init (pd_init),
    .vld_en  (memwb_vld_en),
    .vld_d   (exmem_vld),
    .data_en (mem_go),
    .d       ({exmem_pc, exmem_insn, exmem_rd, exmem_wen, wb_val, exmem_store, exmem_addr,
               (exmem_store ? st_data : 32'd0), (exmem_store ? st_strb : 4'd0)}),
    .vld_q   (memwb_vld),
    .q       ({memwb_pc, memwb_insn, memwb_rd, memwb_wen, memwb_wdata, memwb_mwe, memwb_maddr,
               memwb_mwdata, memwb_mstrb})
  );

  assign wb_we        = memwb_vld && memwb_wen && !mem_stall;

  assign rv_valid     = memwb_vld && !mem_stall;
  assign rv_pc        = memwb_pc;
  assign rv_insn      = memwb_insn;
  assign rv_rd        = memwb_wen ? memwb_rd : 5'd0;
  assign rv_wdata     = memwb_wen ? memwb_wdata : 32'd0;
  assign rv_mem_we    = memwb_mwe;
  assign rv_mem_addr  = memwb_mwe ? memwb_maddr : 32'd0;
  assign rv_mem_wdata = memwb_mwdata;
  assign rv_mem_strb  = memwb_mstrb;

  assign we = memwb_vld_en || mem_go;
endmodule : wb_stage

`default_nettype wire
