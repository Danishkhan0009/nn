//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/csr_unit.sv
// Module    : csr_unit
// Content   : machine-mode CSRs (retention flops): mstatus.MIE/MPIE, mie.MEIE, mtvec, mscratch, mepc, mcause, pm_ctrl (0x7C0); read-only misa, mip.MEIP, mcycle / minstret views. CSR read mux, CSRRW/RS/RC(I) write, trap / mret updates.
// Hierarchy : fido_top > u_core (rv32im_core) > u_csr
// Power leaf: CORE (clock net CORE)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module csr_unit (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        pd_on,
  input  wire        pd_ret,
  input  wire        pd_init,
  // CSR instruction in EX
  input  wire        ex_csr,
  input  wire [11:0] ex_csr_addr,
  input  wire  [2:0] ex_f3,
  input  wire [31:0] ex_csr_src,
  input  wire        ex_csr_wnz,     // rs1 / uimm field != 0
  input  wire        ex_adv,
  // traps
  input  wire        trap,
  input  wire        trap_en,
  input  wire        mret_en,
  input  wire        irq_take,
  input  wire  [3:0] ex_exc_code,
  input  wire [31:0] ex_pc,
  // read-only sources
  input  wire        evq_irq,
  input  wire [31:0] mcycle,
  input  wire [31:0] minstret,
  output logic [31:0] csr_rdata,
  output logic        st_mie,
  output logic        mie_meie,
  output logic [31:0] mtvec,
  output logic [31:0] mepc,
  output logic        we              // any CSR written (clock-gating busy)
);
  wire        st_mpie;
  wire [31:0] mcause;
  wire [31:0] mscratch;
  wire [31:0] pm_ctrl;

  logic        csr_wr;
  logic [31:0] csr_new;
  logic        wr_mstatus;
  logic        wr_mie;
  logic        wr_mtvec;
  logic        wr_mscratch;
  logic        wr_mepc;
  logic        wr_mcause;
  logic        wr_pmctrl;
  logic [31:0] cause_val;
  logic        st_en;
  logic        n_mie;
  logic        n_mpie;
  logic        epc_en;
  logic [31:0] n_mepc;
  logic        cau_en;
  logic [31:0] n_mcause;

  //------------------------------------------------ read mux
  always_comb begin
    case (ex_csr_addr)
      12'h300: csr_rdata = {19'd0, 2'b11, 3'd0, st_mpie, 3'd0, st_mie, 3'd0};   // mstatus
      12'h301: csr_rdata = 32'h4000_1100;                                       // misa RV32IM
      12'h304: csr_rdata = {20'd0, mie_meie, 11'd0};                            // mie
      12'h305: csr_rdata = mtvec;
      12'h340: csr_rdata = mscratch;
      12'h341: csr_rdata = mepc;
      12'h342: csr_rdata = mcause;
      12'h344: csr_rdata = {20'd0, evq_irq, 11'd0};                             // mip
      12'h7C0: csr_rdata = pm_ctrl;
      12'hB00: csr_rdata = mcycle;
      12'hB02: csr_rdata = minstret;
      12'hC00: csr_rdata = mcycle;
      12'hC02: csr_rdata = minstret;
      default: csr_rdata = 32'd0;
    endcase
  end

  //------------------------------------------------ write
  assign csr_wr      = ex_adv && ex_csr && !trap && ((ex_f3[1:0] == 2'b01) || ex_csr_wnz);
  assign csr_new     = (ex_f3[1:0] == 2'b01) ? ex_csr_src :
                       (ex_f3[1:0] == 2'b10) ? (csr_rdata | ex_csr_src) :
                                               (csr_rdata & ~ex_csr_src);
  assign wr_mstatus  = csr_wr && (ex_csr_addr == 12'h300);
  assign wr_mie      = csr_wr && (ex_csr_addr == 12'h304);
  assign wr_mtvec    = csr_wr && (ex_csr_addr == 12'h305);
  assign wr_mscratch = csr_wr && (ex_csr_addr == 12'h340);
  assign wr_mepc     = csr_wr && (ex_csr_addr == 12'h341);
  assign wr_mcause   = csr_wr && (ex_csr_addr == 12'h342);
  assign wr_pmctrl   = csr_wr && (ex_csr_addr == 12'h7C0);

  assign cause_val = irq_take ? 32'h8000_000B : {28'd0, ex_exc_code};
  assign st_en     = wr_mstatus || trap_en || mret_en;
  assign n_mie     = trap_en ? 1'b0 : (mret_en ? st_mpie : csr_new[3]);
  assign n_mpie    = trap_en ? st_mie : (mret_en ? 1'b1 : csr_new[7]);
  assign epc_en    = wr_mepc || trap_en;
  assign n_mepc    = trap_en ? ex_pc : {csr_new[31:2], 2'b00};
  assign cau_en    = wr_mcause || trap_en;
  assign n_mcause  = trap_en ? cause_val : csr_new;

  //------------------------------------------------ registers (retention)
  pg_dff #(.W(2), .RV(2'b00), .RET(1)) u_mstatus (
    .clk(clk), .rst_n(rst_n), .pd_on(pd_on), .pd_ret(pd_ret), .pd_init(pd_init),
    .en(st_en), .d({n_mie, n_mpie}), .q({st_mie, st_mpie}));

  pg_dff #(.W(1), .RV(1'b0), .RET(1)) u_mie (
    .clk(clk), .rst_n(rst_n), .pd_on(pd_on), .pd_ret(pd_ret), .pd_init(pd_init),
    .en(wr_mie), .d(csr_new[11]), .q(mie_meie));

  pg_dff #(.W(32), .RV(32'd0), .RET(1)) u_mtvec (
    .clk(clk), .rst_n(rst_n), .pd_on(pd_on), .pd_ret(pd_ret), .pd_init(pd_init),
    .en(wr_mtvec), .d({csr_new[31:2], 2'b00}), .q(mtvec));

  pg_dff #(.W(32), .RV(32'd0), .RET(1)) u_mepc (
    .clk(clk), .rst_n(rst_n), .pd_on(pd_on), .pd_ret(pd_ret), .pd_init(pd_init),
    .en(epc_en), .d(n_mepc), .q(mepc));

  pg_dff #(.W(32), .RV(32'd0), .RET(1)) u_mcause (
    .clk(clk), .rst_n(rst_n), .pd_on(pd_on), .pd_ret(pd_ret), .pd_init(pd_init),
    .en(cau_en), .d(n_mcause), .q(mcause));

  pg_dff #(.W(32), .RV(32'd0), .RET(1)) u_mscratch (
    .clk(clk), .rst_n(rst_n), .pd_on(pd_on), .pd_ret(pd_ret), .pd_init(pd_init),
    .en(wr_mscratch), .d(csr_new), .q(mscratch));

  pg_dff #(.W(32), .RV(32'd0), .RET(1)) u_pmctrl (
    .clk(clk), .rst_n(rst_n), .pd_on(pd_on), .pd_ret(pd_ret), .pd_init(pd_init),
    .en(wr_pmctrl), .d(csr_new), .q(pm_ctrl));

  assign we = st_en || wr_mie || wr_mtvec || epc_en || cau_en || wr_mscratch || wr_pmctrl;
endmodule : csr_unit

`default_nettype wire
