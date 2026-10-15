//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/core/ex/alu_hi_unit.sv
// Module    : alu_hi_unit
// Content   : upper 16-bit halves of ADD/SUB and LOGIC; own operand registers (clock nets ADD_HI, LOGIC_HI); outputs isolated (clamp 0)
// Hierarchy : fido_top > u_core > u_ex > u_alu_hi
// Power leaf: ALU_HI (PD_ALU_HI in PG FINE)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module alu_hi_unit (
  input  wire        clk_add,
  input  wire        clk_logic,
  input  wire        rst_n,
  input  wire        pd_on,
  input  wire        pd_ret,
  input  wire        pd_init,
  input  wire        iso,
  input  wire        add_we,
  input  wire [15:0] add_a_d,
  input  wire [15:0] add_b_d,
  input  wire        logic_we,
  input  wire [15:0] logic_a_d,
  input  wire [15:0] logic_b_d,
  input  wire        a_fwd,
  input  wire [15:0] a_fwd_val,
  input  wire        b_fwd,
  input  wire [15:0] b_fwd_val,
  input  wire        sub,
  input  wire        cin,
  input  wire  [2:0] f3,
  output logic [15:0] add_res,
  output logic [15:0] logic_res
);
  wire  [15:0] add_a_q;
  wire  [15:0] add_b_q;
  wire  [15:0] lg_a_q;
  wire  [15:0] lg_b_q;
  logic [15:0] aa;
  logic [15:0] ab;
  logic [15:0] la;
  logic [15:0] lb;
  logic [15:0] abx;
  logic [15:0] sum;
  logic [15:0] lres;

  pg_dff #(.W(32)) u_add_ops (
    .clk     (clk_add),
    .rst_n   (rst_n),
    .pd_on   (pd_on),
    .pd_ret  (pd_ret),
    .pd_init (pd_init),
    .en      (add_we),
    .d       ({add_a_d, add_b_d}),
    .q       ({add_a_q, add_b_q})
  );

  pg_dff #(.W(32)) u_logic_ops (
    .clk     (clk_logic),
    .rst_n   (rst_n),
    .pd_on   (pd_on),
    .pd_ret  (pd_ret),
    .pd_init (pd_init),
    .en      (logic_we),
    .d       ({logic_a_d, logic_b_d}),
    .q       ({lg_a_q, lg_b_q})
  );

  assign aa   = a_fwd ? a_fwd_val : add_a_q;
  assign ab   = b_fwd ? b_fwd_val : add_b_q;
  assign la   = a_fwd ? a_fwd_val : lg_a_q;
  assign lb   = b_fwd ? b_fwd_val : lg_b_q;
  assign abx  = sub ? ~ab : ab;
  assign sum  = aa + abx + {15'd0, cin};
  assign lres = (f3 == 3'b100) ? (la ^ lb) :
                (f3 == 3'b110) ? (la | lb) : (la & lb);

  // isolation cells on the ALU_HI boundary
  iso_clamp #(.W(16), .CLAMP(16'd0)) u_iso_add (.iso(iso), .d(sum), .q(add_res));
  iso_clamp #(.W(16), .CLAMP(16'd0)) u_iso_logic (.iso(iso), .d(lres), .q(logic_res));
endmodule : alu_hi_unit

`default_nettype wire
