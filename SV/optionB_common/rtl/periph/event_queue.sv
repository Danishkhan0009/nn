//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/periph/event_queue.sv
// Module    : event_queue
// Content   : peripheral event queue - 4 sources, one pending slot per source,
//             8-deep FIFO, fixed priority (source 0 highest), batching
//             threshold, sticky overflow flag. Always on (it is the wake-up
//             source). Entry = {src[1:0], data[7:0]}; irq = (count >= threshold).
// Hierarchy : fido_top > u_evq
// Power leaf: always on (clock net EVQ, D_EVQ in CG FINE)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module event_queue (
  input  wire        clk,
  input  wire        rst_n,
  input  wire  [3:0] ev_valid,
  input  wire [31:0] ev_data,
  input  wire        pop,
  input  wire        cfg_we,
  input  wire  [3:0] cfg_wdata,
  output logic [3:0] count,
  output logic [9:0] head,
  output logic       ovf,
  output logic       irq,
  output logic       busy
);
  logic [3:0]  pend_v;
  logic [31:0] pend_d;
  logic [9:0]  fifo [8];
  logic [2:0]  hp;
  logic [2:0]  tp;
  logic [3:0]  cnt;
  logic        ovf_r;
  logic [3:0]  thr;

  logic        pop_eff;
  logic        can_push;
  logic [1:0]  sel;
  logic        push;
  logic [3:0]  sel_oh;
  logic [7:0]  sel_data;
  logic [3:0]  keep;
  logic [3:0]  thr_eff;

  assign pop_eff  = pop && (cnt != 4'd0);
  assign can_push = (cnt != 4'd8) || pop_eff;
  assign sel      = pend_v[0] ? 2'd0 : pend_v[1] ? 2'd1 : pend_v[2] ? 2'd2 : 2'd3;
  assign push     = (pend_v != 4'd0) && can_push;
  assign sel_oh   = push ? (4'd1 << sel) : 4'd0;
  assign sel_data = pend_d[{sel, 3'b000} +: 8];   // sel * 8
  assign keep     = pend_v & ~sel_oh;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pend_v <= 4'd0;
      pend_d <= 32'd0;
      hp     <= 3'd0;
      tp     <= 3'd0;
      cnt    <= 4'd0;
      ovf_r  <= 1'b0;
      thr    <= 4'd1;
      for (int k = 0; k < 8; k++) fifo[k] <= 10'd0;
    end else begin
      pend_v <= keep | ev_valid;
      for (int k = 0; k < 4; k++) begin
        if (ev_valid[k]) pend_d[k*8 +: 8] <= ev_data[k*8 +: 8];
      end
      if ((keep & ev_valid) != 4'd0) ovf_r <= 1'b1;
      if (push) begin
        fifo[tp] <= {sel, sel_data};
        tp       <= tp + 3'd1;
      end
      if (pop_eff) hp <= hp + 3'd1;
      if (push && !pop_eff)      cnt <= cnt + 4'd1;
      else if (!push && pop_eff) cnt <= cnt - 4'd1;
      if (cfg_we) thr <= cfg_wdata;
    end
  end

  assign thr_eff = (thr == 4'd0) ? 4'd1 : thr;
  assign count   = cnt;
  assign head    = fifo[hp];
  assign ovf     = ovf_r;
  assign irq     = (cnt >= thr_eff);
  assign busy    = (ev_valid != 4'd0) || (pend_v != 4'd0) || pop || cfg_we;
endmodule : event_queue

`default_nettype wire
