//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/gating/iso_clamp.sv
// Module    : iso_clamp
// Content   : isolation cells on a power-domain boundary (behavioural model of
//             library isolation cells, UPF set_isolation). While iso = 1 the
//             outputs of the domain are clamped to CLAMP.
// Used in   : every power leaf on its outputs (EX, CORE, RF-HI, banks ...)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module iso_clamp #(
  parameter int unsigned  W     = 1,
  parameter logic [W-1:0] CLAMP = '0
) (
  input  wire          iso,
  input  wire  [W-1:0] d,
  output logic [W-1:0] q
);
  assign q = iso ? CLAMP : d;
endmodule : iso_clamp

`default_nettype wire
