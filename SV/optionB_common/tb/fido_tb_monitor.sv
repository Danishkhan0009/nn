//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog testbench
// File      : tb/fido_tb_monitor.sv
// Module    : fido_tb_monitor
// Content   : power-management monitor + protocol checker of the DUT
//   monitor : per domain slot - gating entries, wakes, gated cycles,
//             mispredicts, maximum wake latency; gating stall cycles
//   checker : safety-shell protocol rules (simulation form of the SVA list)
//             A1 no clock enable while PG_RET / PG_OFF / WAKING      (SH-1)
//             A2 isolation asserted before the switch opens          (SH-2)
//             A3 retention saved before the switch opens (live)      (SH-3)
//             A4 isolation released only after restore, power + ack  (SH-4)
//             A5 clock never gated while the unit writes             (SEC stand-in)
//             A6 wake completes within WAKE_PG + 8 cycles            (SH-5)
//             A7 no gating accepted during the trap window           (PM-3)
//             A8 no X/Z on DUT control outputs                       (UP-1)
//   MODE 3/4: every idle period of every power domain is scored against
//             BE_LBL (TP gated+long, FP gated+short, FN missed-long,
//             TN kept-short); CG -> PG escalations on the MUL net counted
//   +MLTRACE: one CSV line per cycle and power domain (training data)
// Hierarchy : tb_<cfg> > u_env > u_mon
// Access    : the environment calls clear(), trace_open(), trace_close() and
//             reads / updates the counters.
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module fido_tb_monitor
  import fido_pkg::*;
  import fido_tb_pkg::*;
#(
  parameter int MODE    = 0,
  parameter int GRAIN   = 0,
  parameter int WAKE_PG = 4
) (
  input  wire          clk,
  input  wire          rst_n,
  input  wire          en,            // sampling enabled (set / cleared on posedge)
  input  wire          verbose,
  input  wire          mltrace,
  input  wire          dut_valid,
  input  wire          dut_wfi,
  input  wire          dut_trap_win,
  input  wire          dut_pg_stall,
  input  wire  [95:0]  pm_state_bus,
  input  wire  [31:0]  dom_clk_en,
  input  wire  [31:0]  dom_iso,
  input  wire  [31:0]  dom_ret,
  input  wire  [31:0]  dom_pwr,
  input  wire  [31:0]  dom_ack,
  input  wire  [31:0]  dom_busy,
  input  wire  [31:0]  dom_ready,
  input  wire  [31:0]  dom_mispred,
  input  wire [255:0]  ml_feat
);
  localparam int NCG      = (GRAIN == 0) ? NCG_FINE : NCG_COARSE;
  localparam int NPG      = (GRAIN == 0) ? NPG_FINE : NPG_COARSE;
  localparam int ND       = (MODE == MODE_CG) ? NCG : (MODE == MODE_PG) ? NPG :
                            (MODE >= MODE_CGPG) ? (NCG + NPG) : 0;
  localparam int WAKE_MAX = WAKE_PG + 8;

  //=========================================================== statistics (read by the environment)
  int          m_entry [32];
  int          m_wake  [32];
  int          m_gcyc  [32];
  int          m_mis   [32];
  int          m_lat   [32];
  int          m_maxl  [32];
  int          m_stall = 0;
  int          cm_tp   [8];
  int          cm_fp   [8];
  int          cm_fn   [8];
  int          cm_tn   [8];
  int          m_esc   = 0;
  int          chk_err = 0;

  //=========================================================== history
  logic  [2:0] p_st    [32];
  logic        p_pwr   [32];
  logic        p_iso   [32];
  logic        p_ret   [32];
  logic        p_ack   [32];
  logic        p_trap  = 1'b0;
  int          w_cnt   [32];
  logic        w_flag  [32];
  logic        q_idle  [8];
  logic        q_gated [8];
  int          q_len   [8];

  //=========================================================== ML trace
  integer      tr_fd  = 0;
  int          tr_cyc = 0;

  task automatic clear;
    for (int i = 0; i < 32; i++) begin
      m_entry[i] = 0; m_wake[i] = 0; m_gcyc[i] = 0; m_mis[i] = 0;
      m_lat[i]   = 0; m_maxl[i] = 0; w_cnt[i]  = 0; w_flag[i] = 1'b0;
      p_st[i]  = PM_ON; p_pwr[i] = 1'b1; p_iso[i] = 1'b0; p_ret[i] = 1'b0; p_ack[i] = 1'b1;
    end
    for (int i = 0; i < 8; i++) begin
      q_idle[i] = 1'b0; q_gated[i] = 1'b0; q_len[i] = 0;
      cm_tp[i]  = 0;    cm_fp[i]   = 0;    cm_fn[i] = 0; cm_tn[i] = 0;
    end
    m_esc   = 0;
    p_trap  = 1'b0;
    m_stall = 0;
    chk_err = 0;
    tr_cyc  = 0;
  endtask

  task automatic chk_fail(input int d, input string msg);
    chk_err = chk_err + 1;
    if (verbose || (chk_err <= 10))
      $display("[%0t] CHECKER %0s: %0s", $time, dname(MODE, GRAIN, d), msg);
  endtask

  task automatic trace_open(input int t);
    string tr_name;
    tr_name = $sformatf("ml_trace_T%02d.csv", t);
    tr_fd   = $fopen(tr_name, "w");
    if (tr_fd != 0)
      $fdisplay(tr_fd, "cycle,slot,busy,idle,h1,h2,occ,wfi,evq,live");
  endtask

  task automatic trace_close;
    if (tr_fd != 0) begin
      $fclose(tr_fd);
      tr_fd = 0;
    end
  endtask

  //=========================================================== monitor + checker (negative edge)
  logic [2:0] st_now;

  always @(negedge clk) begin
    if (rst_n && en && (MODE != 0)) begin
      if (dut_pg_stall) m_stall = m_stall + 1;
      for (int dd = 0; dd < ND; dd++) begin
        st_now = pm_state_bus[3*dd +: 3];
        //---------------- monitor
        if ((p_st[dd] == PM_ON) && (st_now != PM_ON)) m_entry[dd] = m_entry[dd] + 1;
        if ((p_st[dd] != PM_ON) && (st_now == PM_ON)) m_wake[dd]  = m_wake[dd] + 1;
        if (st_now != PM_ON) m_gcyc[dd] = m_gcyc[dd] + 1;
        if (dom_mispred[dd]) m_mis[dd] = m_mis[dd] + 1;
        if ((st_now >= PM_PG_RET) && dom_busy[dd]) begin
          m_lat[dd] = m_lat[dd] + 1;
        end else if (st_now == PM_ON) begin
          if (m_lat[dd] > m_maxl[dd]) m_maxl[dd] = m_lat[dd];
          m_lat[dd] = 0;
        end
        //---------------- checker
        if ((st_now >= PM_PG_RET) && dom_clk_en[dd])
          chk_fail(dd, "A1 clock enabled while PG/WAKING");
        if (p_pwr[dd] && !dom_pwr[dd] && !p_iso[dd])
          chk_fail(dd, "A2 switch opened before isolation");
        if (p_pwr[dd] && !dom_pwr[dd] && (st_now == PM_PG_RET) && !p_ret[dd])
          chk_fail(dd, "A3 switch opened before retention save");
        if (p_iso[dd] && !dom_iso[dd] && (p_ret[dd] || !p_ack[dd] || !p_pwr[dd]))
          chk_fail(dd, "A4 isolation released too early");
        if (is_cg_slot(MODE, GRAIN, dd) && dom_busy[dd] && !dom_clk_en[dd])
          chk_fail(dd, "A5 clock gated while unit writes");
        if ((st_now >= PM_PG_RET) && dom_busy[dd]) begin
          w_cnt[dd] = w_cnt[dd] + 1;
          if ((w_cnt[dd] > WAKE_MAX) && !w_flag[dd]) begin
            w_flag[dd] = 1'b1;
            chk_fail(dd, "A6 wake-up exceeded bound");
          end
        end else if (st_now <= PM_CG) begin
          w_cnt[dd] = 0; w_flag[dd] = 1'b0;
        end
        if ((p_st[dd] == PM_ON) && (st_now != PM_ON) && p_trap)
          chk_fail(dd, "A7 gated during trap window");
        // CG -> PG escalation on the MUL clock net (MODE 3 / 4): the power
        // domain switches off while the clock domain is already clock-gated
        if ((MODE >= 3) && (dd == cn2pg(GRAIN, CN_MUL)) && (p_st[dd] == PM_ON) &&
            (st_now >= PM_PG_RET) && (pm_state_bus[3*cn2cg(GRAIN, CN_MUL) +: 3] == PM_CG))
          m_esc = m_esc + 1;
        //---------------- history
        p_st[dd]  = st_now;
        p_pwr[dd] = dom_pwr[dd];
        p_iso[dd] = dom_iso[dd];
        p_ret[dd] = dom_ret[dd];
        p_ack[dd] = dom_ack[dd];
      end
      p_trap = dut_trap_win;
      //---------------- MODE 3 / 4: idle-period scoring of the power layer
      if (MODE >= 3) begin
        for (int dd = 0; dd < NPG; dd++) begin
          if (!dom_busy[NCG + dd]) begin
            if (!q_idle[dd]) begin
              q_idle[dd] = 1'b1; q_len[dd] = 0; q_gated[dd] = 1'b0;
            end
            q_len[dd] = q_len[dd] + 1;
            if (pm_state_bus[3*(NCG + dd) +: 3] != PM_ON) q_gated[dd] = 1'b1;
          end else if (q_idle[dd]) begin
            q_idle[dd] = 1'b0;
            if (q_gated[dd] && (q_len[dd] >= BE_LBL)) cm_tp[dd] = cm_tp[dd] + 1;
            else if (q_gated[dd])                     cm_fp[dd] = cm_fp[dd] + 1;
            else if (q_len[dd] >= BE_LBL)             cm_fn[dd] = cm_fn[dd] + 1;
            else                                      cm_tn[dd] = cm_tn[dd] + 1;
          end
        end
      end
      //---------------- A8: no X/Z on DUT control outputs (catches X leaking
      //                 through a missing isolation clamp, which if(X)
      //                 semantics would otherwise hide)
      if ((^{dut_valid, dut_wfi, dut_trap_win, dut_pg_stall, pm_state_bus,
             dom_clk_en, dom_iso, dom_ret, dom_pwr, dom_ack, dom_busy, dom_ready,
             dom_mispred}) === 1'bx) begin
        chk_err = chk_err + 1;
        if (verbose || (chk_err <= 10))
          $display("[%0t] CHECKER A8: X/Z on DUT control outputs", $time);
      end
    end
  end

  //=========================================================== ML training trace
  // one line per cycle and power domain: features seen by the model + busy
  always @(negedge clk) begin
    if (rst_n && en) begin
      tr_cyc = tr_cyc + 1;
      if (mltrace && (MODE == 4) && (tr_fd != 0)) begin
        for (int tq = 0; tq < NPG; tq++)
          $fdisplay(tr_fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d", tr_cyc, tq,
                    ml_feat[32*tq + 21], ml_feat[32*tq +: 6], ml_feat[32*tq + 6 +: 3],
                    ml_feat[32*tq + 9 +: 3], ml_feat[32*tq + 12 +: 3], ml_feat[32*tq + 15],
                    ml_feat[32*tq + 16 +: 4], ml_feat[32*tq + 20]);
      end
    end
  end
endmodule : fido_tb_monitor

`default_nettype wire
