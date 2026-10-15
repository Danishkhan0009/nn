//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL, shared by SYRAX (P1) and CARAXES (P2)
// File      : rtl/pkg/fido_pkg.sv
// Package   : fido_pkg
// Content   : configuration codes, clock-net indices, domain maps, execution
//             unit codes, power-management state codes, the decoded control
//             word (ctl_t) and the RV32IM decode / immediate functions.
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
// Compile   : first file of every file list (all other units import it)
//
// Clock nets (CN) - the finest clock / power partition of the design
//   0 ADD_LO   ALU add/sub low half operand regs      (power leaf EX)
//   1 ADD_HI   ALU add/sub high half operand regs     (power leaf ALU_HI)
//   2 LOGIC_LO ALU logic low half operand regs        (power leaf EX)
//   3 LOGIC_HI ALU logic high half operand regs       (power leaf ALU_HI)
//   4 SHIFT    shifter operand regs                   (power leaf EX)
//   5 CMP      comparator operand regs                (power leaf EX)
//   6 MUL      3-cycle multiplier                     (power leaf MUL)
//   7 DIV      iterative divider                      (power leaf DIV)
//   8 IDEX     ID/EX pipeline register                (power leaf EX)
//   9 EXMEM    EX/MEM pipeline register               (power leaf CORE)
//  10 MEMWB    MEM/WB pipeline register               (power leaf CORE)
//  11..14 BANK0..3 data-memory banks                  (power leaf BANKk)
//  15 RFHI     register file bank x16..x31            (power leaf RF_HI)
//  16 EVQ      peripheral event queue                 (always on)
//  17 CORE     PC, IF/ID, RF bank x0..x15, CSRs       (power leaf CORE)
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

package fido_pkg;

  //--------------------------------------------------------------- configuration
  localparam int MODE_BASE    = 0;   // no gating (lock-step reference)
  localparam int MODE_CG      = 1;   // clock gating, reactive policy
  localparam int MODE_PG      = 2;   // power gating, reactive policy
  localparam int MODE_CGPG    = 3;   // clock + power gating, both reactive
  localparam int MODE_CGPG_ML = 4;   // as 3, power-gating decisions by ML models

  localparam int GRAIN_FINE   = 0;
  localparam int GRAIN_COARSE = 1;

  //--------------------------------------------------------------- clock nets
  localparam int NCN         = 18;
  localparam int CN_ADD_LO   = 0;
  localparam int CN_ADD_HI   = 1;
  localparam int CN_LOGIC_LO = 2;
  localparam int CN_LOGIC_HI = 3;
  localparam int CN_SHIFT    = 4;
  localparam int CN_CMP      = 5;
  localparam int CN_MUL      = 6;
  localparam int CN_DIV      = 7;
  localparam int CN_IDEX     = 8;
  localparam int CN_EXMEM    = 9;
  localparam int CN_MEMWB    = 10;
  localparam int CN_BANK0    = 11;
  localparam int CN_BANK1    = 12;
  localparam int CN_BANK2    = 13;
  localparam int CN_BANK3    = 14;
  localparam int CN_RFHI     = 15;
  localparam int CN_EVQ      = 16;
  localparam int CN_CORE     = 17;

  //--------------------------------------------------------------- domain maps
  // clock net -> domain index, 5 bits per net, packed MSB = net 17 ... LSB =
  // net 0; DOM_NONE (31) = the net is not in any domain of that layer.
  //   CG FINE   15 clock domains : D_ADD D_SHIFT D_LOGIC D_CMP D_MUL D_DIV D_IDEX
  //                                D_EXMEM D_MEMWB D_BANK0..3 D_RFHI D_EVQ
  //   CG COARSE  5 clock domains : D_EX D_MEM D_WB D_STORAGE D_CORE
  //   PG FINE    8 power domains : PD_ALU_HI PD_MUL PD_DIV PD_BANK0..3 PD_RF_HI
  //   PG COARSE  3 power domains : PD_EX PD_STORAGE PD_CORE
  localparam logic [4:0]  DOM_NONE = 5'd31;
  localparam logic [89:0] MAP_CG_F = {5'd31, 5'd14, 5'd13, 5'd12, 5'd11, 5'd10, 5'd9, 5'd8, 5'd7,
                                      5'd6,  5'd5,  5'd4,  5'd3,  5'd1,  5'd2,  5'd2, 5'd0, 5'd0};
  localparam logic [89:0] MAP_CG_C = {5'd4,  5'd31, 5'd3,  5'd3,  5'd3,  5'd3,  5'd3, 5'd2, 5'd1,
                                      5'd0,  5'd0,  5'd0,  5'd0,  5'd0,  5'd0,  5'd0, 5'd0, 5'd0};
  localparam logic [89:0] MAP_PG_F = {5'd31, 5'd31, 5'd7,  5'd6,  5'd5,  5'd4,  5'd3, 5'd31, 5'd31,
                                      5'd31, 5'd2,  5'd1,  5'd31, 5'd31, 5'd0,  5'd31, 5'd0, 5'd31};
  localparam logic [89:0] MAP_PG_C = {5'd2,  5'd31, 5'd1,  5'd1,  5'd1,  5'd1,  5'd1, 5'd2, 5'd2,
                                      5'd0,  5'd0,  5'd0,  5'd0,  5'd0,  5'd0,  5'd0, 5'd0, 5'd0};
  // state that must survive power-off: banks, RF-HI, CORE (PC, RF-LO, CSRs)
  localparam logic [17:0] CN_LIVE  = 18'b10_1111_1000_0000_0000;

  localparam int NCG_FINE   = 15;
  localparam int NCG_COARSE = 5;
  localparam int NPG_FINE   = 8;
  localparam int NPG_COARSE = 3;

  //--------------------------------------------------------------- execution units
  localparam logic [2:0] FU_NONE  = 3'd0;
  localparam logic [2:0] FU_ADD   = 3'd1;
  localparam logic [2:0] FU_SHIFT = 3'd2;
  localparam logic [2:0] FU_LOGIC = 3'd3;
  localparam logic [2:0] FU_CMP   = 3'd4;
  localparam logic [2:0] FU_MUL   = 3'd5;
  localparam logic [2:0] FU_DIV   = 3'd6;

  //--------------------------------------------------------------- power management
  // pm_state reported per domain
  localparam logic [2:0] PM_ON     = 3'd0;
  localparam logic [2:0] PM_CG     = 3'd1;
  localparam logic [2:0] PM_PG_RET = 3'd2;
  localparam logic [2:0] PM_PG_OFF = 3'd3;
  localparam logic [2:0] PM_WAKING = 3'd4;
  // policy request class
  localparam logic [1:0] RQ_NONE   = 2'd0;
  localparam logic [1:0] RQ_CG     = 2'd1;
  localparam logic [1:0] RQ_PG_RET = 2'd2;
  localparam logic [1:0] RQ_PG_OFF = 2'd3;

  //--------------------------------------------------------------- decoded control word
  // 24 bits, ID -> EX (bit 0 = wen ... bits 23:21 = funct3)
  typedef struct packed {
    logic [2:0] f3;      // 23:21 funct3
    logic [2:0] unit;    // 20:18 execution unit (FU_*)
    logic       ill;     // 17    illegal instruction
    logic       wfi;     // 16
    logic       mret;    // 15
    logic       ebreak;  // 14
    logic       ecall;   // 13
    logic       csr;     // 12    CSR access
    logic       store;   // 11
    logic       load;    // 10
    logic       br;      //  9    conditional branch
    logic       jalr;    //  8
    logic       jal;     //  7
    logic       auipc;   //  6
    logic       lui;     //  5
    logic       sub;     //  4    SUB / SRA / SRAI
    logic       bimm;    //  3    operand B = immediate
    logic       urs2;    //  2    uses rs2
    logic       urs1;    //  1    uses rs1
    logic       wen;     //  0    writes rd
  } ctl_t;

  //--------------------------------------------------------------- RV32IM decoder
  function automatic ctl_t decode(input logic [31:0] i);
    logic [6:0] op;
    logic [2:0] f3;
    logic [6:0] f7;
    logic       ill;
    ctl_t       c;
    op   = i[6:0];
    f3   = i[14:12];
    f7   = i[31:25];
    ill  = 1'b0;
    c    = '0;
    c.f3 = f3;
    case (op)
      7'b0110011: begin                                   // OP
        c.urs1 = 1'b1; c.urs2 = 1'b1; c.wen = 1'b1;
        if (f7 == 7'b0000001) begin
          c.unit = f3[2] ? FU_DIV : FU_MUL;
        end else if (f7 == 7'b0000000) begin
          case (f3)
            3'd0:    c.unit = FU_ADD;
            3'd1:    c.unit = FU_SHIFT;
            3'd5:    c.unit = FU_SHIFT;
            3'd2:    c.unit = FU_CMP;
            3'd3:    c.unit = FU_CMP;
            default: c.unit = FU_LOGIC;
          endcase
        end else if ((f7 == 7'b0100000) && (f3 == 3'd0)) begin
          c.unit = FU_ADD;   c.sub = 1'b1;
        end else if ((f7 == 7'b0100000) && (f3 == 3'd5)) begin
          c.unit = FU_SHIFT; c.sub = 1'b1;
        end else begin
          ill = 1'b1;
        end
      end
      7'b0010011: begin                                   // OP-IMM
        c.urs1 = 1'b1; c.bimm = 1'b1; c.wen = 1'b1;
        case (f3)
          3'd0: c.unit = FU_ADD;
          3'd1: begin
            if (f7 == 7'b0000000) c.unit = FU_SHIFT;
            else                  ill    = 1'b1;
          end
          3'd5: begin
            if (f7 == 7'b0000000) begin
              c.unit = FU_SHIFT;
            end else if (f7 == 7'b0100000) begin
              c.unit = FU_SHIFT; c.sub = 1'b1;
            end else begin
              ill = 1'b1;
            end
          end
          3'd2:    c.unit = FU_CMP;
          3'd3:    c.unit = FU_CMP;
          default: c.unit = FU_LOGIC;
        endcase
      end
      7'b0110111: begin c.lui   = 1'b1; c.wen = 1'b1; end     // LUI
      7'b0010111: begin c.auipc = 1'b1; c.wen = 1'b1; end     // AUIPC
      7'b1101111: begin c.jal   = 1'b1; c.wen = 1'b1; end     // JAL
      7'b1100111: begin                                       // JALR
        if (f3 == 3'd0) begin
          c.jalr = 1'b1; c.urs1 = 1'b1; c.wen = 1'b1;
        end else begin
          ill = 1'b1;
        end
      end
      7'b1100011: begin                                       // BRANCH
        if ((f3 == 3'd2) || (f3 == 3'd3)) begin
          ill = 1'b1;
        end else begin
          c.br = 1'b1; c.urs1 = 1'b1; c.urs2 = 1'b1; c.unit = FU_CMP;
        end
      end
      7'b0000011: begin                                       // LOAD
        if ((f3 == 3'd3) || (f3 == 3'd6) || (f3 == 3'd7)) begin
          ill = 1'b1;
        end else begin
          c.load = 1'b1; c.urs1 = 1'b1; c.wen = 1'b1;
        end
      end
      7'b0100011: begin                                       // STORE
        if (f3[2] || (f3 == 3'd3)) begin
          ill = 1'b1;
        end else begin
          c.store = 1'b1; c.urs1 = 1'b1; c.urs2 = 1'b1;
        end
      end
      7'b0001111: begin                                       // FENCE = nop
        c.f3 = f3;
      end
      7'b1110011: begin                                       // SYSTEM
        if (f3 == 3'd0) begin
          if      (i == 32'h0000_0073) c.ecall  = 1'b1;
          else if (i == 32'h0010_0073) c.ebreak = 1'b1;
          else if (i == 32'h3020_0073) c.mret   = 1'b1;
          else if (i == 32'h1050_0073) c.wfi    = 1'b1;
          else                         ill      = 1'b1;
        end else if (f3 == 3'd4) begin
          ill = 1'b1;
        end else begin
          c.csr = 1'b1; c.wen = 1'b1;
          c.urs1 = ~f3[2];
        end
      end
      default: ill = 1'b1;
    endcase
    if (ill) begin
      c     = '0;
      c.ill = 1'b1;
    end
    if (i[11:7] == 5'd0) c.wen = 1'b0;
    return c;
  endfunction

  //--------------------------------------------------------------- immediate generator
  function automatic logic [31:0] immgen(input logic [31:0] i);
    logic [31:0] imm;
    case (i[6:0])
      7'b0100011: imm = {{20{i[31]}}, i[31:25], i[11:7]};                       // S
      7'b1100011: imm = {{19{i[31]}}, i[31], i[7], i[30:25], i[11:8], 1'b0};     // B
      7'b0110111: imm = {i[31:12], 12'd0};                                       // U
      7'b0010111: imm = {i[31:12], 12'd0};                                       // U
      7'b1101111: imm = {{11{i[31]}}, i[31], i[19:12], i[20], i[30:21], 1'b0};   // J
      default:    imm = {{20{i[31]}}, i[31:20]};                                 // I
    endcase
    return imm;
  endfunction

endpackage : fido_pkg

`default_nettype wire
