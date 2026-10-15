//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/ex/div_unit.sv
// Module    : div_unit
// Content   : iterative restoring divider, 32 iterations. op: 00 DIV, 01 DIVU, 10 REM, 11 REMU (RISC-V divide-by-zero semantics). Outputs isolated (clamp 0).
// Hierarchy : fido_top > u_core > u_ex > u_div
// Power leaf: DIV (clock net DIV, PD_DIV in PG FINE)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module div_unit (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        pd_on,
  input  wire        pd_ret,
  input  wire        pd_init,
  input  wire        iso,
  input  wire        start,
  input  wire  [1:0] op,
  input  wire [31:0] a,
  input  wire [31:0] b,
  output logic        busy,
  output logic        done,
  output logic [31:0] res,
  output logic        we
);
  // state = {bsy, cnt[5:0], rem[31:0], quo[31:0], dvs[31:0], negq, negr, isrem, dn, r[31:0]}
  wire        bsy;
  wire [5:0]  cnt;
  wire [31:0] rem;
  wire [31:0] quo;
  wire [31:0] dvs;
  wire        negq;
  wire        negr;
  wire        isrem;
  wire        dn;
  wire [31:0] r;

  logic        sgn;
  logic        a_neg;
  logic        b_neg;
  logic [31:0] a_abs;
  logic [31:0] b_abs;
  logic        b_zero;
  logic [32:0] rs;
  logic [33:0] diff;
  logic        ge;
  logic [31:0] q_fin;
  logic [31:0] r_fin;
  logic        en;

  logic        n_bsy;
  logic [5:0]  n_cnt;
  logic [31:0] n_rem;
  logic [31:0] n_quo;
  logic [31:0] n_dvs;
  logic        n_negq;
  logic        n_negr;
  logic        n_isrem;
  logic        n_dn;
  logic [31:0] n_r;

  assign sgn    = ~op[0];
  assign a_neg  = sgn & a[31];
  assign b_neg  = sgn & b[31];
  assign a_abs  = a_neg ? (~a + 32'd1) : a;
  assign b_abs  = b_neg ? (~b + 32'd1) : b;
  assign b_zero = (b == 32'd0);
  assign rs     = {rem, quo[31]};
  assign diff   = {1'b0, rs} - {2'b00, dvs};
  assign ge     = ~diff[33];
  assign q_fin  = negq ? (~quo + 32'd1) : quo;
  assign r_fin  = negr ? (~rem + 32'd1) : rem;

  always_comb begin
    n_bsy   = bsy;
    n_cnt   = cnt;
    n_rem   = rem;
    n_quo   = quo;
    n_dvs   = dvs;
    n_negq  = negq;
    n_negr  = negr;
    n_isrem = isrem;
    n_dn    = 1'b0;
    n_r     = r;
    if (start) begin
      if (b_zero) begin
        n_bsy = 1'b0;
        n_dn  = 1'b1;
        n_r   = op[1] ? a : 32'hFFFF_FFFF;
      end else begin
        n_bsy   = 1'b1;
        n_cnt   = 6'd32;
        n_rem   = 32'd0;
        n_quo   = a_abs;
        n_dvs   = b_abs;
        n_negq  = a_neg ^ b_neg;
        n_negr  = a_neg;
        n_isrem = op[1];
      end
    end else if (bsy) begin
      if (cnt != 6'd0) begin
        n_cnt = cnt - 6'd1;
        if (ge) begin
          n_rem = diff[31:0];
          n_quo = {quo[30:0], 1'b1};
        end else begin
          n_rem = rs[31:0];
          n_quo = {quo[30:0], 1'b0};
        end
      end else begin
        n_bsy = 1'b0;
        n_dn  = 1'b1;
        n_r   = isrem ? r_fin : q_fin;
      end
    end
  end

  assign en = start | bsy | dn;

  pg_dff #(.W(139)) u_state (
    .clk     (clk),
    .rst_n   (rst_n),
    .pd_on   (pd_on),
    .pd_ret  (pd_ret),
    .pd_init (pd_init),
    .en      (en),
    .d       ({n_bsy, n_cnt, n_rem, n_quo, n_dvs, n_negq, n_negr, n_isrem, n_dn, n_r}),
    .q       ({bsy, cnt, rem, quo, dvs, negq, negr, isrem, dn, r})
  );

  // isolation cells on the DIV boundary
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_busy (.iso(iso), .d(bsy), .q(busy));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_done (.iso(iso), .d(dn), .q(done));
  iso_clamp #(.W(32), .CLAMP(32'd0)) u_iso_res (.iso(iso), .d(r), .q(res));
  iso_clamp #(.W(1), .CLAMP(1'd0)) u_iso_we (.iso(iso), .d(en), .q(we));
endmodule : div_unit

`default_nettype wire
