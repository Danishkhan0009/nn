//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/mem_stage.sv
// Module    : mem_stage
// Content   : MEM stage: EX/MEM register (clock net EXMEM), LSU - address decode, bank select (range or interleave), store strobes, load align / extend, MMIO (event queue, TOHOST), stall while a bank wakes, per-bank demand for the PMU. Memory map: 0x0001_0000-0x0001_0FFF data banks; 0x0002_0000 EVQ STATUS, 0x0002_0004 EVQ POP, 0x0002_0008 EVQ CFG; 0x0003_0000 TOHOST
// Hierarchy : fido_top > u_core (rv32im_core) > u_mem
// Power leaf: CORE (clock net EXMEM)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module mem_stage #(
  parameter int BANK_MAP = 0     // 0 = address range (addr[11:10]), 1 = word interleave (addr[3:2])
) (
  input  wire         clk,
  input  wire         rst_n,
  input  wire         pd_on,
  input  wire         pd_ret,
  input  wire         pd_init,
  input  wire         ex_adv,
  input  wire         trap,
  // from EX
  input  wire         ex_vld,
  input  wire  [31:0] ex_pc,
  input  wire  [31:0] ex_insn,
  input  wire   [4:0] ex_rd,
  input  wire         ex_wen,
  input  wire  [31:0] ex_res,
  input  wire         ex_load,
  input  wire         ex_store,
  input  wire   [2:0] ex_f3,
  input  wire  [31:0] ex_addr,
  input  wire  [31:0] ex_sdata,
  // banks / event queue
  input  wire   [3:0] bank_rdy,      // per bank: domain ready
  input  wire [127:0] dm_rdata,
  input  wire   [3:0] evq_count,
  input  wire   [9:0] evq_head,
  input  wire         evq_ovf,
  // EX/MEM register contents
  output logic        exmem_vld,
  output logic [31:0] exmem_pc,
  output logic [31:0] exmem_insn,
  output logic  [4:0] exmem_rd,
  output logic        exmem_wen,
  output logic        exmem_load,
  output logic [31:0] exmem_res,
  output logic        exmem_store,
  output logic [31:0] exmem_addr,
  output logic [31:0] exmem_sdata,
  // LSU results
  output logic        mem_stall,
  output logic        mem_go,        // MEM instruction completes this cycle
  output logic [31:0] wb_val,        // load data or EX result
  output logic [31:0] st_data,
  output logic  [3:0] st_strb,
  output logic  [7:0] dm_idx,
  output logic  [3:0] dm_we,
  output logic        evq_pop,
  output logic        evq_cfg_we,
  output logic        tohost_we,
  output logic  [3:0] bank_dem,      // per bank demand (EX address or MEM access)
  output logic        we             // EX/MEM register written (clock-gating busy)
);
  //------------------------------------------------ EX/MEM register
  logic       exmem_take;
  logic       exmem_vld_en;
  logic [2:0] exmem_f3;

  assign exmem_take   = ex_adv && !trap;
  assign exmem_vld_en = !mem_stall && (exmem_vld || ex_adv);

  pipe_reg #(.W(171)) u_exmem (
    .clk     (clk),
    .rst_n   (rst_n),
    .pd_on   (pd_on),
    .pd_ret  (pd_ret),
    .pd_init (pd_init),
    .vld_en  (exmem_vld_en),
    .vld_d   (exmem_take),
    .data_en (exmem_take),
    .d       ({ex_pc, ex_insn, ex_rd, ex_wen, ex_res, ex_load, ex_store, ex_f3, ex_addr, ex_sdata}),
    .vld_q   (exmem_vld),
    .q       ({exmem_pc, exmem_insn, exmem_rd, exmem_wen, exmem_res, exmem_load, exmem_store,
               exmem_f3, exmem_addr, exmem_sdata})
  );

  //------------------------------------------------ address decode
  logic        dm_hit;
  logic        evq_hit;
  logic        th_hit;
  logic  [1:0] bank;
  logic        mem_access;
  logic        bank_ok;
  logic [31:0] bank_word;
  logic [31:0] evq_word;
  logic [31:0] raw_word;
  logic [31:0] sh_word;
  logic [31:0] ld_val;
  logic        ex_dm_hit;
  logic  [1:0] ex_bank;
  logic        ex_dm_acc;

  assign dm_hit     = (exmem_addr[31:12] == 20'h00010);
  assign evq_hit    = (exmem_addr[31:4]  == 28'h0002000);
  assign th_hit     = (exmem_addr == 32'h0003_0000);
  assign bank       = (BANK_MAP == 0) ? exmem_addr[11:10] : exmem_addr[3:2];
  assign dm_idx     = (BANK_MAP == 0) ? exmem_addr[9:2]   : exmem_addr[11:4];
  assign mem_access = exmem_vld && (exmem_load || exmem_store) && dm_hit;
  assign bank_ok    = (bank == 2'd0) ? bank_rdy[0] : (bank == 2'd1) ? bank_rdy[1] :
                      (bank == 2'd2) ? bank_rdy[2] : bank_rdy[3];
  assign mem_stall  = mem_access && !bank_ok;
  assign mem_go     = exmem_vld && !mem_stall;

  //------------------------------------------------ store
  always_comb begin
    case (exmem_f3[1:0])
      2'b00: begin
        st_strb = 4'b0001 << exmem_addr[1:0];
        st_data = {4{exmem_sdata[7:0]}};
      end
      2'b01: begin
        st_strb = exmem_addr[1] ? 4'b1100 : 4'b0011;
        st_data = {2{exmem_sdata[15:0]}};
      end
      default: begin
        st_strb = 4'b1111;
        st_data = exmem_sdata;
      end
    endcase
  end

  //------------------------------------------------ load
  assign bank_word = dm_rdata[{bank, 5'b00000} +: 32];   // bank * 32
  assign evq_word  = (exmem_addr[3:2] == 2'd0) ? {evq_ovf, 27'd0, evq_count} :
                     (exmem_addr[3:2] == 2'd1) ? {(evq_count != 4'd0), 21'd0, evq_head} : 32'd0;
  assign raw_word  = dm_hit ? bank_word : (evq_hit ? evq_word : 32'd0);
  assign sh_word   = raw_word >> {exmem_addr[1:0], 3'b000};

  always_comb begin
    case (exmem_f3)
      3'b000:  ld_val = {{24{sh_word[7]}},  sh_word[7:0]};
      3'b001:  ld_val = {{16{sh_word[15]}}, sh_word[15:0]};
      3'b100:  ld_val = {24'd0, sh_word[7:0]};
      3'b101:  ld_val = {16'd0, sh_word[15:0]};
      default: ld_val = raw_word;
    endcase
  end

  assign wb_val = exmem_load ? ld_val : exmem_res;

  //------------------------------------------------ write strobes / MMIO
  assign dm_we      = {(mem_go && exmem_store && dm_hit && (bank == 2'd3)),
                       (mem_go && exmem_store && dm_hit && (bank == 2'd2)),
                       (mem_go && exmem_store && dm_hit && (bank == 2'd1)),
                       (mem_go && exmem_store && dm_hit && (bank == 2'd0))};
  assign evq_pop    = mem_go && exmem_load  && evq_hit && (exmem_addr[3:2] == 2'd1);
  assign evq_cfg_we = mem_go && exmem_store && evq_hit && (exmem_addr[3:2] == 2'd2);
  assign tohost_we  = mem_go && exmem_store && th_hit;

  //------------------------------------------------ bank demand (PMU)
  assign ex_dm_hit   = (ex_addr[31:12] == 20'h00010);
  assign ex_bank     = (BANK_MAP == 0) ? ex_addr[11:10] : ex_addr[3:2];
  assign ex_dm_acc   = ex_vld && (ex_load || ex_store) && ex_dm_hit;
  assign bank_dem    = {((ex_dm_acc && (ex_bank == 2'd3)) || (mem_access && (bank == 2'd3))),
                        ((ex_dm_acc && (ex_bank == 2'd2)) || (mem_access && (bank == 2'd2))),
                        ((ex_dm_acc && (ex_bank == 2'd1)) || (mem_access && (bank == 2'd1))),
                        ((ex_dm_acc && (ex_bank == 2'd0)) || (mem_access && (bank == 2'd0)))};

  assign we = exmem_vld_en || exmem_take;
endmodule : mem_stage

`default_nettype wire
