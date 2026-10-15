//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/mem/dmem_bank.sv
// Module    : dmem_bank
// Content   : 256 x 32 data-memory bank with byte enables, retention array
//             (content kept while off only if pd_ret was raised first),
//             asynchronous read, isolated output (clamp 0).
// Hierarchy : fido_top > u_dmem (dmem_banked) > g_bank[b].u_bank
// Power leaf: BANKb (clock net BANKb, PD_BANKb in PG FINE, PD_STORAGE in COARSE)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module dmem_bank (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        pd_on,
  input  wire        pd_ret,
  input  wire        iso,
  input  wire  [7:0] idx,
  input  wire        we,
  input  wire  [3:0] strb,
  input  wire [31:0] wdata,
  output logic [31:0] rdata
);
  logic [31:0] mem [256];
  logic [31:0] mask;
  logic [31:0] cur;

  assign mask = {{8{strb[3]}}, {8{strb[2]}}, {8{strb[1]}}, {8{strb[0]}}};
  assign cur  = mem[idx];

  always_ff @(posedge clk or negedge rst_n or negedge pd_on) begin
    if (!rst_n) begin
      for (int i = 0; i < 256; i++) mem[i] <= 32'd0;
    end else if (!pd_on) begin
      if (!pd_ret) begin
        for (int i = 0; i < 256; i++) mem[i] <= 'x;
      end
    end else if (we) begin
      mem[idx] <= (cur & ~mask) | (wdata & mask);
    end
  end

  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso (
    .iso (iso),
    .d   (cur),
    .q   (rdata)
  );
endmodule : dmem_bank

`default_nettype wire
