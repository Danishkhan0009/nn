//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/gating/icg_cell.sv
// Module    : icg_cell
// Content   : latch-based integrated clock gate (behavioural model of a
//             library clock-gating cell, CGC). The enable is captured while
//             the clock is low, so gclk never glitches.
// Used in   : pmu_top (one per clock domain in MODE 1/2, one per clock net
//             in MODE 3/4)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module icg_cell (
  input  wire  clk,
  input  wire  en,
  output logic gclk
);
  logic en_lat;

  // transparent while clk is low (intended latch)
  always_latch begin
    if (!clk) en_lat = en;
  end

  assign gclk = clk & en_lat;
endmodule : icg_cell

`default_nettype wire
