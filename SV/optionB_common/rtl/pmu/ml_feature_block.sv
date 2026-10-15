//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/pmu/ml_feature_block.sv
// Module    : ml_feature_block
// Content   : per power domain feature vector for the ML policy (MODE 4).
//             All features are registered (one cycle old), so the model is a
//             pure combinational function of flops. Always on (part of PMU).
//   feat[5:0]   idle   cycles since the domain was last busy (saturates at 63)
//   feat[8:6]   h1     length bin of the last finished idle period
//   feat[11:9]  h2     length bin of the idle period before that
//   feat[14:12] occ    pipeline occupancy (valid IF/ID, ID/EX, EX/MEM, MEM/WB)
//   feat[15]    wfi    core asleep in WFI
//   feat[19:16] evq    event-queue occupancy
//   feat[20]    live   domain holds state that must survive power-off
//   feat[21]    busy   present demand (NOT a model input - trace / oracle only)
//   bins: 0 <2, 1 <4, 2 <8, 3 <16, 4 <32, 5 <64, 6 <128, 7 >=128 cycles
// Hierarchy : fido_top > u_pmu > g_dual.g_pd[d].g_ml.u_feat
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module ml_feature_block (
  input  wire         clk,
  input  wire         rst_n,
  input  wire         busy,
  input  wire         live,
  input  wire         wfi,
  input  wire  [2:0]  occ,
  input  wire  [3:0]  evq,
  output logic [21:0] feat
);
  logic [7:0] run;
  logic       busy_q;
  logic [2:0] h1;
  logic [2:0] h2;
  logic [2:0] occ_q;
  logic       wfi_q;
  logic [3:0] evq_q;
  logic [2:0] run_bin;
  logic [5:0] idle;

  assign run_bin = (run < 8'd2)   ? 3'd0 :
                   (run < 8'd4)   ? 3'd1 :
                   (run < 8'd8)   ? 3'd2 :
                   (run < 8'd16)  ? 3'd3 :
                   (run < 8'd32)  ? 3'd4 :
                   (run < 8'd64)  ? 3'd5 :
                   (run < 8'd128) ? 3'd6 : 3'd7;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      run    <= 8'd0;
      busy_q <= 1'b1;
      h1     <= 3'd0;
      h2     <= 3'd0;
      occ_q  <= 3'd0;
      wfi_q  <= 1'b0;
      evq_q  <= 4'd0;
    end else begin
      busy_q <= busy;
      occ_q  <= occ;
      wfi_q  <= wfi;
      evq_q  <= evq;
      if (busy) begin
        run <= 8'd0;
        if (!busy_q) begin          // an idle period just ended: record its length
          h2 <= h1;
          h1 <= run_bin;
        end
      end else if (run != 8'hFF) begin
        run <= run + 8'd1;
      end
    end
  end

  assign idle = (run > 8'd63) ? 6'd63 : run[5:0];
  assign feat = {busy, live, evq_q, wfi_q, occ_q, h2, h1, idle};
endmodule : ml_feature_block

`default_nettype wire
