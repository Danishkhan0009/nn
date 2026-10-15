//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/pmu/pm_sense.sv
// Module    : pm_sense
// Content   : activity sensing per clock net for the PMU
//   cn_we  : functional write enables      -> clock-gating busy
//   cn_dem : present or in-flight demand   -> power-gating busy
//   occ    : pipeline occupancy (ML feature)
// Hierarchy : fido_top > u_sense
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module pm_sense
  import fido_pkg::*;
(
  // write enables (already isolated at their power-domain boundary)
  input  wire        we_add,
  input  wire        we_logic,
  input  wire        we_shift,
  input  wire        we_cmp,
  input  wire        we_mul,
  input  wire        we_div,
  input  wire        we_idex,
  input  wire        we_exmem,
  input  wire        we_memwb,
  input  wire  [3:0] dm_we,
  input  wire        rfh_we,
  input  wire        evq_busy,
  input  wire        we_core,
  // demand
  input  wire        id_vld,
  input  wire  [2:0] id_unit,
  input  wire        ex_vld,
  input  wire  [2:0] ex_unit,
  input  wire        mul_busy,
  input  wire        div_busy,
  input  wire        exmem_vld,
  input  wire        memwb_vld,
  input  wire  [3:0] bank_dem,
  input  wire        rfh_dem,
  input  wire        wfi_sleep,
  input  wire        evq_irq,
  // to PMU
  output logic [17:0] cn_we,
  output logic [17:0] cn_dem,
  output logic [2:0]  occ
);
  logic id_add;
  logic id_logic;
  logic id_shift;
  logic id_cmp;
  logic id_mul;
  logic id_div;

  //------------------------------------------------ clock-gating busy
  always_comb begin
    cn_we[CN_ADD_LO]  = we_add;
    cn_we[CN_ADD_HI]  = we_add;
    cn_we[CN_LOGIC_LO] = we_logic;
    cn_we[CN_LOGIC_HI] = we_logic;
    cn_we[CN_SHIFT]   = we_shift;
    cn_we[CN_CMP]     = we_cmp;
    cn_we[CN_MUL]     = we_mul;
    cn_we[CN_DIV]     = we_div;
    cn_we[CN_IDEX]    = we_idex;
    cn_we[CN_EXMEM]   = we_exmem;
    cn_we[CN_MEMWB]   = we_memwb;
    cn_we[CN_BANK0]   = dm_we[0];
    cn_we[CN_BANK1]   = dm_we[1];
    cn_we[CN_BANK2]   = dm_we[2];
    cn_we[CN_BANK3]   = dm_we[3];
    cn_we[CN_RFHI]    = rfh_we;
    cn_we[CN_EVQ]     = evq_busy;
    cn_we[CN_CORE]    = we_core;
  end

  //------------------------------------------------ power-gating busy (demand)
  assign id_add   = id_vld && (id_unit == FU_ADD);
  assign id_logic = id_vld && (id_unit == FU_LOGIC);
  assign id_shift = id_vld && (id_unit == FU_SHIFT);
  assign id_cmp   = id_vld && (id_unit == FU_CMP);
  assign id_mul   = id_vld && (id_unit == FU_MUL);
  assign id_div   = id_vld && (id_unit == FU_DIV);

  always_comb begin
    cn_dem[CN_ADD_LO]  = id_add   || (ex_unit == FU_ADD);
    cn_dem[CN_ADD_HI]  = id_add   || (ex_unit == FU_ADD);
    cn_dem[CN_LOGIC_LO] = id_logic || (ex_unit == FU_LOGIC);
    cn_dem[CN_LOGIC_HI] = id_logic || (ex_unit == FU_LOGIC);
    cn_dem[CN_SHIFT]   = id_shift || (ex_unit == FU_SHIFT);
    cn_dem[CN_CMP]     = id_cmp   || (ex_unit == FU_CMP);
    cn_dem[CN_MUL]     = id_mul   || (ex_unit == FU_MUL) || mul_busy;
    cn_dem[CN_DIV]     = id_div   || (ex_unit == FU_DIV) || div_busy;
    cn_dem[CN_IDEX]    = id_vld   || ex_vld;
    cn_dem[CN_EXMEM]   = exmem_vld || ex_vld;
    cn_dem[CN_MEMWB]   = memwb_vld || exmem_vld;
    cn_dem[CN_BANK0]   = bank_dem[0];
    cn_dem[CN_BANK1]   = bank_dem[1];
    cn_dem[CN_BANK2]   = bank_dem[2];
    cn_dem[CN_BANK3]   = bank_dem[3];
    cn_dem[CN_RFHI]    = rfh_dem;
    cn_dem[CN_EVQ]     = 1'b0;
    cn_dem[CN_CORE]    = !wfi_sleep || evq_irq;
  end

  //------------------------------------------------ pipeline occupancy
  assign occ = {2'b00, id_vld} + {2'b00, ex_vld} + {2'b00, exmem_vld} + {2'b00, memwb_vld};
endmodule : pm_sense

`default_nettype wire
