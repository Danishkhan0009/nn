//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog testbench
// File      : tb/fido_tb_programs.sv
// Module    : fido_tb_programs
// Content   : stimulus generator - program memory image, a small RV32IM
//             assembler, the self-checking test programs T01..T16, the
//             peripheral-event plan and the gating expectations of each test.
//             Expected values are computed here, independently of the RTL
//             datapath. A failing check stores its check id to TOHOST.
//   T01..T11 run on every configuration; T12..T16 (ML / CG+PG tests) on
//   MODE 3 (CG+PG) and MODE 4 (CG+PG+ML).
// Hierarchy : tb_<cfg> > u_env (fido_tb_env) > u_prog
// Access    : the environment reads prog[], plen, exp_f[], exp_c[],
//             exp_pg_req, t_force and sets seed hierarchically.
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module fido_tb_programs
  import fido_pkg::*;
  import fido_tb_pkg::*;
#(
  parameter int MODE  = 0,
  parameter int GRAIN = 0
) (
  // event plan (read by the two event sources)
  output int           ev_n,
  output logic [1023:0] ev_dly_v,     // 32 x 32-bit delay (cycles of WFI sleep)
  output logic   [63:0] ev_src_v,     // 32 x 2-bit source
  output logic  [255:0] ev_dat_v      // 32 x 8-bit data
);
  //=========================================================== state
  // (no initial block: the environment builds the first program at time 0;
  //  declaration initialisers run before any process starts)
  logic [31:0] prog [1024];
  int          plen   = 0;
  int          chk_id = 0;
  integer      seed   = 1;     // T11 random seed, set by the environment (+SEED)
  // expectations (clock nets that must be gated at least once)
  int          exp_f [4];
  int          exp_c [4];
  logic        exp_pg_req;     // MODE 4: power layer must also gate (forced tests)
  logic  [1:0] t_force;        // ml_force value of the test

  //=========================================================== assembler
  task automatic emit(input logic [31:0] w);
    if (plen < 1024) prog[plen] = w;
    plen = plen + 1;
  endtask

  task automatic a_r(input logic [6:0] f7, input logic [2:0] f3, input logic [4:0] rd,
                     input logic [4:0] rs1, input logic [4:0] rs2);      // R-type ALU / M
    emit(enc_r(f7, rs2, rs1, f3, rd, OP_R));
  endtask

  task automatic a_i(input logic [2:0] f3, input logic [4:0] rd, input logic [4:0] rs1,
                     input logic [11:0] imm);                            // I-type ALU
    emit(enc_i(imm, rs1, f3, rd, OP_I));
  endtask

  task automatic a_lui(input logic [4:0] rd, input logic [19:0] imm);
    emit({imm, rd, OP_LUI});
  endtask

  task automatic a_auipc(input logic [4:0] rd, input logic [19:0] imm);
    emit({imm, rd, OP_AUI});
  endtask

  task automatic a_ld(input logic [2:0] f3, input logic [4:0] rd, input logic [4:0] rs1,
                      input logic [11:0] off);
    emit(enc_i(off, rs1, f3, rd, OP_LD));
  endtask

  task automatic a_st(input logic [2:0] f3, input logic [4:0] rs2, input logic [4:0] rs1,
                      input logic [11:0] off);
    emit(enc_s(off, rs2, rs1, f3));
  endtask

  task automatic a_br(input logic [2:0] f3, input logic [4:0] rs1, input logic [4:0] rs2,
                      input integer target);                             // to absolute word index
    logic [31:0] off;
    off = (target - plen) * 4;
    emit(enc_b(off[12:0], rs2, rs1, f3));
  endtask

  task automatic a_jal(input logic [4:0] rd, input integer target);
    logic [31:0] off;
    off = (target - plen) * 4;
    emit(enc_j(off[20:0], rd));
  endtask

  task automatic a_jalr(input logic [4:0] rd, input logic [4:0] rs1, input logic [11:0] imm);
    emit(enc_i(imm, rs1, 3'd0, rd, OP_JR));
  endtask

  task automatic a_csr(input logic [2:0] f3, input logic [4:0] rd, input logic [11:0] csr,
                       input logic [4:0] rs1);                           // 1 RW 2 RS 3 RC 5 RWI 6 RSI 7 RCI
    emit(enc_i(csr, rs1, f3, rd, OP_SYS));
  endtask

  task automatic a_li(input logic [4:0] rd, input logic [31:0] v);
    logic [31:0] hi;
    if (($signed(v) >= -2048) && ($signed(v) <= 2047)) begin
      a_i(3'd0, rd, 5'd0, v[11:0]);
    end else begin
      hi = v + 32'h0000_0800;
      a_lui(rd, hi[31:12]);
      if (v[11:0] != 12'd0) a_i(3'd0, rd, rd, v[11:0]);
    end
  endtask

  // check: if (rd != v) store check id to TOHOST (fail stub at word 1)
  task automatic check_eq(input logic [4:0] rd, input logic [31:0] v);
    logic [31:0] id;
    logic [11:0] id12;
    chk_id = chk_id + 1;
    id     = chk_id;
    id12   = 12'h100 + id[11:0];
    a_li(5'd14, v);
    a_i(3'd0, 5'd13, 5'd0, id12);
    a_br(3'd1, rd, 5'd14, 1);
  endtask

  // program frame: word 0 jumps to start, words 1..3 = fail stub
  task automatic prog_begin(input integer start);
    for (int i = 0; i < 1024; i++) prog[i] = 32'd0;
    plen   = 0;
    chk_id = 0;
    a_jal(5'd0, start);
    a_lui(5'd15, 20'h00030);                 // fail stub: x15 = TOHOST
    a_st(3'd2, 5'd13, 5'd15, 12'd0);         //            sw x13 -> TOHOST
    a_jal(5'd0, 3);                          //            spin
  endtask

  task automatic pad_to(input integer w);
    while (plen < w) emit(I_NOP);
  endtask

  task automatic prog_pass;
    a_i(3'd0, 5'd13, 5'd0, 12'd1);
    a_lui(5'd15, 20'h00030);
    a_st(3'd2, 5'd13, 5'd15, 12'd0);
    a_jal(5'd0, plen);
    emit(I_NOP);
    emit(I_NOP);
  endtask

  // idle loop using only LUI / SHIFT / CMP: ADD, LOGIC, MUL, DIV, banks and
  // RF-HI stay idle. inner = ib+1 iterations (ib >= 12), outer = ceil(32/s).
  task automatic idle_loop(input integer ib, input integer s);
    integer     outer;
    integer     inner;
    logic [19:0] li20;
    li20 = 20'd1 << (ib - 12);
    a_lui(5'd6, 20'h80000);
    outer = plen;
    a_lui(5'd5, li20);
    inner = plen;
    a_i(3'd5, 5'd5, 5'd5, 12'd1);                 // srli x5,x5,1
    a_br(3'd1, 5'd5, 5'd0, inner);                // bne  x5,x0,inner
    a_i(3'd5, 5'd6, 5'd6, s[11:0]);               // srli x6,x6,s
    a_br(3'd1, 5'd6, 5'd0, outer);                // bne  x6,x0,outer
    emit(I_NOP);
    emit(I_NOP);
  endtask

  // short gap of about 4*(k) cycles, needs x8 = 0x8000_0000
  task automatic gap(input integer k);
    integer     lp;
    logic [11:0] sh;
    sh = 31 - k;
    a_i(3'd5, 5'd5, 5'd8, sh);                    // srli x5,x8,31-k  -> 1<<k
    lp = plen;
    a_i(3'd5, 5'd5, 5'd5, 12'd1);
    a_br(3'd1, 5'd5, 5'd0, lp);
    emit(I_NOP);
    emit(I_NOP);
  endtask

  task automatic add_event(input integer dly, input integer src, input logic [7:0] dat);
    ev_dly_v[ev_n*32 +: 32] = dly;
    ev_src_v[ev_n*2 +: 2]   = src[1:0];
    ev_dat_v[ev_n*8 +: 8]   = dat;
    ev_n = ev_n + 1;
  endtask

  task automatic clear_plan;
    ev_n = 0;
    for (int i = 0; i < 4; i++) begin
      exp_f[i] = -1;
      exp_c[i] = -1;
    end
    exp_pg_req = 1'b0;
    t_force    = 2'd0;
  endtask

  //=========================================================== test programs
  // T01 reset + smoke
  task automatic build_t01;
    clear_plan;
    prog_begin(8);
    pad_to(8);
    a_li(5'd1, 32'd5);
    a_li(5'd2, 32'd7);
    a_r(7'd0, 3'd0, 5'd3, 5'd1, 5'd2);             // add
    check_eq(5'd3, 32'd12);
    a_r(7'h20, 3'd0, 5'd4, 5'd2, 5'd1);            // sub
    check_eq(5'd4, 32'd2);
    a_lui(5'd10, 20'h00010);
    a_st(3'd2, 5'd3, 5'd10, 12'd0);
    a_ld(3'd2, 5'd7, 5'd10, 12'd0);
    check_eq(5'd7, 32'd12);
    prog_pass;
  endtask

  // T02 RV32I ALU, forwarding, load-use, byte/half memory, branches, jumps
  task automatic build_t02;
    logic [31:0] A, B, C, S, P, W;
    integer      nt, L;
    clear_plan;
    prog_begin(8);
    pad_to(8);
    A = 32'h1234_5678; B = 32'h0F0F_0F0F; C = 32'hFFFF_FFFB; S = 32'd7;
    a_li(5'd1, A); a_li(5'd2, B); a_li(5'd3, C); a_li(5'd4, S);
    a_r(7'd0,  3'd0, 5'd5, 5'd1, 5'd2); check_eq(5'd5, A + B);
    a_r(7'h20, 3'd0, 5'd5, 5'd1, 5'd2); check_eq(5'd5, A - B);
    a_r(7'd0,  3'd4, 5'd5, 5'd1, 5'd2); check_eq(5'd5, A ^ B);
    a_r(7'd0,  3'd6, 5'd5, 5'd1, 5'd2); check_eq(5'd5, A | B);
    a_r(7'd0,  3'd7, 5'd5, 5'd1, 5'd2); check_eq(5'd5, A & B);
    a_r(7'd0,  3'd1, 5'd5, 5'd1, 5'd4); check_eq(5'd5, A << 7);
    a_r(7'd0,  3'd5, 5'd5, 5'd3, 5'd4); check_eq(5'd5, C >> 7);
    a_r(7'h20, 3'd5, 5'd5, 5'd3, 5'd4); check_eq(5'd5, $signed(C) >>> 7);
    a_r(7'd0,  3'd2, 5'd5, 5'd3, 5'd4); check_eq(5'd5, 32'd1);
    a_r(7'd0,  3'd3, 5'd5, 5'd3, 5'd4); check_eq(5'd5, 32'd0);
    a_i(3'd0, 5'd5, 5'd1, 12'hF9C);     check_eq(5'd5, A - 32'd100);
    a_i(3'd2, 5'd5, 5'd3, 12'hFFC);     check_eq(5'd5, 32'd1);
    a_i(3'd3, 5'd5, 5'd4, 12'hFFF);     check_eq(5'd5, 32'd1);
    a_i(3'd4, 5'd5, 5'd1, 12'h7FF);     check_eq(5'd5, A ^ 32'h0000_07FF);
    a_i(3'd6, 5'd5, 5'd2, 12'h0F0);     check_eq(5'd5, B | 32'h0000_00F0);
    a_i(3'd7, 5'd5, 5'd1, 12'h0FF);     check_eq(5'd5, A & 32'h0000_00FF);
    a_i(3'd1, 5'd5, 5'd1, 12'd3);       check_eq(5'd5, A << 3);
    a_i(3'd5, 5'd5, 5'd3, 12'd4);       check_eq(5'd5, C >> 4);
    a_i(3'd5, 5'd5, 5'd3, 12'h404);     check_eq(5'd5, $signed(C) >>> 4);
    a_lui(5'd5, 20'hABCDE);             check_eq(5'd5, 32'hABCD_E000);
    P = plen * 4;
    a_auipc(5'd5, 20'h00012);           check_eq(5'd5, P + 32'h0001_2000);
    // EX->EX forwarding chain and MEM->EX forwarding
    a_i(3'd0, 5'd6, 5'd0, 12'd1);
    for (int i = 0; i < 5; i++) a_r(7'd0, 3'd0, 5'd6, 5'd6, 5'd6);
    check_eq(5'd6, 32'd32);
    a_i(3'd0, 5'd7, 5'd0, 12'd3);
    emit(I_NOP);
    a_r(7'd0, 3'd0, 5'd7, 5'd7, 5'd7);
    check_eq(5'd7, 32'd6);
    // load-use
    a_lui(5'd10, 20'h00010);
    a_st(3'd2, 5'd1, 5'd10, 12'd0);
    a_ld(3'd2, 5'd11, 5'd10, 12'd0);
    a_r(7'd0, 3'd0, 5'd12, 5'd11, 5'd11);
    check_eq(5'd12, A + A);
    // byte / half
    W = 32'hF1E2_D3C4;
    a_li(5'd9, W);
    a_st(3'd2, 5'd9, 5'd10, 12'd4);
    a_ld(3'd0, 5'd11, 5'd10, 12'd4);  check_eq(5'd11, 32'hFFFF_FFC4);
    a_ld(3'd4, 5'd11, 5'd10, 12'd5);  check_eq(5'd11, 32'h0000_00D3);
    a_ld(3'd1, 5'd11, 5'd10, 12'd6);  check_eq(5'd11, 32'hFFFF_F1E2);
    a_ld(3'd5, 5'd11, 5'd10, 12'd4);  check_eq(5'd11, 32'h0000_D3C4);
    a_st(3'd0, 5'd4, 5'd10, 12'd8);
    a_st(3'd0, 5'd3, 5'd10, 12'd9);
    a_st(3'd1, 5'd2, 5'd10, 12'd10);
    a_ld(3'd2, 5'd11, 5'd10, 12'd8);  check_eq(5'd11, 32'h0F0F_FB07);
    // branches: taken skips the addi, not-taken executes it
    nt = 0;
    a_i(3'd0, 5'd12, 5'd0, 12'd0);
    a_br(3'd0, 5'd1, 5'd1, plen + 2); a_i(3'd0, 5'd12, 5'd12, 12'd1);             // beq  T
    a_br(3'd0, 5'd1, 5'd2, plen + 2); a_i(3'd0, 5'd12, 5'd12, 12'd1); nt = nt + 1; // beq  NT
    a_br(3'd1, 5'd1, 5'd2, plen + 2); a_i(3'd0, 5'd12, 5'd12, 12'd1);             // bne  T
    a_br(3'd1, 5'd1, 5'd1, plen + 2); a_i(3'd0, 5'd12, 5'd12, 12'd1); nt = nt + 1; // bne  NT
    a_br(3'd4, 5'd3, 5'd4, plen + 2); a_i(3'd0, 5'd12, 5'd12, 12'd1);             // blt  T
    a_br(3'd4, 5'd4, 5'd3, plen + 2); a_i(3'd0, 5'd12, 5'd12, 12'd1); nt = nt + 1; // blt  NT
    a_br(3'd5, 5'd4, 5'd3, plen + 2); a_i(3'd0, 5'd12, 5'd12, 12'd1);             // bge  T
    a_br(3'd5, 5'd3, 5'd4, plen + 2); a_i(3'd0, 5'd12, 5'd12, 12'd1); nt = nt + 1; // bge  NT
    a_br(3'd6, 5'd4, 5'd3, plen + 2); a_i(3'd0, 5'd12, 5'd12, 12'd1);             // bltu T
    a_br(3'd6, 5'd3, 5'd4, plen + 2); a_i(3'd0, 5'd12, 5'd12, 12'd1); nt = nt + 1; // bltu NT
    a_br(3'd7, 5'd3, 5'd4, plen + 2); a_i(3'd0, 5'd12, 5'd12, 12'd1);             // bgeu T
    a_br(3'd7, 5'd4, 5'd3, plen + 2); a_i(3'd0, 5'd12, 5'd12, 12'd1); nt = nt + 1; // bgeu NT
    check_eq(5'd12, nt);
    // jal / jalr
    L = plen;
    a_jal(5'd9, plen + 2);
    a_i(3'd0, 5'd12, 5'd12, 12'd100);
    check_eq(5'd9, L * 4 + 4);
    L = plen;
    a_auipc(5'd11, 20'd0);
    a_i(3'd0, 5'd11, 5'd11, 12'd16);
    a_jalr(5'd9, 5'd11, 12'd0);
    a_i(3'd0, 5'd12, 5'd12, 12'd100);
    check_eq(5'd9, L * 4 + 12);
    check_eq(5'd12, nt);
    prog_pass;
  endtask

  // T03 M-extension incl. divide-by-zero and overflow, back-to-back MUL/DIV
  task automatic build_t03;
    logic [31:0] pa [10];
    logic [31:0] pb [10];
    logic [31:0] e1, e2, e3;
    logic  [2:0] op;
    clear_plan;
    prog_begin(8);
    pad_to(8);
    pa[0] = 32'd7;          pb[0] = 32'd3;
    pa[1] = 32'hFFFF_FFF9;  pb[1] = 32'd3;
    pa[2] = 32'd7;          pb[2] = 32'hFFFF_FFFD;
    pa[3] = 32'hFFFF_FFF9;  pb[3] = 32'hFFFF_FFFD;
    pa[4] = 32'h8000_0000;  pb[4] = 32'hFFFF_FFFF;
    pa[5] = 32'd5;          pb[5] = 32'd0;
    pa[6] = 32'hFFFF_FFFB;  pb[6] = 32'd0;
    pa[7] = 32'hFFFF_FFFF;  pb[7] = 32'hFFFF_FFFF;
    pa[8] = 32'h1234_5678;  pb[8] = 32'h9ABC_DEF0;
    pa[9] = 32'd0;          pb[9] = 32'd7;
    for (int j = 0; j < 10; j++) begin
      a_li(5'd1, pa[j]);
      a_li(5'd2, pb[j]);
      for (int k = 0; k < 8; k++) begin
        op = k[2:0];
        a_r(7'd1, op, 5'd5, 5'd1, 5'd2);
        check_eq(5'd5, ref_mdu(op, pa[j], pb[j]));
      end
    end
    // dependent back-to-back chain
    a_li(5'd1, 32'd1000);
    a_li(5'd2, 32'd7);
    a_r(7'd1, 3'd4, 5'd5, 5'd1, 5'd2);       // div x5 = 142
    a_r(7'd1, 3'd4, 5'd6, 5'd5, 5'd2);       // div x6 = 20
    a_r(7'd1, 3'd0, 5'd7, 5'd6, 5'd6);       // mul x7 = 400
    a_r(7'd1, 3'd6, 5'd9, 5'd7, 5'd2);       // rem x9 = 1
    e1 = 32'd1000 / 32'd7; e2 = e1 / 32'd7; e3 = e2 * e2;
    check_eq(5'd5, e1);
    check_eq(5'd6, e2);
    check_eq(5'd7, e3);
    check_eq(5'd9, e3 % 32'd7);
    prog_pass;
  endtask

  // T04 compute idle -> gate -> wake (MUL, DIV, ALU high half)
  task automatic build_t04;
    logic [31:0] A, B;
    clear_plan;
    exp_f[0] = CN_MUL; exp_f[1] = CN_DIV; exp_f[2] = CN_ADD_HI;
    exp_c[0] = CN_BANK0;
    prog_begin(8);
    pad_to(8);
    A = 32'h0001_2345; B = 32'h0000_0056;
    a_li(5'd1, A); a_li(5'd2, B);
    idle_loop(16, 8);
    a_r(7'd1, 3'd0, 5'd5, 5'd1, 5'd2);  check_eq(5'd5, A * B);
    a_r(7'd1, 3'd4, 5'd6, 5'd1, 5'd2);  check_eq(5'd6, A / B);
    a_r(7'd0, 3'd0, 5'd7, 5'd1, 5'd2);  check_eq(5'd7, A + B);
    a_r(7'd0, 3'd4, 5'd7, 5'd1, 5'd2);  check_eq(5'd7, A ^ B);
    idle_loop(16, 8);
    a_r(7'd1, 3'd3, 5'd5, 5'd1, 5'd1);  check_eq(5'd5, ref_mdu(3'd3, A, A));
    a_r(7'd1, 3'd6, 5'd6, 5'd1, 5'd2);  check_eq(5'd6, A % B);
    a_r(7'd0, 3'd7, 5'd7, 5'd1, 5'd2);  check_eq(5'd7, A & B);
    a_r(7'd0, 3'd6, 5'd7, 5'd1, 5'd2);  check_eq(5'd7, A | B);
    idle_loop(18, 8);
    a_r(7'd1, 3'd5, 5'd6, 5'd1, 5'd2);  check_eq(5'd6, A / B);
    a_r(7'd1, 3'd0, 5'd5, 5'd6, 5'd2);  check_eq(5'd5, (A / B) * B);
    prog_pass;
  endtask

  // T05 short-idle thrash: MUL / DIV separated by gaps around the thresholds
  task automatic build_t05;
    integer      gl [16];
    logic [31:0] A, B;
    logic [31:0] jj;
    clear_plan;
    prog_begin(8);
    pad_to(8);
    gl[0] = 1;  gl[1] = 2;  gl[2] = 3;  gl[3] = 5;
    gl[4] = 8;  gl[5] = 12; gl[6] = 16; gl[7] = 20;
    gl[8] = 24; gl[9] = 2;  gl[10] = 30; gl[11] = 1;
    gl[12] = 6; gl[13] = 10; gl[14] = 14; gl[15] = 4;
    A = 32'd3; B = 32'd1000;
    a_lui(5'd8, 20'h80000);
    a_li(5'd1, A); a_li(5'd2, B);
    for (int j = 0; j < 16; j++) begin
      jj = j;
      if (jj[0] == 1'b0) a_r(7'd1, 3'd0, 5'd7, 5'd1, 5'd2);    // mul
      else               a_r(7'd1, 3'd5, 5'd9, 5'd2, 5'd1);    // divu
      gap(gl[j]);
    end
    check_eq(5'd7, A * B);
    check_eq(5'd9, B / A);
    for (int j = 0; j < 8; j++) begin
      a_r(7'd1, 3'd0, 5'd7, 5'd7, 5'd1);
      gap(gl[15 - j]);
    end
    check_eq(5'd7, A * B * 3 * 3 * 3 * 3 * 3 * 3 * 3 * 3);
    prog_pass;
  endtask

  // T06 data-memory banks: write all banks, idle, read back (retention), then
  //     work in bank 0 only and read bank 3
  task automatic build_t06;
    logic [31:0] v;
    logic [31:0] o;
    integer      lp;
    clear_plan;
    exp_f[0] = CN_BANK1;
    exp_c[0] = CN_BANK0;
    prog_begin(8);
    pad_to(8);
    a_lui(5'd10, 20'h00010);                  // x10 = 0x0001_0000 (bank 0 base)
    a_i(3'd0, 5'd11, 5'd10, 12'h7FC);         // x11 = 0x0001_07FC
    a_i(3'd0, 5'd11, 5'd11, 12'h004);         // x11 = 0x0001_0800 (bank 2 base)
    for (int k = 0; k < 4; k++) begin
      for (int j = 0; j < 4; j++) begin
        v = 32'hB000_0000 | (k << 16) | (j << 4) | 32'h5;
        a_li(5'd1, v);
        if (k < 2) begin
          o = (k * 32'h400) + j * 4;
          a_st(3'd2, 5'd1, 5'd10, o[11:0]);
        end else begin
          o = ((k - 2) * 32'h400) + j * 4;
          a_st(3'd2, 5'd1, 5'd11, o[11:0]);
        end
      end
    end
    idle_loop(16, 8);
    for (int k = 0; k < 4; k++) begin
      for (int j = 0; j < 4; j++) begin
        v = 32'hB000_0000 | (k << 16) | (j << 4) | 32'h5;
        if (k < 2) begin
          o = (k * 32'h400) + j * 4;
          a_ld(3'd2, 5'd1, 5'd10, o[11:0]);
        end else begin
          o = ((k - 2) * 32'h400) + j * 4;
          a_ld(3'd2, 5'd1, 5'd11, o[11:0]);
        end
        check_eq(5'd1, v);
      end
    end
    // bank-0 only phase
    a_lui(5'd5, 20'h00080);                   // x5 = 1<<19 -> 20 iterations
    lp = plen;
    a_ld(3'd2, 5'd1, 5'd10, 12'd0);
    a_st(3'd2, 5'd1, 5'd10, 12'd32);
    a_i(3'd5, 5'd5, 5'd5, 12'd1);
    a_br(3'd1, 5'd5, 5'd0, lp);
    emit(I_NOP);
    emit(I_NOP);
    a_ld(3'd2, 5'd1, 5'd10, 12'd32);
    check_eq(5'd1, 32'hB000_0005);
    a_ld(3'd2, 5'd1, 5'd11, 12'h40C);
    check_eq(5'd1, 32'hB003_0035);
    prog_pass;
  endtask

  // T07 register-file bank HI retention
  task automatic build_t07;
    logic [31:0] v;
    logic [31:0] jj;
    clear_plan;
    exp_f[0] = CN_RFHI;
    exp_c[0] = CN_RFHI;
    prog_begin(8);
    pad_to(8);
    for (int j = 16; j < 28; j++) begin
      jj = j;
      v  = 32'hA500_0000 | (j << 16) | (j * 3);
      a_li(jj[4:0], v);
    end
    idle_loop(16, 8);
    for (int j = 16; j < 28; j++) begin
      jj = j;
      v  = 32'hA500_0000 | (j << 16) | (j * 3);
      check_eq(jj[4:0], v);
    end
    a_r(7'd0, 3'd0, 5'd16, 5'd16, 5'd17);
    v = (32'hA500_0000 | (32'd16 << 16) | 32'd48) + (32'hA500_0000 | (32'd17 << 16) | 32'd51);
    idle_loop(16, 16);
    check_eq(5'd16, v);
    prog_pass;
  endtask

  // T08 WFI with polling (MIE = 0), batching threshold, long sleep
  task automatic build_t08;
    clear_plan;
    exp_f[0] = CN_MUL; exp_f[1] = CN_BANK0;
    exp_c[0] = CN_CORE;
    add_event(40,  1, 8'h11);
    add_event(60,  2, 8'h22);
    add_event(30,  3, 8'h33);
    add_event(300, 0, 8'h44);
    prog_begin(8);
    pad_to(8);
    a_lui(5'd10, 20'h00020);                  // EVQ base
    a_li(5'd1, 32'h800);
    a_csr(3'd1, 5'd0, 12'h304, 5'd1);         // mie.MEIE = 1
    a_li(5'd2, 32'd2);
    a_st(3'd2, 5'd2, 5'd10, 12'd8);           // threshold 2
    emit(I_WFI);
    a_ld(3'd2, 5'd3, 5'd10, 12'd0);  check_eq(5'd3, 32'd2);
    a_ld(3'd2, 5'd4, 5'd10, 12'd4);  check_eq(5'd4, 32'h8000_0111);
    a_ld(3'd2, 5'd4, 5'd10, 12'd4);  check_eq(5'd4, 32'h8000_0222);
    a_ld(3'd2, 5'd3, 5'd10, 12'd0);  check_eq(5'd3, 32'd0);
    a_li(5'd2, 32'd1);
    a_st(3'd2, 5'd2, 5'd10, 12'd8);           // threshold 1
    emit(I_WFI);
    a_ld(3'd2, 5'd4, 5'd10, 12'd4);  check_eq(5'd4, 32'h8000_0333);
    emit(I_WFI);
    a_ld(3'd2, 5'd4, 5'd10, 12'd4);  check_eq(5'd4, 32'h8000_0044);
    prog_pass;
  endtask

  // T09 WFI with interrupt (MIE = 1): trap, handler pops the event, mret
  task automatic build_t09;
    clear_plan;
    exp_f[0] = CN_MUL;
    exp_c[0] = CN_CORE;
    add_event(25,  1, 8'hA1);
    add_event(50,  2, 8'hB2);
    add_event(200, 3, 8'hC3);
    prog_begin(32);
    // handler at word 4 (mtvec = 16)
    a_csr(3'd2, 5'd11, 12'h342, 5'd0);        // csrr x11, mcause
    a_st(3'd2, 5'd11, 5'd9, 12'd0);
    a_ld(3'd2, 5'd12, 5'd10, 12'd4);          // pop
    a_st(3'd2, 5'd12, 5'd9, 12'd4);
    a_i(3'd0, 5'd9, 5'd9, 12'd8);
    a_i(3'd0, 5'd7, 5'd7, 12'd1);
    emit(I_MRET);
    pad_to(32);
    a_lui(5'd10, 20'h00020);
    a_lui(5'd9, 20'h00010);
    a_i(3'd0, 5'd9, 5'd9, 12'h100);
    a_i(3'd0, 5'd7, 5'd0, 12'd0);
    a_i(3'd0, 5'd6, 5'd0, 12'd0);
    a_li(5'd1, 32'd16);
    a_csr(3'd1, 5'd0, 12'h305, 5'd1);         // mtvec
    a_li(5'd1, 32'h800);
    a_csr(3'd1, 5'd0, 12'h304, 5'd1);         // mie.MEIE
    a_li(5'd2, 32'd1);
    a_st(3'd2, 5'd2, 5'd10, 12'd8);           // threshold 1
    a_csr(3'd6, 5'd0, 12'h300, 5'd8);         // csrsi mstatus, MIE
    emit(I_WFI); a_i(3'd0, 5'd6, 5'd6, 12'd1);
    emit(I_WFI); a_i(3'd0, 5'd6, 5'd6, 12'd1);
    emit(I_WFI); a_i(3'd0, 5'd6, 5'd6, 12'd1);
    a_csr(3'd7, 5'd0, 12'h300, 5'd8);         // csrci mstatus, MIE
    check_eq(5'd7, 32'd3);
    check_eq(5'd6, 32'd3);
    a_lui(5'd9, 20'h00010);
    a_ld(3'd2, 5'd1, 5'd9, 12'h100); check_eq(5'd1, 32'h8000_000B);
    a_ld(3'd2, 5'd1, 5'd9, 12'h104); check_eq(5'd1, 32'h8000_01A1);
    a_ld(3'd2, 5'd1, 5'd9, 12'h10C); check_eq(5'd1, 32'h8000_02B2);
    a_ld(3'd2, 5'd1, 5'd9, 12'h110); check_eq(5'd1, 32'h8000_000B);
    a_ld(3'd2, 5'd1, 5'd9, 12'h114); check_eq(5'd1, 32'h8000_03C3);
    prog_pass;
  endtask

  // T10 synchronous traps (ecall, illegal, ebreak) around gated units
  task automatic build_t10;
    clear_plan;
    prog_begin(32);
    // handler: log mcause, mepc += 4, count
    a_csr(3'd2, 5'd11, 12'h342, 5'd0);
    a_st(3'd2, 5'd11, 5'd9, 12'd0);
    a_i(3'd0, 5'd9, 5'd9, 12'd4);
    a_csr(3'd2, 5'd12, 12'h341, 5'd0);
    a_i(3'd0, 5'd12, 5'd12, 12'd4);
    a_csr(3'd1, 5'd0, 12'h341, 5'd12);
    a_i(3'd0, 5'd7, 5'd7, 12'd1);
    emit(I_MRET);
    pad_to(32);
    a_lui(5'd9, 20'h00010);
    a_i(3'd0, 5'd9, 5'd9, 12'h200);
    a_i(3'd0, 5'd7, 5'd0, 12'd0);
    a_li(5'd1, 32'd16);
    a_csr(3'd1, 5'd0, 12'h305, 5'd1);
    a_li(5'd1, 32'd6);
    a_li(5'd2, 32'd7);
    a_r(7'd1, 3'd0, 5'd5, 5'd1, 5'd2);       // mul 42
    emit(I_ECALL);
    check_eq(5'd5, 32'd42);
    emit(32'hFFFF_FFFF);                     // illegal
    a_r(7'd1, 3'd4, 5'd5, 5'd5, 5'd2);       // div 6
    check_eq(5'd5, 32'd6);
    emit(I_EBREAK);
    idle_loop(16, 8);
    emit(I_ECALL);
    check_eq(5'd7, 32'd4);
    a_lui(5'd9, 20'h00010);
    a_ld(3'd2, 5'd1, 5'd9, 12'h200); check_eq(5'd1, 32'd11);
    a_ld(3'd2, 5'd1, 5'd9, 12'h204); check_eq(5'd1, 32'd2);
    a_ld(3'd2, 5'd1, 5'd9, 12'h208); check_eq(5'd1, 32'd3);
    a_ld(3'd2, 5'd1, 5'd9, 12'h20C); check_eq(5'd1, 32'd11);
    prog_pass;
  endtask

  // prelude for T10: endless idle program used to reset the DUT while gated
  task automatic build_idle_forever;
    integer top;
    clear_plan;
    prog_begin(8);
    pad_to(8);
    top = plen;
    idle_loop(16, 8);
    a_jal(5'd0, top);
    emit(I_NOP);
    emit(I_NOP);
  endtask

  // T11 constrained-random program (REF vs DUT lock-step is the checker)
  task automatic build_t11;
    logic  [4:0] rs [21];
    logic [31:0] rnd;
    logic [31:0] kk;
    integer      n, sel, lp;
    logic  [4:0] rd_, r1_, r2_;
    logic  [2:0] f3_;
    logic [11:0] off;
    clear_plan;
    prog_begin(8);
    pad_to(8);
    rs[0] = 5'd1;  rs[1] = 5'd2;  rs[2] = 5'd3;  rs[3] = 5'd4;  rs[4] = 5'd6;
    rs[5] = 5'd7;  rs[6] = 5'd9;  rs[7] = 5'd12;
    for (int k = 0; k < 12; k++) begin
      kk = k;
      rs[8 + k] = 5'd16 + kk[4:0];
    end
    rs[20] = 5'd0;
    a_lui(5'd8, 20'h80000);
    a_lui(5'd10, 20'h00010);
    a_i(3'd0, 5'd11, 5'd10, 12'h7FC);
    a_i(3'd0, 5'd11, 5'd11, 12'h004);
    for (int k = 0; k < 20; k++) begin
      rnd = $random(seed);
      a_li(rs[k], rnd);
    end
    n = 0;
    while ((n < 300) && (plen < 940)) begin
      sel = {$random(seed)} % 100;
      rd_ = rs[{$random(seed)} % 20];
      r1_ = rs[{$random(seed)} % 21];
      r2_ = rs[{$random(seed)} % 21];
      rnd = $random(seed);
      if (sel < 30) begin
        case ({$random(seed)} % 10)
          0: a_r(7'd0,  3'd0, rd_, r1_, r2_);
          1: a_r(7'h20, 3'd0, rd_, r1_, r2_);
          2: a_r(7'd0,  3'd1, rd_, r1_, r2_);
          3: a_r(7'd0,  3'd2, rd_, r1_, r2_);
          4: a_r(7'd0,  3'd3, rd_, r1_, r2_);
          5: a_r(7'd0,  3'd4, rd_, r1_, r2_);
          6: a_r(7'd0,  3'd5, rd_, r1_, r2_);
          7: a_r(7'h20, 3'd5, rd_, r1_, r2_);
          8: a_r(7'd0,  3'd6, rd_, r1_, r2_);
          default: a_r(7'd0, 3'd7, rd_, r1_, r2_);
        endcase
      end else if (sel < 50) begin
        case ({$random(seed)} % 9)
          0: a_i(3'd0, rd_, r1_, rnd[11:0]);
          1: a_i(3'd2, rd_, r1_, rnd[11:0]);
          2: a_i(3'd3, rd_, r1_, rnd[11:0]);
          3: a_i(3'd4, rd_, r1_, rnd[11:0]);
          4: a_i(3'd6, rd_, r1_, rnd[11:0]);
          5: a_i(3'd7, rd_, r1_, rnd[11:0]);
          6: a_i(3'd1, rd_, r1_, {7'd0, rnd[4:0]});
          7: a_i(3'd5, rd_, r1_, {7'd0, rnd[4:0]});
          default: a_i(3'd5, rd_, r1_, {7'h20, rnd[4:0]});
        endcase
      end else if (sel < 60) begin
        a_r(7'd1, rnd[2:0], rd_, r1_, r2_);
      end else if (sel < 78) begin
        off = {1'b0, rnd[10:2], 2'b00};
        case ({$random(seed)} % 8)
          0: a_ld(3'd2, rd_, (rnd[20] ? 5'd11 : 5'd10), off);
          1: a_st(3'd2, r2_, (rnd[20] ? 5'd11 : 5'd10), off);
          2: a_ld(3'd0, rd_, (rnd[20] ? 5'd11 : 5'd10), off | {10'd0, rnd[22:21]});
          3: a_ld(3'd4, rd_, (rnd[20] ? 5'd11 : 5'd10), off | {10'd0, rnd[22:21]});
          4: a_ld(3'd1, rd_, (rnd[20] ? 5'd11 : 5'd10), off | {10'd0, rnd[22], 1'b0});
          5: a_ld(3'd5, rd_, (rnd[20] ? 5'd11 : 5'd10), off | {10'd0, rnd[22], 1'b0});
          6: a_st(3'd0, r2_, (rnd[20] ? 5'd11 : 5'd10), off | {10'd0, rnd[22:21]});
          default: a_st(3'd1, r2_, (rnd[20] ? 5'd11 : 5'd10), off | {10'd0, rnd[22], 1'b0});
        endcase
      end else if (sel < 88) begin
        gap(3 + ({$random(seed)} % 18));
      end else if (sel < 96) begin
        case ({$random(seed)} % 6)
          0: f3_ = 3'd0;
          1: f3_ = 3'd1;
          2: f3_ = 3'd4;
          3: f3_ = 3'd5;
          4: f3_ = 3'd6;
          default: f3_ = 3'd7;
        endcase
        lp = plen + 3;
        a_br(f3_, r1_, r2_, lp);
        a_r(7'd0, 3'd0, rd_, r1_, r2_);
        a_r(7'd0, 3'd4, rd_, rd_, r2_);
      end else begin
        if (rnd[0]) a_lui(rd_, rnd[31:12]);
        else        a_auipc(rd_, rnd[31:12]);
      end
      n = n + 1;
    end
    prog_pass;
  endtask

  //=========================================================== ML / CG+PG tests (MODE 3 / 4)
  // common: x8 = 0x8000_0000 (gap), x10 = bank0, x11 = bank1, x12 = event queue
  task automatic ml_setup;
    a_lui(5'd8, 20'h80000);
    a_lui(5'd10, 20'h00010);
    a_i(3'd0, 5'd11, 5'd10, 12'h400);
    a_lui(5'd12, 20'h00020);
  endtask

  // enable MEIE (no trap: polling WFI as in T08) and set batching threshold 1
  task automatic ml_wfi_setup;
    a_li(5'd3, 32'h800);
    a_csr(3'd1, 5'd0, 12'h304, 5'd3);
    a_i(3'd0, 5'd4, 5'd0, 12'd1);
    a_st(3'd2, 5'd4, 5'd12, 12'd8);
  endtask

  // T12 confident wrong prediction: ml_force = 1 makes every idle power
  //     domain request a confident power-off. The shell must keep the core
  //     correct, wake within bound, and count the wrong gates as mispredicts.
  task automatic build_t12;
    logic [31:0] o;
    clear_plan;
    t_force    = 2'd1;
    exp_pg_req = 1'b1;
    exp_f[0] = CN_MUL; exp_f[1] = CN_BANK1;
    exp_c[0] = CN_BANK0; exp_c[1] = CN_CORE;
    add_event(100, 1, 8'h5A);
    prog_begin(8);
    pad_to(8);
    ml_setup;
    a_li(5'd1, 32'd7);
    a_li(5'd2, 32'd3);
    a_i(3'd0, 5'd9, 5'd0, 12'd0);
    // note: gap / idle_loop use x5 and x6 as scratch registers
    for (int j = 0; j < 6; j++) begin
      a_r(7'd1, 3'd0, 5'd7, 5'd1, 5'd2);          // mul x7 = 21
      gap(2 + j);
      a_r(7'd1, 3'd4, 5'd6, 5'd7, 5'd2);          // div x6 = 7
      gap(3);
      a_r(7'd0, 3'd0, 5'd9, 5'd9, 5'd6);          // x9 += 7
      o = j * 4;
      a_st(3'd2, 5'd9, 5'd11, o[11:0]);
      gap(4);
    end
    check_eq(5'd9, 32'd42);
    a_ld(3'd2, 5'd7, 5'd11, 12'd20); check_eq(5'd7, 32'd42);
    a_ld(3'd2, 5'd7, 5'd11, 12'd0);  check_eq(5'd7, 32'd7);
    ml_wfi_setup;
    emit(I_WFI);
    a_ld(3'd2, 5'd4, 5'd12, 12'd4);  check_eq(5'd4, 32'h8000_015A);
    prog_pass;
  endtask

  // T13 low confidence: ml_force = 2 sets the model confidence to 0. The shell
  //     must refuse every power-gating request (no PG entry), clock gating
  //     must still work, the program has long idles where PG would pay off.
  task automatic build_t13;
    logic [31:0] A, B;
    clear_plan;
    t_force = 2'd2;
    exp_f[0] = CN_MUL; exp_f[1] = CN_BANK1;
    exp_c[0] = CN_BANK0; exp_c[1] = CN_CORE;
    add_event(150, 2, 8'h3C);
    prog_begin(8);
    pad_to(8);
    ml_setup;
    A = 32'h0000_1234; B = 32'h0000_0056;
    a_li(5'd1, A);
    a_li(5'd2, B);
    a_st(3'd2, 5'd1, 5'd11, 12'd0);
    a_r(7'd1, 3'd0, 5'd5, 5'd1, 5'd2);  check_eq(5'd5, A * B);
    idle_loop(16, 8);
    a_r(7'd1, 3'd0, 5'd6, 5'd1, 5'd2);  check_eq(5'd6, A * B);
    a_ld(3'd2, 5'd7, 5'd11, 12'd0);     check_eq(5'd7, A);
    ml_wfi_setup;
    emit(I_WFI);
    a_ld(3'd2, 5'd4, 5'd12, 12'd4);     check_eq(5'd4, 32'h8000_023C);
    prog_pass;
  endtask

  // T14 sleep classes: three WFI sleeps (short 10, medium 60, long 400 cycles)
  //     with data in three banks; the data must survive every sleep. The idle
  //     table shows which sleeps the policy powered down.
  task automatic build_t14;
    clear_plan;
    exp_f[0] = CN_BANK1;
    exp_c[0] = CN_CORE;
    add_event(10,  0, 8'h11);
    add_event(60,  1, 8'h22);
    add_event(400, 2, 8'h33);
    prog_begin(8);
    pad_to(8);
    ml_setup;
    a_lui(5'd9, 20'h00010);
    a_i(3'd0, 5'd9, 5'd9, 12'h7FC);
    a_i(3'd0, 5'd9, 5'd9, 12'h004);                // x9 = bank2 base
    a_li(5'd1, 32'hA0A0_0001); a_st(3'd2, 5'd1, 5'd10, 12'd0);
    a_li(5'd1, 32'hB1B1_0002); a_st(3'd2, 5'd1, 5'd11, 12'd0);
    a_li(5'd1, 32'hC2C2_0003); a_st(3'd2, 5'd1, 5'd9,  12'd0);
    ml_wfi_setup;
    emit(I_WFI);
    a_ld(3'd2, 5'd4, 5'd12, 12'd4);  check_eq(5'd4, 32'h8000_0011);
    a_ld(3'd2, 5'd1, 5'd10, 12'd0);  check_eq(5'd1, 32'hA0A0_0001);
    emit(I_WFI);
    a_ld(3'd2, 5'd4, 5'd12, 12'd4);  check_eq(5'd4, 32'h8000_0122);
    a_ld(3'd2, 5'd1, 5'd11, 12'd0);  check_eq(5'd1, 32'hB1B1_0002);
    emit(I_WFI);
    a_ld(3'd2, 5'd4, 5'd12, 12'd4);  check_eq(5'd4, 32'h8000_0233);
    a_ld(3'd2, 5'd1, 5'd9,  12'd0);  check_eq(5'd1, 32'hC2C2_0003);
    a_ld(3'd2, 5'd1, 5'd10, 12'd0);  check_eq(5'd1, 32'hA0A0_0001);
    a_ld(3'd2, 5'd1, 5'd11, 12'd0);  check_eq(5'd1, 32'hB1B1_0002);
    prog_pass;
  endtask

  // T15 periodic pattern: 12 x (two dependent MULs, then ~60 idle cycles).
  //     The idle length repeats, which the history features can learn.
  task automatic build_t15;
    integer lp;
    clear_plan;
    exp_f[0] = CN_MUL;
    exp_c[0] = CN_BANK0;
    prog_begin(8);
    pad_to(8);
    ml_setup;
    a_li(5'd1, 32'd3);
    a_li(5'd2, 32'd5);
    a_li(5'd7, 32'd1);
    a_li(5'd3, 32'd12);
    lp = plen;
    a_r(7'd1, 3'd0, 5'd7, 5'd7, 5'd1);             // x7 *= 3
    a_r(7'd1, 3'd0, 5'd9, 5'd7, 5'd2);             // x9 = x7 * 5
    gap(14);
    a_i(3'd0, 5'd3, 5'd3, 12'hFFF);                // x3 -= 1
    a_br(3'd1, 5'd3, 5'd0, lp);
    emit(I_NOP);
    emit(I_NOP);
    check_eq(5'd7, 32'd531441);
    check_eq(5'd9, 32'd2657205);
    prog_pass;
  endtask

  // T16 CG -> PG escalation: a long MUL idle (fine) and a long WFI sleep
  //     (coarse). Reactive CG+PG first clock-gates (8 cycles) then powers off
  //     (16 cycles); MODE 3 must show at least one escalation on the MUL net.
  task automatic build_t16;
    clear_plan;
    exp_f[0] = CN_MUL;
    exp_c[0] = CN_CORE;
    add_event(300, 3, 8'h77);
    prog_begin(8);
    pad_to(8);
    ml_setup;
    a_li(5'd1, 32'd1234);
    a_li(5'd2, 32'd77);
    a_r(7'd1, 3'd0, 5'd9, 5'd1, 5'd2);  check_eq(5'd9, 32'd95018);
    idle_loop(16, 8);                                // uses x5, x6
    a_r(7'd1, 3'd0, 5'd7, 5'd9, 5'd2);  check_eq(5'd7, 32'd7316386);
    ml_wfi_setup;
    emit(I_WFI);
    a_ld(3'd2, 5'd4, 5'd12, 12'd4);     check_eq(5'd4, 32'h8000_0377);
    a_r(7'd1, 3'd0, 5'd6, 5'd1, 5'd1);  check_eq(5'd6, 32'd1522756);
    prog_pass;
  endtask

  //=========================================================== dispatcher
  task automatic build(input int t);
    case (t)
      1:       build_t01;
      2:       build_t02;
      3:       build_t03;
      4:       build_t04;
      5:       build_t05;
      6:       build_t06;
      7:       build_t07;
      8:       build_t08;
      9:       build_t09;
      10:      build_t10;
      11:      build_t11;
      12:      build_t12;
      13:      build_t13;
      14:      build_t14;
      15:      build_t15;
      default: build_t16;
    endcase
  endtask
endmodule : fido_tb_programs

`default_nettype wire
