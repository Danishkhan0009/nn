//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/gating/pg_dff.sv
// Module    : pg_dff
// Content   : D flip-flop inside a (possibly) power-gated domain
//   RET = 0 : normal flop    - X while powered off, reset value on power-up init
//   RET = 1 : retention flop - keeps its value while off if pd_ret was raised
//             before the switch opened
// Power gating is modelled in RTL (no UPF needed to simulate): a wrong
// safety-shell sequence shows up as X / wrong data in the lock-step scoreboard.
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module pg_dff #(
  parameter int unsigned  W   = 1,
  parameter logic [W-1:0] RV  = '0,     // reset / power-up value
  parameter int           RET = 0       // 1 = retention flop
) (
  input  wire          clk,
  input  wire          rst_n,
  input  wire          pd_on,    // domain powered (switch closed and settled)
  input  wire          pd_ret,   // retention save request
  input  wire          pd_init,  // power-up initialisation of non-retention state
  input  wire          en,
  input  wire  [W-1:0] d,
  output logic [W-1:0] q
);
  always_ff @(posedge clk or negedge rst_n or negedge pd_on or posedge pd_init) begin
    if (!rst_n) begin
      q <= RV;
    end else if (!pd_on) begin
      if (!((RET != 0) && pd_ret)) q <= 'x;
    end else if (pd_init) begin
      if (RET == 0) q <= RV;
    end else if (en) begin
      q <= d;
    end
  end
endmodule : pg_dff

`default_nettype wire
