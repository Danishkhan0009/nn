//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog testbench
// File      : tb/fido_tb_env.sv
// Module    : fido_tb_env
// Content   : shared twin-core lock-step environment
//   REF = fido_top MODE=BASE (no gating), DUT = configuration under test.
//   Same program, same event stimulus (delivered relative to each core's own
//   WFI sleep, so both cores retire the same instruction stream).
//
//   fido_tb_env
//   |-- u_prog    fido_tb_programs    assembler, test programs T01..T16, event plan
//   |-- u_ev_ref  fido_tb_event_src   events for the REF core
//   |-- u_ev_dut  fido_tb_event_src   events for the DUT core
//   |-- u_sb      fido_tb_scoreboard  retirement compare REF vs DUT, cycle counts
//   |-- u_mon     fido_tb_monitor     pm_state monitor, protocol checker, ML trace
//   `-- (this module) clock, reset, program load, run control, report
//
// Plusargs : +TEST=n  run only test n (default: all)     +SEED=n  random seed
//            +VERBOSE print every mismatch / checker message
//            +MLTRACE (MODE 4) reactive policy + write ml_trace_Tnn.csv per
//                     test into the run folder (training data for ml/train_ml.py)
// Hierarchy : tb_<cfg> > u_env
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module fido_tb_env
  import fido_pkg::*;
  import fido_tb_pkg::*;
#(
  parameter int    MODE    = 0,
  parameter int    GRAIN   = 0,
  parameter int    WAKE_PG = 4,
  parameter string CFG     = "BASE"
) (
  output logic         clk,
  output logic         rst_n,
  output logic         prog_we,
  output logic  [9:0]  prog_addr,
  output logic [31:0]  prog_data,
  output logic  [3:0]  ref_ev_valid,
  output logic [31:0]  ref_ev_data,
  output logic  [3:0]  dut_ev_valid,
  output logic [31:0]  dut_ev_data,
  output logic  [1:0]  ml_force,
  // REF observation
  input  wire          ref_valid,
  input  wire  [31:0]  ref_pc,
  input  wire  [31:0]  ref_insn,
  input  wire   [4:0]  ref_rd,
  input  wire  [31:0]  ref_wdata,
  input  wire          ref_mem_we,
  input  wire  [31:0]  ref_mem_addr,
  input  wire  [31:0]  ref_mem_wdata,
  input  wire   [3:0]  ref_mem_strb,
  input  wire          ref_wfi,
  // DUT observation
  input  wire          dut_valid,
  input  wire  [31:0]  dut_pc,
  input  wire  [31:0]  dut_insn,
  input  wire   [4:0]  dut_rd,
  input  wire  [31:0]  dut_wdata,
  input  wire          dut_mem_we,
  input  wire  [31:0]  dut_mem_addr,
  input  wire  [31:0]  dut_mem_wdata,
  input  wire   [3:0]  dut_mem_strb,
  input  wire          dut_wfi,
  input  wire  [95:0]  pm_state_bus,
  input  wire  [31:0]  dom_clk_en,
  input  wire  [31:0]  dom_iso,
  input  wire  [31:0]  dom_ret,
  input  wire  [31:0]  dom_pwr,
  input  wire  [31:0]  dom_ack,
  input  wire  [31:0]  dom_busy,
  input  wire  [31:0]  dom_ready,
  input  wire  [31:0]  dom_mispred,
  input  wire          dut_trap_win,
  input  wire          dut_pg_stall,
  input  wire [255:0]  ml_feat
);
  //=========================================================== configuration
  localparam int NCG    = (GRAIN == 0) ? NCG_FINE : NCG_COARSE;
  localparam int NPG    = (GRAIN == 0) ? NPG_FINE : NPG_COARSE;
  localparam int ND     = (MODE == MODE_CG) ? NCG : (MODE == MODE_PG) ? NPG :
                          (MODE >= MODE_CGPG) ? (NCG + NPG) : 0;
  localparam int NTESTS = (MODE >= MODE_CGPG) ? 16 : 11;

  //=========================================================== run control state
  logic   sb_en         = 1'b0;
  logic   mon_en        = 1'b0;
  logic   verbose       = 1'b0;
  logic   mltrace       = 1'b0;
  integer seed          = 1;
  integer sel_test      = 0;
  int     t_pass        = 0;
  int     t_fail        = 0;
  int     chk_err_total = 0;

  //=========================================================== sub-environment
  wire [31:0]   ev_n;
  wire [1023:0] ev_dly_v;
  wire [63:0]   ev_src_v;
  wire [255:0]  ev_dat_v;

  fido_tb_programs #(.MODE(MODE), .GRAIN(GRAIN)) u_prog (
    .ev_n     (ev_n),
    .ev_dly_v (ev_dly_v),
    .ev_src_v (ev_src_v),
    .ev_dat_v (ev_dat_v)
  );

  fido_tb_event_src u_ev_ref (
    .clk      (clk),
    .rst_n    (rst_n),
    .wfi      (ref_wfi),
    .ev_n     (ev_n),
    .ev_dly_v (ev_dly_v),
    .ev_src_v (ev_src_v),
    .ev_dat_v (ev_dat_v),
    .ev_valid (ref_ev_valid),
    .ev_data  (ref_ev_data)
  );

  fido_tb_event_src u_ev_dut (
    .clk      (clk),
    .rst_n    (rst_n),
    .wfi      (dut_wfi),
    .ev_n     (ev_n),
    .ev_dly_v (ev_dly_v),
    .ev_src_v (ev_src_v),
    .ev_dat_v (ev_dat_v),
    .ev_valid (dut_ev_valid),
    .ev_data  (dut_ev_data)
  );

  fido_tb_scoreboard u_sb (
    .clk           (clk),
    .rst_n         (rst_n),
    .en            (sb_en),
    .verbose       (verbose),
    .ref_valid     (ref_valid),
    .ref_pc        (ref_pc),
    .ref_insn      (ref_insn),
    .ref_rd        (ref_rd),
    .ref_wdata     (ref_wdata),
    .ref_mem_we    (ref_mem_we),
    .ref_mem_addr  (ref_mem_addr),
    .ref_mem_wdata (ref_mem_wdata),
    .ref_mem_strb  (ref_mem_strb),
    .dut_valid     (dut_valid),
    .dut_pc        (dut_pc),
    .dut_insn      (dut_insn),
    .dut_rd        (dut_rd),
    .dut_wdata     (dut_wdata),
    .dut_mem_we    (dut_mem_we),
    .dut_mem_addr  (dut_mem_addr),
    .dut_mem_wdata (dut_mem_wdata),
    .dut_mem_strb  (dut_mem_strb)
  );

  fido_tb_monitor #(.MODE(MODE), .GRAIN(GRAIN), .WAKE_PG(WAKE_PG)) u_mon (
    .clk          (clk),
    .rst_n        (rst_n),
    .en           (mon_en),
    .verbose      (verbose),
    .mltrace      (mltrace),
    .dut_valid    (dut_valid),
    .dut_wfi      (dut_wfi),
    .dut_trap_win (dut_trap_win),
    .dut_pg_stall (dut_pg_stall),
    .pm_state_bus (pm_state_bus),
    .dom_clk_en   (dom_clk_en),
    .dom_iso      (dom_iso),
    .dom_ret      (dom_ret),
    .dom_pwr      (dom_pwr),
    .dom_ack      (dom_ack),
    .dom_busy     (dom_busy),
    .dom_ready    (dom_ready),
    .dom_mispred  (dom_mispred),
    .ml_feat      (ml_feat)
  );

  //=========================================================== clock
  initial clk = 1'b0;
  always #5 clk = ~clk;

  //=========================================================== run control
  task automatic load_and_reset;
    int carry;
    @(negedge clk);
    // samplers that are still enabled (only after the T10 prelude) take this
    // edge first; reset and the sampler disable follow 1 ns later (no clock
    // edge in between), so no sampler races these assignments
    #1;
    rst_n  = 1'b0;
    sb_en  = 1'b0;
    mon_en = 1'b0;
    for (int n = 0; n < 1024; n++) begin
      @(negedge clk);
      prog_we   = 1'b1;
      prog_addr = n[9:0];
      prog_data = u_prog.prog[n];
    end
    @(negedge clk);
    prog_we = 1'b0;
    // reset check: every domain ON while in reset
    for (int n = 0; n < 32; n++) begin
      if (pm_state_bus[3*n +: 3] != PM_ON) begin
        u_mon.chk_err = u_mon.chk_err + 1;
        $display("[%0t] CHECKER: domain %0d not ON during reset", $time, n);
      end
    end
    carry = u_mon.chk_err + u_sb.sb_err;
    u_sb.clear();
    u_mon.clear();
    u_mon.chk_err = carry;
    @(negedge clk);
    rst_n = 1'b1;
    // enable the negedge samplers half a cycle later, so no sampler races
    // the reset release (cycle counts identical on every simulator)
    @(posedge clk);
    sb_en  = 1'b1;
    mon_en = 1'b1;
  endtask

  task automatic wait_done;
    // the done flags and run_cyc are written by the scoreboard on the
    // negative edge; they are polled on the positive edge (half a cycle
    // later), so the end of a test never depends on the order in which a
    // simulator runs processes woken by the same clock edge
    while (!(u_sb.ref_done && u_sb.dut_done) && (u_sb.run_cyc < TIMEOUT)) @(posedge clk);
    repeat (3) @(negedge clk);
    // disable the negedge samplers half a cycle before the next negedge, so
    // no sampler races this assignment (statistics identical on every simulator)
    @(posedge clk);
    sb_en  = 1'b0;
    mon_en = 1'b0;
  endtask

  //=========================================================== report
  task automatic report_test(input int t, input string name);
    logic t_ok;
    int   cn;
    int   dom;
    int   bad_exp;
    int   pct;
    int   npg_entry;
    int   npg_mis;
    int   npg_fp;
    int   ref_cyc;
    int   dut_cyc;
    t_ok    = 1'b1;
    bad_exp = 0;
    ref_cyc = u_sb.ref_cyc;
    dut_cyc = u_sb.dut_cyc;
    if (!(u_sb.ref_done && u_sb.dut_done)) begin
      t_ok = 1'b0;
      $display("  ERROR: timeout (REF done=%0b DUT done=%0b)", u_sb.ref_done, u_sb.dut_done);
    end
    if (u_sb.ref_code != 32'd1) begin
      t_ok = 1'b0;
      $display("  ERROR: REF program failed, code %08h (check %0d)", u_sb.ref_code,
               u_sb.ref_code - 32'h100);
    end
    if (u_sb.dut_code != 32'd1) begin
      t_ok = 1'b0;
      $display("  ERROR: DUT program failed, code %08h (check %0d)", u_sb.dut_code,
               u_sb.dut_code - 32'h100);
    end
    if ((u_sb.sb_err != 0) || (u_sb.ref_ret != u_sb.dut_ret) || (u_sb.f_cnt != 0)) begin
      t_ok = 1'b0;
      $display("  ERROR: scoreboard errors=%0d REF retired=%0d DUT retired=%0d left=%0d",
               u_sb.sb_err, u_sb.ref_ret, u_sb.dut_ret, u_sb.f_cnt);
    end
    if (u_mon.chk_err != 0) begin
      t_ok = 1'b0;
      $display("  ERROR: %0d protocol-checker errors", u_mon.chk_err);
    end
    if ((MODE == MODE_CG) || (MODE == MODE_PG)) begin
      for (int d = 0; d < 4; d++) begin
        cn = (GRAIN == 0) ? u_prog.exp_f[d] : u_prog.exp_c[d];
        if (cn >= 0) begin
          dom = cn2dom(MODE, GRAIN, cn);
          if (dom != 31) begin
            if (u_mon.m_entry[dom] == 0) begin
              bad_exp = bad_exp + 1;
              $display("  ERROR: expected %0s to be gated at least once", dname(MODE, GRAIN, dom));
            end
          end
        end
      end
    end
    if (MODE >= MODE_CGPG) begin
      // clock layer always; power layer for reactive CG+PG, and for ML only
      // where the test forces the decision (an ML model may rightly decide
      // not to power-gate - that is scored in the idle-period table instead)
      for (int d = 0; d < 4; d++) begin
        cn = (GRAIN == 0) ? u_prog.exp_f[d] : u_prog.exp_c[d];
        if (cn >= 0) begin
          dom = cn2cg(GRAIN, cn);
          if ((dom != 31) && (u_mon.m_entry[dom] == 0)) begin
            bad_exp = bad_exp + 1;
            $display("  ERROR: expected %0s to be gated at least once", dname(MODE, GRAIN, dom));
          end
          dom = cn2pg(GRAIN, cn);
          if ((dom != 31) && ((MODE == MODE_CGPG) || u_prog.exp_pg_req) && (u_mon.m_entry[dom] == 0)) begin
            bad_exp = bad_exp + 1;
            $display("  ERROR: expected %0s to be power-gated at least once", dname(MODE, GRAIN, dom));
          end
        end
      end
      npg_entry = 0;
      npg_mis   = 0;
      npg_fp    = 0;
      for (int d = NCG; d < NCG + NPG; d++) begin
        npg_entry = npg_entry + u_mon.m_entry[d];
        npg_mis   = npg_mis + u_mon.m_mis[d];
        npg_fp    = npg_fp + u_mon.cm_fp[d - NCG];
      end
      // T12 (MODE 4): the forced confident decisions must include wrong gates
      // (power-down on an idle shorter than BE_LBL, or a wake inside the
      // break-even window) - and the scoreboard / checker above must be clean
      if ((MODE == MODE_CGPG_ML) && (t == 12) && !mltrace && ((npg_mis + npg_fp) == 0)) begin
        bad_exp = bad_exp + 1;
        $display("  ERROR: forced confident gating produced no wrong gate to recover from");
      end
      // T13 (MODE 4): confidence 0 -> the shell must refuse every power-gating request
      if ((MODE == MODE_CGPG_ML) && (t == 13) && !mltrace && (npg_entry != 0)) begin
        bad_exp = bad_exp + 1;
        $display("  ERROR: %0d power-gating entries with confidence 0", npg_entry);
      end
      // T16 (MODE 3): reactive CG+PG must escalate CG -> PG on the MUL net
      if ((MODE == MODE_CGPG) && (t == 16) && (u_mon.m_esc == 0)) begin
        bad_exp = bad_exp + 1;
        $display("  ERROR: no CG -> PG escalation seen on the MUL clock net");
      end
    end
    if (bad_exp != 0) t_ok = 1'b0;
    chk_err_total = chk_err_total + u_mon.chk_err;
    u_mon.chk_err = 0;

    $display("  retired %0d instr | REF %0d cycles | DUT %0d cycles | overhead %0d.%01d %% | gating stalls %0d",
             u_sb.dut_ret, ref_cyc, dut_cyc,
             ((dut_cyc - ref_cyc) * 100) / ((ref_cyc > 0) ? ref_cyc : 1),
             (((dut_cyc - ref_cyc) * 1000) / ((ref_cyc > 0) ? ref_cyc : 1)) % 10, u_mon.m_stall);
    if (MODE != MODE_BASE) begin
      $display("  domain       entries    wakes   gated%%  mispred  maxwake");
      for (int d = 0; d < ND; d++) begin
        pct = (u_mon.m_gcyc[d] * 100) / ((dut_cyc > 0) ? dut_cyc : 1);
        $display("  %s %8d %8d %8d %8d %8d", dname(MODE, GRAIN, d), u_mon.m_entry[d],
                 u_mon.m_wake[d], pct, u_mon.m_mis[d], u_mon.m_maxl[d]);
      end
    end
    if (MODE >= MODE_CGPG) begin
      $display("  power-gating decisions per idle period (long = idle >= %0d cycles)", BE_LBL);
      $display("  domain     gated+long gated+short  missed-long  kept-short");
      for (int d = 0; d < NPG; d++)
        $display("  %s %10d %11d %12d %11d", pg_name(GRAIN, d), u_mon.cm_tp[d], u_mon.cm_fp[d],
                 u_mon.cm_fn[d], u_mon.cm_tn[d]);
      $display("  CG->PG escalations on the MUL clock net: %0d", u_mon.m_esc);
    end
    if (t_ok) begin
      t_pass = t_pass + 1;
      $display("  RESULT T%02d %0s : PASS", t, name);
    end else begin
      t_fail = t_fail + 1;
      $display("  RESULT T%02d %0s : FAIL", t, name);
    end
    u_sb.sb_err = 0;
  endtask

  //=========================================================== one test
  task automatic run_test(input int t);
    string name;
    int    n;
    int    nongated;
    name = test_name(t);
    u_prog.build(t);
    $display("");
    $display("---------------------------------------------------------------------------");
    $display(" T%02d %0s   [%0s]   program %0d words", t, name, CFG, u_prog.plen);
    $display("---------------------------------------------------------------------------");
    if (u_prog.plen > 1024) $display("  ERROR: program too long");
    ml_force <= mltrace ? 2'd3 : u_prog.t_force;
    if (mltrace && (MODE == MODE_CGPG_ML)) u_mon.trace_open(t);
    if (t == 10) begin
      // prelude: run an idle program, then reset the DUT while it is gated
      u_prog.build_idle_forever();
      load_and_reset();
      n        = 0;
      nongated = 1;
      while ((n < 2000) && (nongated != 0)) begin
        @(negedge clk);
        n        = n + 1;
        nongated = 1;
        for (int k = 0; k < ND; k++)
          if ((pm_state_bus[3*k +: 3] >= PM_PG_RET) ||
              (((MODE == MODE_CG) || (MODE >= MODE_CGPG)) && (pm_state_bus[3*k +: 3] == PM_CG)))
            nongated = 0;
      end
      if (MODE != MODE_BASE)
        $display("  prelude: DUT gated after %0d cycles (%0s), asserting reset now",
                 n, (nongated == 0) ? "yes" : "no");
      u_prog.build(10);
    end
    load_and_reset();
    wait_done();
    u_mon.trace_close();
    report_test(t, name);
  endtask

  //=========================================================== main
  initial begin
    rst_n     = 1'b0;
    prog_we   = 1'b0;
    prog_addr = 10'd0;
    prog_data = 32'd0;
    ml_force  = 2'd0;
    u_sb.clear();
    u_mon.clear();
    if (!$value$plusargs("SEED=%d", seed))     seed     = 1;
    if (!$value$plusargs("TEST=%d", sel_test)) sel_test = 0;
    if ($test$plusargs("VERBOSE")) verbose = 1'b1;
    if ($test$plusargs("MLTRACE")) mltrace = 1'b1;
    u_prog.seed = seed;
    $display("===========================================================================");
    $display(" FIDO V3 shared kit - lock-step testbench   config %0s  (MODE=%0d GRAIN=%0d)", CFG, MODE, GRAIN);
    if (MODE >= MODE_CGPG)
      $display(" REF = fido_top BASE, DUT = %0s, %0d clock + %0d power domains, seed %0d", CFG, NCG, NPG, seed);
    else
      $display(" REF = fido_top BASE, DUT = %0s, %0d gated domains, seed %0d", CFG, ND, seed);
    if (mltrace) $display(" ML trace mode: reactive policy, writing ml_trace_Tnn.csv");
    $display("===========================================================================");
    for (int tn = 1; tn <= NTESTS; tn++) begin
      if ((sel_test == 0) || (sel_test == tn)) run_test(tn);
    end
    $display("");
    $display("===========================================================================");
    $display(" SUMMARY %0s : %0d passed, %0d failed, %0d checker errors", CFG, t_pass, t_fail, chk_err_total);
    if (t_fail == 0) $display(" ALL TESTS PASSED");
    else             $display(" TESTS FAILED");
    $display("===========================================================================");
    $finish;
  end
endmodule : fido_tb_env

`default_nettype wire
