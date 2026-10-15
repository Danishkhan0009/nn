//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/rf_bank.sv
// Module    : rf_bank
// Content   : one register-file bank, 16 x 32, 2R1W, asynchronous read, retention array (keeps its content while off only if pd_ret was raised first); read data isolated (clamp 0)
// Hierarchy : fido_top > u_core > u_rf > u_bank_lo / u_bank_hi
// Power leaf: CORE (u_bank_lo, iso tied 0) or RF_HI (u_bank_hi)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module rf_bank (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        pd_on,
  input  wire        pd_ret,
  input  wire        iso,
  input  wire  [3:0] ra1,
  input  wire  [3:0] ra2,
  input  wire        we,
  input  wire  [3:0] wa,
  input  wire [31:0] wd,
  output logic [31:0] rd1,
  output logic [31:0] rd2
);
  logic [31:0] mem [16];

  always_ff @(posedge clk or negedge rst_n or negedge pd_on) begin
    if (!rst_n) begin
      for (int i = 0; i < 16; i++) mem[i] <= 32'd0;
    end else if (!pd_on) begin
      if (!pd_ret) begin
        for (int i = 0; i < 16; i++) mem[i] <= 'x;
      end
    end else if (we) begin
      mem[wa] <= wd;
    end
  end

  logic [31:0] r1;
  logic [31:0] r2;

  assign r1 = mem[ra1];
  assign r2 = mem[ra2];

  // isolation cells on the read ports (clamp 0)
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_rd1 (.iso(iso), .d(r1), .q(rd1));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_rd2 (.iso(iso), .d(r2), .q(rd2));
endmodule : rf_bank

`default_nettype wire
