//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog testbench
// File      : tb/fido_tb_pkg.sv
// Package   : fido_tb_pkg
// Content   : bench constants, RV32IM instruction encoders, an independent
//             M-extension reference model, and domain / test names used in
//             the reports.
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

package fido_tb_pkg;
  import fido_pkg::*;

  //--------------------------------------------------------------- bench constants
  localparam int TIMEOUT = 200000;   // cycles per test
  localparam int FIFO_D  = 8192;     // scoreboard depth (REF ahead of DUT)
  localparam int BE_LBL  = 24;       // break-even idle length used for scoring (= ml/train_ml.py)
  localparam int MAX_EV  = 32;       // events per test

  //--------------------------------------------------------------- opcodes
  localparam logic [6:0] OP_R   = 7'b0110011;
  localparam logic [6:0] OP_I   = 7'b0010011;
  localparam logic [6:0] OP_LUI = 7'b0110111;
  localparam logic [6:0] OP_AUI = 7'b0010111;
  localparam logic [6:0] OP_JAL = 7'b1101111;
  localparam logic [6:0] OP_JR  = 7'b1100111;
  localparam logic [6:0] OP_BR  = 7'b1100011;
  localparam logic [6:0] OP_LD  = 7'b0000011;
  localparam logic [6:0] OP_ST  = 7'b0100011;
  localparam logic [6:0] OP_SYS = 7'b1110011;

  localparam logic [31:0] I_ECALL  = 32'h0000_0073;
  localparam logic [31:0] I_EBREAK = 32'h0010_0073;
  localparam logic [31:0] I_MRET   = 32'h3020_0073;
  localparam logic [31:0] I_WFI    = 32'h1050_0073;
  localparam logic [31:0] I_NOP    = 32'h0000_5013;   // srli x0,x0,0 (shift unit, neutral)

  //--------------------------------------------------------------- encoders
  function automatic logic [31:0] enc_r(input logic [6:0] f7, input logic [4:0] rs2,
                                        input logic [4:0] rs1, input logic [2:0] f3,
                                        input logic [4:0] rd, input logic [6:0] op);
    return {f7, rs2, rs1, f3, rd, op};
  endfunction

  function automatic logic [31:0] enc_i(input logic [11:0] imm, input logic [4:0] rs1,
                                        input logic [2:0] f3, input logic [4:0] rd,
                                        input logic [6:0] op);
    return {imm, rs1, f3, rd, op};
  endfunction

  function automatic logic [31:0] enc_s(input logic [11:0] imm, input logic [4:0] rs2,
                                        input logic [4:0] rs1, input logic [2:0] f3);
    return {imm[11:5], rs2, rs1, f3, imm[4:0], OP_ST};
  endfunction

  function automatic logic [31:0] enc_b(input logic [12:0] off, input logic [4:0] rs2,
                                        input logic [4:0] rs1, input logic [2:0] f3);
    return {off[12], off[10:5], rs2, rs1, f3, off[4:1], off[11], OP_BR};
  endfunction

  function automatic logic [31:0] enc_j(input logic [20:0] off, input logic [4:0] rd);
    return {off[20], off[10:1], off[11], off[19:12], rd, OP_JAL};
  endfunction

  //--------------------------------------------------------------- M-extension reference
  // independent of the RTL datapath (expected values of the self-checking programs)
  function automatic logic [31:0] ref_mdu(input logic [2:0] op, input logic [31:0] a,
                                          input logic [31:0] b);
    logic [63:0] sa;
    logic [63:0] sb;
    logic [63:0] za;
    logic [63:0] zb;
    logic [63:0] p;
    logic [31:0] r;
    sa = {{32{a[31]}}, a};
    sb = {{32{b[31]}}, b};
    za = {32'd0, a};
    zb = {32'd0, b};
    case (op)
      3'd0: begin p = za * zb; r = p[31:0];  end
      3'd1: begin p = sa * sb; r = p[63:32]; end
      3'd2: begin p = sa * zb; r = p[63:32]; end
      3'd3: begin p = za * zb; r = p[63:32]; end
      3'd4: begin
        if (b == 32'd0)                                         r = 32'hFFFF_FFFF;
        else if ((a == 32'h8000_0000) && (b == 32'hFFFF_FFFF)) r = 32'h8000_0000;
        else                                                    r = $signed(a) / $signed(b);
      end
      3'd5: begin
        if (b == 32'd0) r = 32'hFFFF_FFFF;
        else            r = a / b;
      end
      3'd6: begin
        if (b == 32'd0)                                         r = a;
        else if ((a == 32'h8000_0000) && (b == 32'hFFFF_FFFF)) r = 32'd0;
        else                                                    r = $signed(a) % $signed(b);
      end
      default: begin
        if (b == 32'd0) r = a;
        else            r = a % b;
      end
    endcase
    return r;
  endfunction

  //--------------------------------------------------------------- names (10 characters)
  function automatic string cg_name(input int grain, input int d);
    string s;
    s = "?         ";
    if (grain == 0) begin
      case (d)
        0:  s = "D_ADD     ";
        1:  s = "D_SHIFT   ";
        2:  s = "D_LOGIC   ";
        3:  s = "D_CMP     ";
        4:  s = "D_MUL     ";
        5:  s = "D_DIV     ";
        6:  s = "D_IDEX    ";
        7:  s = "D_EXMEM   ";
        8:  s = "D_MEMWB   ";
        9:  s = "D_BANK0   ";
        10: s = "D_BANK1   ";
        11: s = "D_BANK2   ";
        12: s = "D_BANK3   ";
        13: s = "D_RFHI    ";
        14: s = "D_EVQ     ";
        default: s = "?         ";
      endcase
    end else begin
      case (d)
        0: s = "D_EX      ";
        1: s = "D_MEM     ";
        2: s = "D_WB      ";
        3: s = "D_STORAGE ";
        4: s = "D_CORE    ";
        default: s = "?         ";
      endcase
    end
    return s;
  endfunction

  function automatic string pg_name(input int grain, input int d);
    string s;
    s = "?         ";
    if (grain == 0) begin
      case (d)
        0: s = "PD_ALU_HI ";
        1: s = "PD_MUL    ";
        2: s = "PD_DIV    ";
        3: s = "PD_BANK0  ";
        4: s = "PD_BANK1  ";
        5: s = "PD_BANK2  ";
        6: s = "PD_BANK3  ";
        7: s = "PD_RF_HI  ";
        default: s = "?         ";
      endcase
    end else begin
      case (d)
        0: s = "PD_EX     ";
        1: s = "PD_STORAGE";
        2: s = "PD_CORE   ";
        default: s = "?         ";
      endcase
    end
    return s;
  endfunction

  // name of observation slot d (MODE 3/4: slots 0..NCG-1 clock, then power domains)
  function automatic string dname(input int mode, input int grain, input int d);
    int ncg;
    ncg = (grain == 0) ? 15 : 5;
    if (mode == 1)                     return cg_name(grain, d);
    else if (mode == 2)                return pg_name(grain, d);
    else if ((mode >= 3) && (d < ncg)) return cg_name(grain, d);
    else if (mode >= 3)                return pg_name(grain, d - ncg);
    else                               return "?         ";
  endfunction

  //--------------------------------------------------------------- domain maps
  // number of observation slots of a configuration
  function automatic int n_slots(input int mode, input int grain);
    int ncg;
    int npg;
    ncg = (grain == 0) ? NCG_FINE : NCG_COARSE;
    npg = (grain == 0) ? NPG_FINE : NPG_COARSE;
    if (mode == MODE_CG)      return ncg;
    else if (mode == MODE_PG) return npg;
    else if (mode >= 3)       return ncg + npg;
    else                      return 0;
  endfunction

  // MODE 1 / 2: domain of clock net cn (31 = not gated)
  function automatic int cn2dom(input int mode, input int grain, input int cn);
    logic [89:0] map;
    if (mode == MODE_CG) map = (grain == 0) ? MAP_CG_F : MAP_CG_C;
    else                 map = (grain == 0) ? MAP_PG_F : MAP_PG_C;
    return int'(map[cn*5 +: 5]);
  endfunction

  // MODE 3 / 4: slot of the clock domain of clock net cn (31 = none)
  function automatic int cn2cg(input int grain, input int cn);
    logic [89:0] map;
    map = (grain == 0) ? MAP_CG_F : MAP_CG_C;
    return int'(map[cn*5 +: 5]);
  endfunction

  // MODE 3 / 4: slot of the power domain of clock net cn (31 = none)
  function automatic int cn2pg(input int grain, input int cn);
    logic [89:0] map;
    int          ncg;
    map = (grain == 0) ? MAP_PG_F : MAP_PG_C;
    ncg = (grain == 0) ? NCG_FINE : NCG_COARSE;
    if (map[cn*5 +: 5] == DOM_NONE) return 31;
    else                            return ncg + int'(map[cn*5 +: 5]);
  endfunction

  // slot d is a clock-gating domain
  function automatic bit is_cg_slot(input int mode, input int grain, input int d);
    int ncg;
    ncg = (grain == 0) ? NCG_FINE : NCG_COARSE;
    return (mode == MODE_CG) || ((mode >= 3) && (d < ncg));
  endfunction

  function automatic string test_name(input int t);
    case (t)
      1:       return "reset_smoke";
      2:       return "alu_fwd_branch";
      3:       return "mul_div";
      4:       return "compute_idle_wake";
      5:       return "short_idle_thrash";
      6:       return "bank_retention";
      7:       return "rf_hi_retention";
      8:       return "wfi_poll_sleep";
      9:       return "wfi_irq_trap";
      10:      return "traps_reset_gated";
      11:      return "random_stress";
      12:      return "ml_confident_wrong";
      13:      return "ml_low_confidence";
      14:      return "ml_sleep_class";
      15:      return "ml_periodic_pattern";
      default: return "cg_to_pg_escalation";
    endcase
  endfunction

endpackage : fido_tb_pkg

`default_nettype wire
