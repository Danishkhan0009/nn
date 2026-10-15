//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/regfile.sv
// Module    : regfile
// Content   : register file x0..x31 in two banks: u_bank_lo (x0..x15, CORE leaf) and u_bank_hi (x16..x31, RF-HI leaf, behind isolation cells in both directions); x0 hard-wired to 0; write-back bypass to the ID read ports
// Hierarchy : fido_top > u_core (rv32im_core) > u_rf
// Power leaf: CORE (u_bank_lo, read mux) and RF_HI (u_bank_hi, clock net RFHI)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module regfile (
  input  wire        clk_lo,         // clock net CORE
  input  wire        clk_hi,         // clock net RFHI
  input  wire        rst_n,
  // power leaf CORE
  input  wire        pdc_on,
  input  wire        pdc_ret,
  input  wire        pdc_iso,
  // power leaf RF_HI
  input  wire        pdh_on,
  input  wire        pdh_ret,
  input  wire        pdh_iso,
  // read (ID)
  input  wire  [4:0] rs1,
  input  wire  [4:0] rs2,
  // write (WB)
  input  wire        wb_we,
  input  wire  [4:0] wb_rd,
  input  wire [31:0] wb_wdata,
  output logic [31:0] r1,
  output logic [31:0] r2,
  output logic        rflo_we,       // bank LO written (clock-gating busy of CORE)
  output logic        rfh_we         // bank HI written, isolated (clock-gating busy of RFHI)
);
  wire [31:0] lo_rd1;
  wire [31:0] lo_rd2;
  wire [31:0] hi_rd1;
  wire [31:0] hi_rd2;
  wire  [3:0] hi_ra1;
  wire  [3:0] hi_ra2;
  wire        hi_we;
  wire  [3:0] hi_wa;
  wire [31:0] hi_wd;
  logic       rfh_we_i;
  logic [31:0] rd1_raw;
  logic [31:0] rd2_raw;

  assign rflo_we  = wb_we && !wb_rd[4];
  assign rfh_we_i = wb_we && wb_rd[4];

  //------------------------------------------------ bank LO (inside the CORE leaf)
  rf_bank u_bank_lo (
    .clk    (clk_lo),
    .rst_n  (rst_n),
    .pd_on  (pdc_on),
    .pd_ret (pdc_ret),
    .iso    (1'b0),
    .ra1    (rs1[3:0]),
    .ra2    (rs2[3:0]),
    .we     (rflo_we),
    .wa     (wb_rd[3:0]),
    .wd     (wb_wdata),
    .rd1    (lo_rd1),
    .rd2    (lo_rd2)
  );

  //------------------------------------------------ CORE -> RF-HI isolation (clamp 0)
  iso_clamp #(.W(4), .CLAMP(4'd0)) u_iso_hi_ra1 (.iso(pdc_iso), .d(rs1[3:0]), .q(hi_ra1));
  iso_clamp #(.W(4), .CLAMP(4'd0)) u_iso_hi_ra2 (.iso(pdc_iso), .d(rs2[3:0]), .q(hi_ra2));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_hi_we (.iso(pdc_iso), .d(rfh_we_i), .q(hi_we));
  iso_clamp #(.W(4), .CLAMP(4'd0)) u_iso_hi_wa (.iso(pdc_iso), .d(wb_rd[3:0]), .q(hi_wa));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_hi_wd (.iso(pdc_iso), .d(wb_wdata), .q(hi_wd));

  //------------------------------------------------ bank HI (RF-HI leaf, isolated read data)
  rf_bank u_bank_hi (
    .clk    (clk_hi),
    .rst_n  (rst_n),
    .pd_on  (pdh_on),
    .pd_ret (pdh_ret),
    .iso    (pdh_iso),
    .ra1    (hi_ra1),
    .ra2    (hi_ra2),
    .we     (hi_we),
    .wa     (hi_wa),
    .wd     (hi_wd),
    .rd1    (hi_rd1),
    .rd2    (hi_rd2)
  );

  //------------------------------------------------ read ports: bank select, x0, WB bypass
  assign rd1_raw = rs1[4] ? hi_rd1 : lo_rd1;
  assign rd2_raw = rs2[4] ? hi_rd2 : lo_rd2;
  assign r1      = (rs1 == 5'd0) ? 32'd0 : ((wb_we && (wb_rd == rs1)) ? wb_wdata : rd1_raw);
  assign r2      = (rs2 == 5'd0) ? 32'd0 : ((wb_we && (wb_rd == rs2)) ? wb_wdata : rd2_raw);
  assign rfh_we  = hi_we;
endmodule : regfile

`default_nettype wire
