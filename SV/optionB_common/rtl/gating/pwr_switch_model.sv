//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/gating/pwr_switch_model.sv
// Module    : pwr_switch_model
// Content   : header power switch + supply settle time.
//             The switch opens one cycle after pwr_req falls (supply decays)
//             and reports "settled" (ack = pd_on = 1) WAKE cycles after
//             pwr_req rises. Both edges come from flops.
// Used in   : pm_domain (power-gating domains only)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module pwr_switch_model #(
  parameter int WAKE = 4
) (
  input  wire  clk,
  input  wire  rst_n,
  input  wire  pwr_req,
  output logic ack,
  output logic pd_on
);
  localparam logic [7:0] WK = 8'(WAKE);

  logic [7:0] cnt;
  logic       ack_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt   <= WK;
      ack_r <= 1'b1;
    end else if (!pwr_req) begin
      cnt   <= 8'd0;
      ack_r <= 1'b0;
    end else begin
      if (cnt != WK) cnt <= cnt + 8'd1;
      ack_r <= ((cnt + 8'd1) >= WK);
    end
  end

  assign ack   = ack_r;
  assign pd_on = ack_r;
endmodule : pwr_switch_model

`default_nettype wire
