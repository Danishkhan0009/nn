//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog testbench
// File      : tb/fido_tb_event_src.sv
// Module    : fido_tb_event_src
// Content   : peripheral event source (UART / SPI / timer / GPIO stand-in) for
//             ONE core. Events of the plan are delivered relative to that
//             core's own WFI sleep: event i fires ev_dly[i] cycles into a
//             sleep. REF and DUT therefore see the same event sequence and
//             retire the same instruction stream, whatever the gating does to
//             their timing. Drives on the negative clock edge.
// Hierarchy : tb_<cfg> > u_env > u_ev_ref / u_ev_dut
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module fido_tb_event_src (
  input  wire           clk,
  input  wire           rst_n,
  input  wire           wfi,          // the core is asleep (pipeline drained)
  input  wire    [31:0] ev_n,         // number of events in the plan
  input  wire  [1023:0] ev_dly_v,
  input  wire    [63:0] ev_src_v,
  input  wire   [255:0] ev_dat_v,
  output logic    [3:0] ev_valid,
  output logic   [31:0] ev_data
);
  int idx = 0;    // next event of the plan
  int cnt = 0;    // cycles into the present sleep

  always @(negedge clk) begin
    if (!rst_n) begin
      idx      <= 0;
      cnt      <= 0;
      ev_valid <= 4'd0;
      ev_data  <= 32'd0;
    end else begin
      ev_valid <= 4'd0;
      if (wfi) begin
        cnt <= cnt + 1;
        if ((idx < ev_n) && (cnt == ev_dly_v[idx*32 +: 32])) begin
          ev_valid[ev_src_v[idx*2 +: 2]]          <= 1'b1;
          ev_data[ev_src_v[idx*2 +: 2]*8 +: 8]    <= ev_dat_v[idx*8 +: 8];
          idx <= idx + 1;
        end
      end else begin
        cnt <= 0;
      end
    end
  end
endmodule : fido_tb_event_src

`default_nettype wire
