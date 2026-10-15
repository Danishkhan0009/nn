//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/ex/ex_stage.sv
// Module    : ex_stage
// Content   : EX stage of the RV32IM pipeline
//               u_idex   pipe_reg     ID/EX register              (clock net IDEX)
//               u_fwd    fwd_unit     EX/MEM, MEM/WB -> EX forwarding
//               u_addsub alu_addsub   ADD/SUB low half            (clock net ADD_LO)
//               u_logic  alu_logic    LOGIC low half              (clock net LOGIC_LO)
//               u_alu_hi alu_hi_unit  ADD/LOGIC high halves       (power leaf ALU_HI)
//               u_shift  alu_shift    shifter                     (clock net SHIFT)
//               u_cmp    alu_cmp      compare / branch condition  (clock net CMP)
//               u_mdu    mdu_ctrl     MUL/DIV sequencing          (clock net IDEX)
//               u_mul    mul_unit     3-cycle multiplier          (power leaf MUL)
//               u_div    div_unit     iterative divider           (power leaf DIV)
//             plus result select, branch / jump resolution, AGU, exceptions.
//             Every output crosses the EX power boundary through isolation
//             cells (clamp 0).
// Hierarchy : fido_top > u_core (rv32im_core) > u_ex
// Power leaf: EX (PD_EX in PG COARSE; always on in PG FINE)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module ex_stage
  import fido_pkg::*;
(
  input  wire        clk_add_lo,
  input  wire        clk_add_hi,
  input  wire        clk_logic_lo,
  input  wire        clk_logic_hi,
  input  wire        clk_shift,
  input  wire        clk_cmp,
  input  wire        clk_mul,
  input  wire        clk_div,
  input  wire        clk_idex,
  input  wire        rst_n,
  // power leaf EX
  input  wire        pdx_on,
  input  wire        pdx_ret,
  input  wire        pdx_init,
  input  wire        pdx_iso,
  // power leaf ALU_HI
  input  wire        pdh_on,
  input  wire        pdh_ret,
  input  wire        pdh_init,
  input  wire        pdh_iso,
  // power leaf MUL
  input  wire        pdm_on,
  input  wire        pdm_ret,
  input  wire        pdm_init,
  input  wire        pdm_iso,
  // power leaf DIV
  input  wire        pdd_on,
  input  wire        pdd_ret,
  input  wire        pdd_init,
  input  wire        pdd_iso,
  // from ID (isolated at the CORE boundary)
  input  wire        id_load,
  input  wire        idex_vld_we,
  input  wire [31:0] id_pc,
  input  wire [31:0] id_insn,
  input  wire [31:0] id_imm,
  input  wire [31:0] id_r1,
  input  wire [31:0] id_r2,
  input  wire  [4:0] id_rd,
  input  wire  [4:0] id_rs1,
  input  wire  [4:0] id_rs2,
  input  wire ctl_t  id_ctl,
  // from core control (isolated at the CORE boundary)
  input  wire        take_trap,
  input  wire        ex_adv,
  input  wire        fw_exmem_vld,
  input  wire        fw_exmem_wen,
  input  wire  [4:0] fw_exmem_rd,
  input  wire [31:0] fw_exmem_res,
  input  wire        fw_memwb_vld,
  input  wire        fw_memwb_wen,
  input  wire  [4:0] fw_memwb_rd,
  input  wire [31:0] fw_memwb_wdata,
  input  wire [31:0] csr_rdata,
  // to core control (isolated)
  output logic        ex_vld,
  output logic [31:0] ex_pc,
  output logic [31:0] ex_insn,
  output logic  [4:0] ex_rd,
  output logic        ex_wen,
  output logic [31:0] ex_res,
  output logic        ex_load,
  output logic        ex_store,
  output logic  [2:0] ex_f3,
  output logic [31:0] ex_addr,
  output logic [31:0] ex_sdata,
  output logic        ex_redirect,
  output logic [31:0] ex_target,
  output logic        ex_exc,
  output logic  [3:0] ex_exc_code,
  output logic        ex_mret,
  output logic        ex_wfi,
  output logic        ex_csr,
  output logic [11:0] ex_csr_addr,
  output logic [31:0] ex_csr_src,
  output logic        ex_csr_wnz,
  output logic        ex_stall,
  output logic        ex_mdu_started,
  output logic  [2:0] ex_unit,
  output logic        mul_busy,
  output logic        div_busy,
  // clock-gating busy (functional write enables) per clock net (isolated)
  output logic        we_add,
  output logic        we_logic,
  output logic        we_shift,
  output logic        we_cmp,
  output logic        we_mul,
  output logic        we_div,
  output logic        we_idex
);
  //================================================================ ID/EX register
  wire [31:0] q_pc;
  wire [31:0] q_insn;
  wire [31:0] q_imm;
  wire [31:0] q_r1;
  wire [31:0] q_r2;
  wire  [4:0] q_rd;
  wire  [4:0] q_rs1;
  wire  [4:0] q_rs2;
  wire [23:0] q_ctl_w;
  wire        q_vld;
  ctl_t       q_ctl;

  pipe_reg #(.W(199)) u_idex (
    .clk     (clk_idex),
    .rst_n   (rst_n),
    .pd_on   (pdx_on),
    .pd_ret  (pdx_ret),
    .pd_init (pdx_init),
    .vld_en  (idex_vld_we),
    .vld_d   (id_load),
    .data_en (id_load),
    .d       ({id_pc, id_insn, id_imm, id_r1, id_r2, id_rd, id_rs1, id_rs2, id_ctl}),
    .vld_q   (q_vld),
    .q       ({q_pc, q_insn, q_imm, q_r1, q_r2, q_rd, q_rs1, q_rs2, q_ctl_w})
  );

  assign q_ctl = ctl_t'(q_ctl_w);

  logic [2:0] unit;
  logic [2:0] f3;
  logic       is_mul;
  logic       is_div;
  logic [2:0] id_unit;

  assign unit    = q_ctl.unit;
  assign f3      = q_ctl.f3;
  assign is_mul  = (unit == FU_MUL);
  assign is_div  = (unit == FU_DIV);
  assign id_unit = id_ctl.unit;

  //================================================================ forwarding
  wire        fa;
  wire        fb;
  wire [31:0] fa_val;
  wire [31:0] fb_val;
  logic [31:0] a_full;
  logic [31:0] b_full;

  fwd_unit u_fwd (
    .urs1        (q_ctl.urs1),
    .urs2        (q_ctl.urs2),
    .rs1         (q_rs1),
    .rs2         (q_rs2),
    .exmem_vld   (fw_exmem_vld),
    .exmem_wen   (fw_exmem_wen),
    .exmem_rd    (fw_exmem_rd),
    .exmem_res   (fw_exmem_res),
    .memwb_vld   (fw_memwb_vld),
    .memwb_wen   (fw_memwb_wen),
    .memwb_rd    (fw_memwb_rd),
    .memwb_wdata (fw_memwb_wdata),
    .fa          (fa),
    .fb          (fb),
    .fa_val      (fa_val),
    .fb_val      (fb_val)
  );

  assign a_full = fa ? fa_val : q_r1;
  assign b_full = fb ? fb_val : q_r2;

  //================================================================ operand dispatch
  // the operand registers of a sub-unit load only when an instruction for
  // that unit issues, so idle sub-units see no write enable (clock gating)
  logic [31:0] id_a;
  logic [31:0] id_b;
  logic        op_we_add;
  logic        op_we_logic;
  logic        op_we_shift;
  logic        op_we_cmp;
  logic        is_sub;

  assign id_a        = id_r1;
  assign id_b        = id_ctl.bimm ? id_imm : id_r2;
  assign op_we_add   = id_load && (id_unit == FU_ADD);
  assign op_we_logic = id_load && (id_unit == FU_LOGIC);
  assign op_we_shift = id_load && (id_unit == FU_SHIFT);
  assign op_we_cmp   = id_load && (id_unit == FU_CMP);
  assign is_sub      = q_ctl.sub && (unit == FU_ADD);

  //================================================================ ALU sub-units
  wire [16:0] sum_lo;
  wire [15:0] lg_lo;
  wire [15:0] add_hi;
  wire [15:0] lg_hi;
  wire [31:0] shift_res;
  wire        slt_bit;
  wire        br_cond;
  logic [31:0] add_res;
  logic [31:0] logic_res;

  alu_addsub u_addsub (
    .clk       (clk_add_lo),
    .rst_n     (rst_n),
    .pd_on     (pdx_on),
    .pd_ret    (pdx_ret),
    .pd_init   (pdx_init),
    .we        (op_we_add),
    .a_d       (id_a[15:0]),
    .b_d       (id_b[15:0]),
    .a_fwd     (fa),
    .a_fwd_val (fa_val[15:0]),
    .b_fwd     (fb),
    .b_fwd_val (fb_val[15:0]),
    .sub       (is_sub),
    .sum_lo    (sum_lo)
  );

  alu_logic u_logic (
    .clk       (clk_logic_lo),
    .rst_n     (rst_n),
    .pd_on     (pdx_on),
    .pd_ret    (pdx_ret),
    .pd_init   (pdx_init),
    .we        (op_we_logic),
    .a_d       (id_a[15:0]),
    .b_d       (id_b[15:0]),
    .a_fwd     (fa),
    .a_fwd_val (fa_val[15:0]),
    .b_fwd     (fb),
    .b_fwd_val (fb_val[15:0]),
    .f3        (f3),
    .res_lo    (lg_lo)
  );

  alu_hi_unit u_alu_hi (
    .clk_add   (clk_add_hi),
    .clk_logic (clk_logic_hi),
    .rst_n     (rst_n),
    .pd_on     (pdh_on),
    .pd_ret    (pdh_ret),
    .pd_init   (pdh_init),
    .iso       (pdh_iso),
    .add_we    (op_we_add),
    .add_a_d   (id_a[31:16]),
    .add_b_d   (id_b[31:16]),
    .logic_we  (op_we_logic),
    .logic_a_d (id_a[31:16]),
    .logic_b_d (id_b[31:16]),
    .a_fwd     (fa),
    .a_fwd_val (fa_val[31:16]),
    .b_fwd     (fb),
    .b_fwd_val (fb_val[31:16]),
    .sub       (is_sub),
    .cin       (sum_lo[16]),
    .f3        (f3),
    .add_res   (add_hi),
    .logic_res (lg_hi)
  );

  alu_shift u_shift (
    .clk       (clk_shift),
    .rst_n     (rst_n),
    .pd_on     (pdx_on),
    .pd_ret    (pdx_ret),
    .pd_init   (pdx_init),
    .we        (op_we_shift),
    .a_d       (id_a),
    .b_d       (id_b[4:0]),
    .a_fwd     (fa),
    .a_fwd_val (fa_val),
    .b_fwd     (fb),
    .b_fwd_val (fb_val[4:0]),
    .f3        (f3),
    .sra       (q_ctl.sub),
    .res       (shift_res)
  );

  alu_cmp u_cmp (
    .clk       (clk_cmp),
    .rst_n     (rst_n),
    .pd_on     (pdx_on),
    .pd_ret    (pdx_ret),
    .pd_init   (pdx_init),
    .we        (op_we_cmp),
    .a_d       (id_a),
    .b_d       (id_b),
    .a_fwd     (fa),
    .a_fwd_val (fa_val),
    .b_fwd     (fb),
    .b_fwd_val (fb_val),
    .f3        (f3),
    .slt_bit   (slt_bit),
    .br_cond   (br_cond)
  );

  assign add_res   = {add_hi, sum_lo[15:0]};
  assign logic_res = {lg_hi, lg_lo};

  //================================================================ MUL / DIV
  wire        start_mdu;
  wire        mdu_started;
  wire        flags_en;
  wire [31:0] mdu_out;
  wire        stall_i;
  wire        mul_done;
  wire [31:0] mul_res;
  wire        div_done;
  wire [31:0] div_res;
  wire        mul_busy_i;
  wire        div_busy_i;
  wire        mul_we_i;
  wire        div_we_i;

  mdu_ctrl u_mdu (
    .clk         (clk_idex),
    .rst_n       (rst_n),
    .pd_on       (pdx_on),
    .pd_ret      (pdx_ret),
    .pd_init     (pdx_init),
    .q_vld       (q_vld),
    .is_mul      (is_mul),
    .is_div      (is_div),
    .take_trap   (take_trap),
    .ex_adv      (ex_adv),
    .mul_done    (mul_done),
    .mul_res     (mul_res),
    .div_done    (div_done),
    .div_res     (div_res),
    .start_mdu   (start_mdu),
    .mdu_started (mdu_started),
    .flags_en    (flags_en),
    .mdu_out     (mdu_out),
    .stall       (stall_i)
  );

  mul_unit u_mul (
    .clk     (clk_mul),
    .rst_n   (rst_n),
    .pd_on   (pdm_on),
    .pd_ret  (pdm_ret),
    .pd_init (pdm_init),
    .iso     (pdm_iso),
    .start   (start_mdu && is_mul),
    .op      (f3[1:0]),
    .a       (a_full),
    .b       (b_full),
    .busy    (mul_busy_i),
    .done    (mul_done),
    .res     (mul_res),
    .we      (mul_we_i)
  );

  div_unit u_div (
    .clk     (clk_div),
    .rst_n   (rst_n),
    .pd_on   (pdd_on),
    .pd_ret  (pdd_ret),
    .pd_init (pdd_init),
    .iso     (pdd_iso),
    .start   (start_mdu && is_div),
    .op      (f3[1:0]),
    .a       (a_full),
    .b       (b_full),
    .busy    (div_busy_i),
    .done    (div_done),
    .res     (div_res),
    .we      (div_we_i)
  );

  //================================================================ result, branch, AGU
  logic [31:0] pc_imm;
  logic [31:0] pc_4;
  logic [31:0] agu;
  logic [31:0] res_i;
  logic        redir_i;
  logic [31:0] target_i;
  logic        exc_i;
  logic  [3:0] code_i;
  logic [31:0] csrsrc_i;

  assign pc_imm = q_pc + q_imm;
  assign pc_4   = q_pc + 32'd4;
  assign agu    = a_full + q_imm;

  always_comb begin
    if (q_ctl.lui)                    res_i = q_imm;
    else if (q_ctl.auipc)             res_i = pc_imm;
    else if (q_ctl.jal || q_ctl.jalr) res_i = pc_4;
    else if (q_ctl.csr)               res_i = csr_rdata;
    else begin
      case (unit)
        FU_ADD:   res_i = add_res;
        FU_SHIFT: res_i = shift_res;
        FU_LOGIC: res_i = logic_res;
        FU_CMP:   res_i = {31'd0, slt_bit};
        FU_MUL:   res_i = mdu_out;
        FU_DIV:   res_i = mdu_out;
        default:  res_i = 32'd0;
      endcase
    end
  end

  assign redir_i  = q_vld && ((q_ctl.br && br_cond) || q_ctl.jal || q_ctl.jalr);
  assign target_i = q_ctl.jalr ? {agu[31:1], 1'b0} : pc_imm;
  assign exc_i    = q_vld && (q_ctl.ecall || q_ctl.ebreak || q_ctl.ill);
  assign code_i   = q_ctl.ill ? 4'd2 : (q_ctl.ebreak ? 4'd3 : 4'd11);
  assign csrsrc_i = f3[2] ? {27'd0, q_rs1} : a_full;

  //================================================================ isolation (EX boundary)
  // one isolation cell per output signal (clamp 0), as UPF set_isolation would place them
  // pipeline data to MEM
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_ex_vld (.iso(pdx_iso), .d(q_vld), .q(ex_vld));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_ex_pc (.iso(pdx_iso), .d(q_pc), .q(ex_pc));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_ex_insn (.iso(pdx_iso), .d(q_insn), .q(ex_insn));
  iso_clamp #(.W(5), .CLAMP(5'd0)) u_iso_ex_rd (.iso(pdx_iso), .d(q_rd), .q(ex_rd));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_ex_wen (.iso(pdx_iso), .d(q_ctl.wen), .q(ex_wen));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_ex_res (.iso(pdx_iso), .d(res_i), .q(ex_res));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_ex_load (.iso(pdx_iso), .d(q_ctl.load), .q(ex_load));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_ex_store (.iso(pdx_iso), .d(q_ctl.store), .q(ex_store));
  iso_clamp #(.W(3), .CLAMP(3'd0)) u_iso_ex_f3 (.iso(pdx_iso), .d(f3), .q(ex_f3));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_ex_addr (.iso(pdx_iso), .d(agu), .q(ex_addr));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_ex_sdata (.iso(pdx_iso), .d(b_full), .q(ex_sdata));
  // control to IF / trap / CSR
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_ex_redirect (.iso(pdx_iso), .d(redir_i), .q(ex_redirect));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_ex_target (.iso(pdx_iso), .d(target_i), .q(ex_target));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_ex_exc (.iso(pdx_iso), .d(exc_i), .q(ex_exc));
  iso_clamp #(.W(4), .CLAMP(4'd0)) u_iso_ex_exc_code (.iso(pdx_iso), .d(code_i), .q(ex_exc_code));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_ex_mret (.iso(pdx_iso), .d((q_vld && q_ctl.mret)), .q(ex_mret));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_ex_wfi (.iso(pdx_iso), .d((q_vld && q_ctl.wfi)), .q(ex_wfi));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_ex_csr (.iso(pdx_iso), .d((q_vld && q_ctl.csr)), .q(ex_csr));
  iso_clamp #(.W(12), .CLAMP(12'd0)) u_iso_ex_csr_addr (.iso(pdx_iso), .d(q_insn[31:20]), .q(ex_csr_addr));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_ex_csr_src (.iso(pdx_iso), .d(csrsrc_i), .q(ex_csr_src));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_ex_csr_wnz (.iso(pdx_iso), .d((q_rs1 != 5'd0)), .q(ex_csr_wnz));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_ex_stall (.iso(pdx_iso), .d(stall_i), .q(ex_stall));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_ex_mdu_started (.iso(pdx_iso), .d(mdu_started), .q(ex_mdu_started));
  // PMU sensing
  iso_clamp #(.W(3), .CLAMP(3'd0)) u_iso_ex_unit (.iso(pdx_iso), .d((q_vld ? unit : FU_NONE)), .q(ex_unit));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_mul_busy (.iso(pdx_iso), .d(mul_busy_i), .q(mul_busy));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_div_busy (.iso(pdx_iso), .d(div_busy_i), .q(div_busy));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_we_add (.iso(pdx_iso), .d(op_we_add), .q(we_add));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_we_logic (.iso(pdx_iso), .d(op_we_logic), .q(we_logic));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_we_shift (.iso(pdx_iso), .d(op_we_shift), .q(we_shift));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_we_cmp (.iso(pdx_iso), .d(op_we_cmp), .q(we_cmp));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_we_mul (.iso(pdx_iso), .d(mul_we_i), .q(we_mul));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_we_div (.iso(pdx_iso), .d(div_we_i), .q(we_div));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_we_idex (.iso(pdx_iso), .d((id_load | idex_vld_we | flags_en)), .q(we_idex));
endmodule : ex_stage

`default_nettype wire
