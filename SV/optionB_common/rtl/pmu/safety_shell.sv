//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/pmu/safety_shell.sv
// Module    : safety_shell
// Content   : per-domain FSM. The policy can only request; the shell enforces
//             order and timing. A power-gating request is taken only when the
//             policy's confidence bit is 1.
//               ON -> CG                       (MODE = CG)
//               ON -> ISO -> [SAVE] -> OFF     (MODE = PG; SAVE only when live)
//               OFF -> PWRUP -> INIT -> REST -> ISOREL -> ON
//             pm_state : 0 ON, 1 CG, 2 PG_RET, 3 PG_OFF, 4 WAKING
//             Power-control outputs are registered (glitch-free into the
//             asynchronous power-down / init / retention controls).
// Hierarchy : pmu_top > pm_domain > u_shell
// SVA (later bind file shell_sva.sv): SH-1 .. SH-7
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module safety_shell
  import fido_pkg::*;
#(
  parameter int MODE = MODE_CG,   // MODE_CG or MODE_PG
  parameter int BE   = 8,         // break-even: wake earlier = mispredict
  parameter int HYST = 8          // lock-ON cycles after a mispredict
) (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        busy,
  input  wire        live,
  input  wire        trap_win,
  input  wire  [1:0] req_class,
  input  wire        conf,
  input  wire        ack_pwr,
  output logic       clk_en,
  output logic       iso,
  output logic       ret,
  output logic       pwr_req,
  output logic       init,
  output logic       ready,
  output logic [2:0] pm_state,
  output logic       mispredict
);
  typedef enum logic [3:0] {
    S_ON     = 4'd0,
    S_CG     = 4'd1,
    S_ISO    = 4'd2,
    S_SAVE   = 4'd3,
    S_OFF    = 4'd4,
    S_PWRUP  = 4'd5,
    S_INIT   = 4'd6,
    S_REST   = 4'd7,
    S_ISOREL = 4'd8
  } state_e;

  localparam logic [7:0] BE8 = 8'(BE);
  localparam logic [7:0] HY8 = 8'(HYST);

  state_e     st;
  state_e     st_n;
  logic       tgt_ret;
  logic       tgt_n;
  logic [7:0] age;
  logic [7:0] lock;
  logic       iso_r;
  logic       ret_r;
  logic       pwr_r;
  logic       init_r;

  logic can_gate;
  logic acc_cg;
  logic acc_pg;
  logic gated;

  assign can_gate = !busy && !trap_win && (lock == 8'd0);
  assign acc_cg   = (MODE == MODE_CG) && can_gate && (req_class == RQ_CG);
  // power-gating requests are accepted only with confidence = 1
  // (reactive policy: always 1; ML policy: model confidence bit)
  assign acc_pg   = (MODE == MODE_PG) && can_gate && conf &&
                    ((req_class == RQ_PG_RET) || (req_class == RQ_PG_OFF));
  assign gated    = (st == S_CG) || (st == S_OFF);

  assign mispredict = gated && busy && (age < BE8);

  //---------------------------------------------------------- next state
  always_comb begin
    st_n  = st;
    tgt_n = tgt_ret;
    case (st)
      S_ON: begin
        if (acc_cg) begin
          st_n = S_CG;
        end else if (acc_pg) begin
          st_n  = S_ISO;
          tgt_n = live || (req_class == RQ_PG_RET);
        end
      end
      S_CG: begin
        if (busy) st_n = S_ON;
      end
      S_ISO: begin
        tgt_n = tgt_ret || live;
        if (busy)                 st_n = S_ISOREL;
        else if (tgt_ret || live) st_n = S_SAVE;
        else                      st_n = S_OFF;
      end
      S_SAVE: begin
        if (busy) st_n = S_REST;
        else      st_n = S_OFF;
      end
      S_OFF: begin
        if (busy) st_n = S_PWRUP;
      end
      S_PWRUP: begin
        if (ack_pwr) st_n = S_INIT;
      end
      S_INIT:   st_n = S_REST;
      S_REST:   st_n = S_ISOREL;
      S_ISOREL: st_n = S_ON;
      default:  st_n = S_ON;
    endcase
  end

  //---------------------------------------------------------- registers
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st      <= S_ON;
      tgt_ret <= 1'b0;
      age     <= 8'd0;
      lock    <= 8'd0;
      iso_r   <= 1'b0;
      ret_r   <= 1'b0;
      pwr_r   <= 1'b1;
      init_r  <= 1'b0;
    end else begin
      if (mispredict)        lock <= HY8;
      else if (lock != 8'd0) lock <= lock - 8'd1;

      if (gated && !busy) begin
        if (age != 8'hFF) age <= age + 8'd1;
      end else begin
        age <= 8'd0;
      end

      st      <= st_n;
      tgt_ret <= tgt_n;
      iso_r   <= (st_n == S_ISO) || (st_n == S_SAVE) || (st_n == S_OFF) ||
                 (st_n == S_PWRUP) || (st_n == S_INIT) || (st_n == S_REST);
      ret_r   <= (st_n == S_SAVE) ||
                 (tgt_n && ((st_n == S_OFF) || (st_n == S_PWRUP) || (st_n == S_INIT)));
      pwr_r   <= (st_n != S_OFF);
      init_r  <= (st_n == S_INIT);
    end
  end

  //---------------------------------------------------------- outputs
  assign clk_en   = (st == S_ON) || ((st == S_CG) && busy);
  assign iso      = iso_r;
  assign ret      = ret_r;
  assign pwr_req  = pwr_r;
  assign init     = init_r;
  assign ready    = (st == S_ON) || (st == S_CG);
  assign pm_state = (st == S_ON) ? PM_ON :
                    (st == S_CG) ? PM_CG :
                    ((st == S_ISO) || (st == S_SAVE) || (st == S_OFF)) ?
                      (tgt_ret ? PM_PG_RET : PM_PG_OFF) :
                    PM_WAKING;
endmodule : safety_shell

`default_nettype wire
