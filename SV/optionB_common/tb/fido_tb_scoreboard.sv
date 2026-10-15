//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog testbench
// File      : tb/fido_tb_scoreboard.sv
// Module    : fido_tb_scoreboard
// Content   : lock-step retirement scoreboard. Every REF retirement is pushed
//             into a FIFO, every DUT retirement is popped and compared
//             (pc, insn, rd, wdata, store address / data / strobe; 4-state
//             compare, so X from a wrongly powered-down domain is caught).
//             A store to TOHOST ends the program of that core. Also counts
//             the cycles of each core (overhead = DUT vs REF cycles).
// Hierarchy : tb_<cfg> > u_env > u_sb
// Access    : the environment calls clear() and reads the counters.
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module fido_tb_scoreboard
  import fido_tb_pkg::*;
(
  input  wire        clk,
  input  wire        rst_n,
  input  wire        en,            // sampling enabled (set / cleared on posedge)
  input  wire        verbose,
  // REF retirement
  input  wire        ref_valid,
  input  wire [31:0] ref_pc,
  input  wire [31:0] ref_insn,
  input  wire  [4:0] ref_rd,
  input  wire [31:0] ref_wdata,
  input  wire        ref_mem_we,
  input  wire [31:0] ref_mem_addr,
  input  wire [31:0] ref_mem_wdata,
  input  wire  [3:0] ref_mem_strb,
  // DUT retirement
  input  wire        dut_valid,
  input  wire [31:0] dut_pc,
  input  wire [31:0] dut_insn,
  input  wire  [4:0] dut_rd,
  input  wire [31:0] dut_wdata,
  input  wire        dut_mem_we,
  input  wire [31:0] dut_mem_addr,
  input  wire [31:0] dut_mem_wdata,
  input  wire  [3:0] dut_mem_strb
);
  //=========================================================== FIFO
  logic [31:0] f_pc    [FIFO_D];
  logic [31:0] f_insn  [FIFO_D];
  logic  [4:0] f_rd    [FIFO_D];
  logic [31:0] f_wdata [FIFO_D];
  logic        f_mwe   [FIFO_D];
  logic [31:0] f_maddr [FIFO_D];
  logic [31:0] f_mdata [FIFO_D];
  logic  [3:0] f_mstrb [FIFO_D];
  int          f_wp  = 0;
  int          f_rp  = 0;
  int          f_cnt = 0;

  //=========================================================== results (read by the environment)
  logic        ref_done = 1'b0;
  logic        dut_done = 1'b0;
  logic [31:0] ref_code = 32'd0;
  logic [31:0] dut_code = 32'd0;
  int          ref_ret  = 0;
  int          dut_ret  = 0;
  int          sb_err   = 0;
  int          ref_cyc  = 0;
  int          dut_cyc  = 0;
  int          run_cyc  = 0;

  task automatic clear;
    f_wp     = 0;
    f_rp     = 0;
    f_cnt    = 0;
    ref_done = 1'b0;
    dut_done = 1'b0;
    ref_code = 32'd0;
    dut_code = 32'd0;
    ref_ret  = 0;
    dut_ret  = 0;
    sb_err   = 0;
    ref_cyc  = 0;
    dut_cyc  = 0;
    run_cyc  = 0;
  endtask

  //=========================================================== sampling (negative edge)
  always @(negedge clk) begin
    if (rst_n && en) begin
      run_cyc = run_cyc + 1;
      if (!ref_done) ref_cyc = ref_cyc + 1;
      if (!dut_done) dut_cyc = dut_cyc + 1;
      // REF retire -> push
      if (ref_valid && !ref_done) begin
        if (f_cnt >= FIFO_D) begin
          sb_err = sb_err + 1;
          $display("[%0t] SCOREBOARD: REF ahead by more than %0d retirements", $time, FIFO_D);
        end else begin
          f_pc[f_wp]    = ref_pc;
          f_insn[f_wp]  = ref_insn;
          f_rd[f_wp]    = ref_rd;
          f_wdata[f_wp] = ref_wdata;
          f_mwe[f_wp]   = ref_mem_we;
          f_maddr[f_wp] = ref_mem_addr;
          f_mdata[f_wp] = ref_mem_wdata;
          f_mstrb[f_wp] = ref_mem_strb;
          f_wp  = (f_wp + 1) % FIFO_D;
          f_cnt = f_cnt + 1;
        end
        ref_ret = ref_ret + 1;
        if (ref_mem_we && (ref_mem_addr == 32'h0003_0000)) begin
          ref_done = 1'b1;
          ref_code = ref_mem_wdata;
        end
      end
      // DUT retire -> pop and compare
      if (dut_valid && !dut_done) begin
        if (f_cnt == 0) begin
          sb_err = sb_err + 1;
          if (verbose || (sb_err <= 5))
            $display("[%0t] SCOREBOARD: DUT retired pc=%08h with no REF entry", $time, dut_pc);
        end else begin
          if ((dut_pc !== f_pc[f_rp]) || (dut_insn !== f_insn[f_rp]) ||
              (dut_rd !== f_rd[f_rp]) || (dut_wdata !== f_wdata[f_rp]) ||
              (dut_mem_we !== f_mwe[f_rp]) || (dut_mem_addr !== f_maddr[f_rp]) ||
              (dut_mem_wdata !== f_mdata[f_rp]) || (dut_mem_strb !== f_mstrb[f_rp])) begin
            sb_err = sb_err + 1;
            if (verbose || (sb_err <= 5)) begin
              $display("[%0t] SCOREBOARD MISMATCH #%0d (retirement %0d)", $time, sb_err, dut_ret);
              $display("    REF pc=%08h insn=%08h rd=x%0d wdata=%08h st=%0b addr=%08h data=%08h strb=%b",
                       f_pc[f_rp], f_insn[f_rp], f_rd[f_rp], f_wdata[f_rp], f_mwe[f_rp],
                       f_maddr[f_rp], f_mdata[f_rp], f_mstrb[f_rp]);
              $display("    DUT pc=%08h insn=%08h rd=x%0d wdata=%08h st=%0b addr=%08h data=%08h strb=%b",
                       dut_pc, dut_insn, dut_rd, dut_wdata, dut_mem_we, dut_mem_addr,
                       dut_mem_wdata, dut_mem_strb);
            end
          end
          f_rp  = (f_rp + 1) % FIFO_D;
          f_cnt = f_cnt - 1;
        end
        dut_ret = dut_ret + 1;
        if (dut_mem_we && (dut_mem_addr == 32'h0003_0000)) begin
          dut_done = 1'b1;
          dut_code = dut_mem_wdata;
        end
      end
    end
  end
endmodule : fido_tb_scoreboard

`default_nettype wire
