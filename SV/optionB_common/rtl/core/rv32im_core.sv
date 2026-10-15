//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/rv32im_core.sv
// Module    : rv32im_core
// Content   : 5-stage RV32IM pipeline with forwarding, load-use interlock,
//             CSRs, traps, WFI and per-clock-net gating hooks.
//               u_if   if_stage     PC, IF/ID                      CORE leaf
//               u_id   id_stage     decode, immediates             CORE leaf
//               u_rf   regfile      bank LO (CORE) + bank HI (RF_HI leaf)
//               u_hz   hazard_unit  load-use, readiness, issue     CORE leaf
//               u_trap trap_unit    traps, mret, WFI flag, flush   CORE leaf
//               u_csr  csr_unit     machine-mode CSRs              CORE leaf
//               u_ex   ex_stage     ID/EX + ALU/MUL/DIV            EX / ALU_HI / MUL / DIV leaves
//               u_mem  mem_stage    EX/MEM + LSU                   CORE leaf
//               u_wb   wb_stage     MEM/WB + retirement            CORE leaf
//             Every signal leaving the CORE leaf passes isolation cells
//             (clamp 0, except wfi_sleep which clamps to 1 = "asleep").
//             Clock nets / power leaves are indexed as in fido_pkg (CN_*).
// Hierarchy : fido_top > u_core
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module rv32im_core
  import fido_pkg::*;
#(
  parameter int BANK_MAP = 0     // 0 = address range, 1 = word interleave
) (
  input  wire  [17:0]  gclk_cn,      // gated clock per clock net
  input  wire          rst_n,
  input  wire  [17:0]  on_cn,        // power leaf of the net is powered
  input  wire  [17:0]  ret_cn,       // retention save request
  input  wire  [17:0]  init_cn,      // power-up init
  input  wire  [17:0]  iso_cn,       // isolation enable
  input  wire  [17:0]  rdy_cn,       // domain ready (not power-gated)
  // instruction memory
  input  wire  [31:0]  imem_rdata,
  output logic [31:0]  imem_addr,
  // data-memory banks
  output logic  [7:0]  dm_idx,
  output logic  [3:0]  dm_we,
  output logic  [3:0]  dm_strb,
  output logic [31:0]  dm_wdata,
  input  wire [127:0]  dm_rdata,
  // event queue
  output logic         evq_pop,
  output logic         evq_cfg_we,
  output logic  [3:0]  evq_cfg_wdata,
  input  wire   [3:0]  evq_count,
  input  wire   [9:0]  evq_head,
  input  wire          evq_ovf,
  input  wire          evq_irq,
  // always-on counters
  input  wire  [31:0]  mcycle,
  input  wire  [31:0]  minstret,
  // retirement trace / status
  output logic         rv_valid,
  output logic [31:0]  rv_pc,
  output logic [31:0]  rv_insn,
  output logic  [4:0]  rv_rd,
  output logic [31:0]  rv_wdata,
  output logic         rv_mem_we,
  output logic [31:0]  rv_mem_addr,
  output logic [31:0]  rv_mem_wdata,
  output logic  [3:0]  rv_mem_strb,
  output logic         tohost_we,
  output logic [31:0]  tohost_data,
  // PMU sensing (isolated at their leaf boundary)
  output logic         we_add,
  output logic         we_logic,
  output logic         we_shift,
  output logic         we_cmp,
  output logic         we_mul,
  output logic         we_div,
  output logic         we_idex,
  output logic         we_core,
  output logic         we_exmem,
  output logic         we_memwb,
  output logic         rfh_we,
  output logic  [3:0]  bank_dem,
  output logic         rfh_dem,
  output logic         id_vld_o,
  output logic  [2:0]  id_unit_o,
  output logic         ex_vld_o,
  output logic  [2:0]  ex_unit_o,
  output logic         mul_busy,
  output logic         div_busy,
  output logic         exmem_vld_o,
  output logic         memwb_vld_o,
  output logic         wfi_sleep,
  output logic         trap_win,
  output logic         pg_stall
);
  //================================================================ CORE-leaf signals
  // IF
  wire [31:0] pc;
  wire        ifid_vld;
  wire [31:0] ifid_pc;
  wire [31:0] ifid_insn;
  wire        if_we;
  // ID
  wire ctl_t  ctl;
  wire [31:0] imm;
  wire  [4:0] rs1;
  wire  [4:0] rs2;
  wire  [4:0] rd;
  wire  [2:0] unit;
  wire        uses_hi;
  // RF
  wire [31:0] r1;
  wire [31:0] r2;
  wire        rflo_we;
  // hazards
  wire        ex_adv_c;
  wire        id_issue;
  wire        idex_vld_we_c;
  wire        pg_stall_c;
  // traps
  wire        irq_take;
  wire        trap_c;
  wire        trap_en;
  wire        mret_en;
  wire        flush;
  wire [31:0] flush_target;
  wire        wfi_flag;
  wire        wfi_en;
  wire        sleep_c;
  wire        trap_win_c;
  // CSR
  wire [31:0] csr_rdata_c;
  wire        st_mie;
  wire        mie_meie;
  wire [31:0] mtvec;
  wire [31:0] mepc;
  wire        csr_we;
  // MEM
  wire        exmem_vld;
  wire [31:0] exmem_pc;
  wire [31:0] exmem_insn;
  wire  [4:0] exmem_rd;
  wire        exmem_wen;
  wire        exmem_load;
  wire [31:0] exmem_res;
  wire        exmem_store;
  wire [31:0] exmem_addr;
  wire [31:0] exmem_sdata;
  wire        mem_stall;
  wire        mem_go;
  wire [31:0] wb_val;
  wire [31:0] st_data;
  wire  [3:0] st_strb;
  wire  [7:0] dm_idx_c;
  wire  [3:0] dm_we_c;
  wire        evq_pop_c;
  wire        evq_cfg_we_c;
  wire        tohost_we_c;
  wire  [3:0] bank_dem_c;
  wire        mem_we;
  // WB
  wire        memwb_vld;
  wire  [4:0] memwb_rd;
  wire        memwb_wen;
  wire [31:0] memwb_wdata;
  wire        wb_we;
  wire        rv_valid_c;
  wire [31:0] rv_pc_c;
  wire [31:0] rv_insn_c;
  wire  [4:0] rv_rd_c;
  wire [31:0] rv_wdata_c;
  wire        rv_mem_we_c;
  wire [31:0] rv_mem_addr_c;
  wire [31:0] rv_mem_wdata_c;
  wire  [3:0] rv_mem_strb_c;
  wire        wb_we_busy;

  //================================================================ CORE -> EX (isolated)
  wire        x_id_load;
  wire        x_idex_vld_we;
  wire [31:0] x_id_pc;
  wire [31:0] x_id_insn;
  wire [31:0] x_id_imm;
  wire [31:0] x_id_r1;
  wire [31:0] x_id_r2;
  wire  [4:0] x_id_rd;
  wire  [4:0] x_id_rs1;
  wire  [4:0] x_id_rs2;
  wire ctl_t  x_id_ctl;
  wire        x_take_trap;
  wire        x_ex_adv;
  wire        x_fw_exmem_vld;
  wire        x_fw_exmem_wen;
  wire  [4:0] x_fw_exmem_rd;
  wire [31:0] x_fw_exmem_res;
  wire        x_fw_memwb_vld;
  wire        x_fw_memwb_wen;
  wire  [4:0] x_fw_memwb_rd;
  wire [31:0] x_fw_memwb_wdata;
  wire [31:0] x_csr_rdata;

  //================================================================ EX -> CORE (isolated in ex_stage)
  wire        ex_vld;
  wire [31:0] ex_pc;
  wire [31:0] ex_insn;
  wire  [4:0] ex_rd;
  wire        ex_wen;
  wire [31:0] ex_res;
  wire        ex_load;
  wire        ex_store;
  wire  [2:0] ex_f3;
  wire [31:0] ex_addr;
  wire [31:0] ex_sdata;
  wire        ex_redirect;
  wire [31:0] ex_target;
  wire        ex_exc;
  wire  [3:0] ex_exc_code;
  wire        ex_mret;
  wire        ex_wfi;
  wire        ex_csr;
  wire [11:0] ex_csr_addr;
  wire [31:0] ex_csr_src;
  wire        ex_csr_wnz;
  wire        ex_stall;
  wire        ex_mdu_started;
  wire  [2:0] ex_unit;

  //================================================================ IF
  if_stage u_if (
    .clk          (gclk_cn[CN_CORE]),
    .rst_n        (rst_n),
    .pd_on        (on_cn[CN_CORE]),
    .pd_ret       (ret_cn[CN_CORE]),
    .pd_init      (init_cn[CN_CORE]),
    .flush        (flush),
    .flush_target (flush_target),
    .id_issue     (id_issue),
    .wfi_flag     (wfi_flag),
    .imem_rdata   (imem_rdata),
    .pc           (pc),
    .ifid_vld     (ifid_vld),
    .ifid_pc      (ifid_pc),
    .ifid_insn    (ifid_insn),
    .we           (if_we)
  );

  //================================================================ ID
  id_stage u_id (
    .ifid_insn (ifid_insn),
    .ctl       (ctl),
    .imm       (imm),
    .rs1       (rs1),
    .rs2       (rs2),
    .rd        (rd),
    .unit      (unit),
    .uses_hi   (uses_hi)
  );

  //================================================================ register file
  regfile u_rf (
    .clk_lo   (gclk_cn[CN_CORE]),
    .clk_hi   (gclk_cn[CN_RFHI]),
    .rst_n    (rst_n),
    .pdc_on   (on_cn[CN_CORE]),
    .pdc_ret  (ret_cn[CN_CORE]),
    .pdc_iso  (iso_cn[CN_CORE]),
    .pdh_on   (on_cn[CN_RFHI]),
    .pdh_ret  (ret_cn[CN_RFHI]),
    .pdh_iso  (iso_cn[CN_RFHI]),
    .rs1      (rs1),
    .rs2      (rs2),
    .wb_we    (wb_we),
    .wb_rd    (memwb_rd),
    .wb_wdata (memwb_wdata),
    .r1       (r1),
    .r2       (r2),
    .rflo_we  (rflo_we),
    .rfh_we   (rfh_we)
  );

  //================================================================ hazards
  hazard_unit u_hz (
    .ifid_vld    (ifid_vld),
    .urs1        (ctl.urs1),
    .urs2        (ctl.urs2),
    .rs1         (rs1),
    .rs2         (rs2),
    .unit        (unit),
    .uses_hi     (uses_hi),
    .ex_vld      (ex_vld),
    .ex_load     (ex_load),
    .ex_rd       (ex_rd),
    .ex_stall    (ex_stall),
    .mem_stall   (mem_stall),
    .flush       (flush),
    .cn_ready    (rdy_cn),
    .ex_adv      (ex_adv_c),
    .id_issue    (id_issue),
    .idex_vld_we (idex_vld_we_c),
    .pg_stall    (pg_stall_c)
  );

  //================================================================ traps / WFI
  trap_unit u_trap (
    .clk            (gclk_cn[CN_CORE]),
    .rst_n          (rst_n),
    .pd_on          (on_cn[CN_CORE]),
    .pd_ret         (ret_cn[CN_CORE]),
    .pd_init        (init_cn[CN_CORE]),
    .st_mie         (st_mie),
    .mie_meie       (mie_meie),
    .mtvec          (mtvec),
    .mepc           (mepc),
    .evq_irq        (evq_irq),
    .ex_vld         (ex_vld),
    .ex_exc         (ex_exc),
    .ex_mret        (ex_mret),
    .ex_wfi         (ex_wfi),
    .ex_redirect    (ex_redirect),
    .ex_target      (ex_target),
    .ex_pc          (ex_pc),
    .ex_mdu_started (ex_mdu_started),
    .ex_adv         (ex_adv_c),
    .ifid_vld       (ifid_vld),
    .exmem_vld      (exmem_vld),
    .memwb_vld      (memwb_vld),
    .irq_take       (irq_take),
    .trap           (trap_c),
    .trap_en        (trap_en),
    .mret_en        (mret_en),
    .flush          (flush),
    .flush_target   (flush_target),
    .wfi_flag       (wfi_flag),
    .wfi_en         (wfi_en),
    .sleep          (sleep_c),
    .trap_win       (trap_win_c)
  );

  //================================================================ CSRs
  csr_unit u_csr (
    .clk         (gclk_cn[CN_CORE]),
    .rst_n       (rst_n),
    .pd_on       (on_cn[CN_CORE]),
    .pd_ret      (ret_cn[CN_CORE]),
    .pd_init     (init_cn[CN_CORE]),
    .ex_csr      (ex_csr),
    .ex_csr_addr (ex_csr_addr),
    .ex_f3       (ex_f3),
    .ex_csr_src  (ex_csr_src),
    .ex_csr_wnz  (ex_csr_wnz),
    .ex_adv      (ex_adv_c),
    .trap        (trap_c),
    .trap_en     (trap_en),
    .mret_en     (mret_en),
    .irq_take    (irq_take),
    .ex_exc_code (ex_exc_code),
    .ex_pc       (ex_pc),
    .evq_irq     (evq_irq),
    .mcycle      (mcycle),
    .minstret    (minstret),
    .csr_rdata   (csr_rdata_c),
    .st_mie      (st_mie),
    .mie_meie    (mie_meie),
    .mtvec       (mtvec),
    .mepc        (mepc),
    .we          (csr_we)
  );

  //================================================================ CORE -> EX isolation
  // one isolation cell per signal leaving the CORE leaf (clamp 0)
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_id_load (.iso(iso_cn[CN_CORE]), .d(id_issue), .q(x_id_load));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_idex_vld_we (.iso(iso_cn[CN_CORE]), .d(idex_vld_we_c), .q(x_idex_vld_we));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_id_pc (.iso(iso_cn[CN_CORE]), .d(ifid_pc), .q(x_id_pc));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_id_insn (.iso(iso_cn[CN_CORE]), .d(ifid_insn), .q(x_id_insn));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_id_imm (.iso(iso_cn[CN_CORE]), .d(imm), .q(x_id_imm));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_id_r1 (.iso(iso_cn[CN_CORE]), .d(r1), .q(x_id_r1));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_id_r2 (.iso(iso_cn[CN_CORE]), .d(r2), .q(x_id_r2));
  iso_clamp #(.W(5), .CLAMP(5'd0)) u_iso_id_rd (.iso(iso_cn[CN_CORE]), .d(rd), .q(x_id_rd));
  iso_clamp #(.W(5), .CLAMP(5'd0)) u_iso_id_rs1 (.iso(iso_cn[CN_CORE]), .d(rs1), .q(x_id_rs1));
  iso_clamp #(.W(5), .CLAMP(5'd0)) u_iso_id_rs2 (.iso(iso_cn[CN_CORE]), .d(rs2), .q(x_id_rs2));
  iso_clamp #(.W(24), .CLAMP(24'd0)) u_iso_id_ctl (.iso(iso_cn[CN_CORE]), .d(ctl), .q(x_id_ctl));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_take_trap (.iso(iso_cn[CN_CORE]), .d(trap_c), .q(x_take_trap));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_ex_adv (.iso(iso_cn[CN_CORE]), .d(ex_adv_c), .q(x_ex_adv));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_fw_exmem_vld (.iso(iso_cn[CN_CORE]), .d(exmem_vld), .q(x_fw_exmem_vld));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_fw_exmem_wen (.iso(iso_cn[CN_CORE]), .d((exmem_wen && !exmem_load)), .q(x_fw_exmem_wen));
  iso_clamp #(.W(5), .CLAMP(5'd0)) u_iso_fw_exmem_rd (.iso(iso_cn[CN_CORE]), .d(exmem_rd), .q(x_fw_exmem_rd));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_fw_exmem_res (.iso(iso_cn[CN_CORE]), .d(exmem_res), .q(x_fw_exmem_res));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_fw_memwb_vld (.iso(iso_cn[CN_CORE]), .d(memwb_vld), .q(x_fw_memwb_vld));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_fw_memwb_wen (.iso(iso_cn[CN_CORE]), .d(memwb_wen), .q(x_fw_memwb_wen));
  iso_clamp #(.W(5), .CLAMP(5'd0)) u_iso_fw_memwb_rd (.iso(iso_cn[CN_CORE]), .d(memwb_rd), .q(x_fw_memwb_rd));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_fw_memwb_wdata (.iso(iso_cn[CN_CORE]), .d(memwb_wdata), .q(x_fw_memwb_wdata));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_csr_rdata (.iso(iso_cn[CN_CORE]), .d(csr_rdata_c), .q(x_csr_rdata));

  //================================================================ EX
  ex_stage u_ex (
    .clk_add_lo     (gclk_cn[CN_ADD_LO]),
    .clk_add_hi     (gclk_cn[CN_ADD_HI]),
    .clk_logic_lo   (gclk_cn[CN_LOGIC_LO]),
    .clk_logic_hi   (gclk_cn[CN_LOGIC_HI]),
    .clk_shift      (gclk_cn[CN_SHIFT]),
    .clk_cmp        (gclk_cn[CN_CMP]),
    .clk_mul        (gclk_cn[CN_MUL]),
    .clk_div        (gclk_cn[CN_DIV]),
    .clk_idex       (gclk_cn[CN_IDEX]),
    .rst_n          (rst_n),
    .pdx_on         (on_cn[CN_IDEX]),
    .pdx_ret        (ret_cn[CN_IDEX]),
    .pdx_init       (init_cn[CN_IDEX]),
    .pdx_iso        (iso_cn[CN_IDEX]),
    .pdh_on         (on_cn[CN_ADD_HI]),
    .pdh_ret        (ret_cn[CN_ADD_HI]),
    .pdh_init       (init_cn[CN_ADD_HI]),
    .pdh_iso        (iso_cn[CN_ADD_HI]),
    .pdm_on         (on_cn[CN_MUL]),
    .pdm_ret        (ret_cn[CN_MUL]),
    .pdm_init       (init_cn[CN_MUL]),
    .pdm_iso        (iso_cn[CN_MUL]),
    .pdd_on         (on_cn[CN_DIV]),
    .pdd_ret        (ret_cn[CN_DIV]),
    .pdd_init       (init_cn[CN_DIV]),
    .pdd_iso        (iso_cn[CN_DIV]),
    .id_load        (x_id_load),
    .idex_vld_we    (x_idex_vld_we),
    .id_pc          (x_id_pc),
    .id_insn        (x_id_insn),
    .id_imm         (x_id_imm),
    .id_r1          (x_id_r1),
    .id_r2          (x_id_r2),
    .id_rd          (x_id_rd),
    .id_rs1         (x_id_rs1),
    .id_rs2         (x_id_rs2),
    .id_ctl         (x_id_ctl),
    .take_trap      (x_take_trap),
    .ex_adv         (x_ex_adv),
    .fw_exmem_vld   (x_fw_exmem_vld),
    .fw_exmem_wen   (x_fw_exmem_wen),
    .fw_exmem_rd    (x_fw_exmem_rd),
    .fw_exmem_res   (x_fw_exmem_res),
    .fw_memwb_vld   (x_fw_memwb_vld),
    .fw_memwb_wen   (x_fw_memwb_wen),
    .fw_memwb_rd    (x_fw_memwb_rd),
    .fw_memwb_wdata (x_fw_memwb_wdata),
    .csr_rdata      (x_csr_rdata),
    .ex_vld         (ex_vld),
    .ex_pc          (ex_pc),
    .ex_insn        (ex_insn),
    .ex_rd          (ex_rd),
    .ex_wen         (ex_wen),
    .ex_res         (ex_res),
    .ex_load        (ex_load),
    .ex_store       (ex_store),
    .ex_f3          (ex_f3),
    .ex_addr        (ex_addr),
    .ex_sdata       (ex_sdata),
    .ex_redirect    (ex_redirect),
    .ex_target      (ex_target),
    .ex_exc         (ex_exc),
    .ex_exc_code    (ex_exc_code),
    .ex_mret        (ex_mret),
    .ex_wfi         (ex_wfi),
    .ex_csr         (ex_csr),
    .ex_csr_addr    (ex_csr_addr),
    .ex_csr_src     (ex_csr_src),
    .ex_csr_wnz     (ex_csr_wnz),
    .ex_stall       (ex_stall),
    .ex_mdu_started (ex_mdu_started),
    .ex_unit        (ex_unit),
    .mul_busy       (mul_busy),
    .div_busy       (div_busy),
    .we_add         (we_add),
    .we_logic       (we_logic),
    .we_shift       (we_shift),
    .we_cmp         (we_cmp),
    .we_mul         (we_mul),
    .we_div         (we_div),
    .we_idex        (we_idex)
  );

  //================================================================ MEM
  mem_stage #(.BANK_MAP(BANK_MAP)) u_mem (
    .clk         (gclk_cn[CN_EXMEM]),
    .rst_n       (rst_n),
    .pd_on       (on_cn[CN_CORE]),
    .pd_ret      (ret_cn[CN_CORE]),
    .pd_init     (init_cn[CN_CORE]),
    .ex_adv      (ex_adv_c),
    .trap        (trap_c),
    .ex_vld      (ex_vld),
    .ex_pc       (ex_pc),
    .ex_insn     (ex_insn),
    .ex_rd       (ex_rd),
    .ex_wen      (ex_wen),
    .ex_res      (ex_res),
    .ex_load     (ex_load),
    .ex_store    (ex_store),
    .ex_f3       (ex_f3),
    .ex_addr     (ex_addr),
    .ex_sdata    (ex_sdata),
    .bank_rdy    (rdy_cn[CN_BANK3:CN_BANK0]),
    .dm_rdata    (dm_rdata),
    .evq_count   (evq_count),
    .evq_head    (evq_head),
    .evq_ovf     (evq_ovf),
    .exmem_vld   (exmem_vld),
    .exmem_pc    (exmem_pc),
    .exmem_insn  (exmem_insn),
    .exmem_rd    (exmem_rd),
    .exmem_wen   (exmem_wen),
    .exmem_load  (exmem_load),
    .exmem_res   (exmem_res),
    .exmem_store (exmem_store),
    .exmem_addr  (exmem_addr),
    .exmem_sdata (exmem_sdata),
    .mem_stall   (mem_stall),
    .mem_go      (mem_go),
    .wb_val      (wb_val),
    .st_data     (st_data),
    .st_strb     (st_strb),
    .dm_idx      (dm_idx_c),
    .dm_we       (dm_we_c),
    .evq_pop     (evq_pop_c),
    .evq_cfg_we  (evq_cfg_we_c),
    .tohost_we   (tohost_we_c),
    .bank_dem    (bank_dem_c),
    .we          (mem_we)
  );

  //================================================================ WB
  wb_stage u_wb (
    .clk          (gclk_cn[CN_MEMWB]),
    .rst_n        (rst_n),
    .pd_on        (on_cn[CN_CORE]),
    .pd_ret       (ret_cn[CN_CORE]),
    .pd_init      (init_cn[CN_CORE]),
    .mem_stall    (mem_stall),
    .mem_go       (mem_go),
    .exmem_vld    (exmem_vld),
    .exmem_pc     (exmem_pc),
    .exmem_insn   (exmem_insn),
    .exmem_rd     (exmem_rd),
    .exmem_wen    (exmem_wen),
    .wb_val       (wb_val),
    .exmem_store  (exmem_store),
    .exmem_addr   (exmem_addr),
    .st_data      (st_data),
    .st_strb      (st_strb),
    .memwb_vld    (memwb_vld),
    .memwb_rd     (memwb_rd),
    .memwb_wen    (memwb_wen),
    .memwb_wdata  (memwb_wdata),
    .wb_we        (wb_we),
    .rv_valid     (rv_valid_c),
    .rv_pc        (rv_pc_c),
    .rv_insn      (rv_insn_c),
    .rv_rd        (rv_rd_c),
    .rv_wdata     (rv_wdata_c),
    .rv_mem_we    (rv_mem_we_c),
    .rv_mem_addr  (rv_mem_addr_c),
    .rv_mem_wdata (rv_mem_wdata_c),
    .rv_mem_strb  (rv_mem_strb_c),
    .we           (wb_we_busy)
  );

  //================================================================ PMU status of the CORE leaf
  logic       we_core_c;
  logic       rfh_dem_c;
  logic [2:0] id_unit_c;

  assign we_core_c = if_we || rflo_we || csr_we || wfi_en;
  assign rfh_dem_c = (ifid_vld && uses_hi) ||
                     (ex_vld && ex_wen && ex_rd[4]) ||
                     (exmem_vld && exmem_wen && exmem_rd[4]) ||
                     (memwb_vld && memwb_wen && memwb_rd[4]);
  assign id_unit_c = ifid_vld ? unit : FU_NONE;

  //================================================================ CORE -> outside isolation
  // memories, event queue, retirement trace, TOHOST (clamp 0)
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_imem_addr (.iso(iso_cn[CN_CORE]), .d(pc), .q(imem_addr));
  iso_clamp #(.W(8), .CLAMP(8'd0)) u_iso_dm_idx (.iso(iso_cn[CN_CORE]), .d(dm_idx_c), .q(dm_idx));
  iso_clamp #(.W(4), .CLAMP(4'd0)) u_iso_dm_we (.iso(iso_cn[CN_CORE]), .d(dm_we_c), .q(dm_we));
  iso_clamp #(.W(4), .CLAMP(4'd0)) u_iso_dm_strb (.iso(iso_cn[CN_CORE]), .d(st_strb), .q(dm_strb));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_dm_wdata (.iso(iso_cn[CN_CORE]), .d(st_data), .q(dm_wdata));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_evq_pop (.iso(iso_cn[CN_CORE]), .d(evq_pop_c), .q(evq_pop));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_evq_cfg_we (.iso(iso_cn[CN_CORE]), .d(evq_cfg_we_c), .q(evq_cfg_we));
  iso_clamp #(.W(4), .CLAMP(4'd0)) u_iso_evq_cfg_wdata (.iso(iso_cn[CN_CORE]), .d(exmem_sdata[3:0]), .q(evq_cfg_wdata));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_rv_valid (.iso(iso_cn[CN_CORE]), .d(rv_valid_c), .q(rv_valid));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_rv_pc (.iso(iso_cn[CN_CORE]), .d(rv_pc_c), .q(rv_pc));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_rv_insn (.iso(iso_cn[CN_CORE]), .d(rv_insn_c), .q(rv_insn));
  iso_clamp #(.W(5), .CLAMP(5'd0)) u_iso_rv_rd (.iso(iso_cn[CN_CORE]), .d(rv_rd_c), .q(rv_rd));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_rv_wdata (.iso(iso_cn[CN_CORE]), .d(rv_wdata_c), .q(rv_wdata));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_rv_mem_we (.iso(iso_cn[CN_CORE]), .d(rv_mem_we_c), .q(rv_mem_we));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_rv_mem_addr (.iso(iso_cn[CN_CORE]), .d(rv_mem_addr_c), .q(rv_mem_addr));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_rv_mem_wdata (.iso(iso_cn[CN_CORE]), .d(rv_mem_wdata_c), .q(rv_mem_wdata));
  iso_clamp #(.W(4), .CLAMP(4'd0)) u_iso_rv_mem_strb (.iso(iso_cn[CN_CORE]), .d(rv_mem_strb_c), .q(rv_mem_strb));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_tohost_we (.iso(iso_cn[CN_CORE]), .d(tohost_we_c), .q(tohost_we));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_tohost_data (.iso(iso_cn[CN_CORE]), .d(exmem_sdata), .q(tohost_data));

  // PMU sensing (clamp 0)
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_we_core (.iso(iso_cn[CN_CORE]), .d(we_core_c), .q(we_core));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_we_exmem (.iso(iso_cn[CN_CORE]), .d(mem_we), .q(we_exmem));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_we_memwb (.iso(iso_cn[CN_CORE]), .d(wb_we_busy), .q(we_memwb));
  iso_clamp #(.W(4), .CLAMP(4'd0)) u_iso_bank_dem (.iso(iso_cn[CN_CORE]), .d(bank_dem_c), .q(bank_dem));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_rfh_dem (.iso(iso_cn[CN_CORE]), .d(rfh_dem_c), .q(rfh_dem));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_id_vld_o (.iso(iso_cn[CN_CORE]), .d(ifid_vld), .q(id_vld_o));
  iso_clamp #(.W(3), .CLAMP(3'd0)) u_iso_id_unit_o (.iso(iso_cn[CN_CORE]), .d(id_unit_c), .q(id_unit_o));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_exmem_vld_o (.iso(iso_cn[CN_CORE]), .d(exmem_vld), .q(exmem_vld_o));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_memwb_vld_o (.iso(iso_cn[CN_CORE]), .d(memwb_vld), .q(memwb_vld_o));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_trap_win (.iso(iso_cn[CN_CORE]), .d(trap_win_c), .q(trap_win));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_pg_stall (.iso(iso_cn[CN_CORE]), .d(pg_stall_c), .q(pg_stall));

  // core asleep: clamps to 1 while the CORE leaf is isolated
  iso_clamp #(.W(1), .CLAMP(1'b1)) u_iso_sleep (.iso(iso_cn[CN_CORE]), .d(sleep_c), .q(wfi_sleep));

  // EX-leaf signals for the PMU (already isolated inside ex_stage)
  assign ex_vld_o  = ex_vld;
  assign ex_unit_o = ex_unit;
endmodule : rv32im_core

`default_nettype wire
