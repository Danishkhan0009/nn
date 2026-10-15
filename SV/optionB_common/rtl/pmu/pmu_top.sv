//=============================================================================
// FIDO V3 (WITCHER) - SystemVerilog RTL
// File      : rtl/pmu/pmu_top.sv
// Module    : pmu_top
// Content   : power-management unit and gating fabric (always on)
//   MODE 0 (BASE)      : no gating, every clock net = clk
//   MODE 1 / 2 (CG/PG) : one layer, one pm_domain + one ICG per domain;
//                        clock net -> domain by the CG or PG map
//   MODE 3 / 4         : two layers at once - clock domains (CG map, reactive)
//                        and power domains (PG map, reactive or ML); one ICG
//                        per clock net, enabled by clock-domain enable AND
//                        power-domain enable
//   Observation slots (32): MODE 1/2 slot = domain; MODE 3/4 slots
//   0..NCG-1 = clock domains, NCG..NCG+NPG-1 = power domains; unused slots
//   read ON.
// Hierarchy : fido_top > u_pmu
//               g_single.g_dom[d].u_dom (pm_domain), .u_icg (icg_cell)
//               g_dual.g_cd[d].u_dom    (pm_domain, clock layer)
//               g_dual.g_pd[d].u_dom    (pm_domain, power layer)
//               g_dual.g_pd[d].g_ml.u_feat (ml_feature_block, MODE 4)
//               g_dual.g_model_*.u_models  (ml_models_fine / _coarse, MODE 4)
//               g_dual.g_cn[c].g_icg.u_icg (icg_cell per clock net)
// Language  : SystemVerilog IEEE 1800-2012, target Cadence Xcelium 22.09
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module pmu_top
  import fido_pkg::*;
#(
  parameter int MODE    = MODE_BASE,
  parameter int GRAIN   = GRAIN_FINE,
  parameter int THR_CG  = 8,    // idle cycles before clock gating
  parameter int THR_PG  = 16,   // idle cycles before power gating
  parameter int WAKE_PG = 4,    // power-switch settle cycles
  parameter int BE      = 8,    // break-even (mispredict window)
  parameter int HYST    = 8     // lock-ON cycles after a mispredict
) (
  input  wire          clk,
  input  wire          rst_n,
  input  wire  [17:0]  cn_we,        // clock-gating busy per clock net
  input  wire  [17:0]  cn_dem,       // power-gating busy per clock net
  input  wire          trap_win,
  input  wire          wfi_sleep,
  input  wire  [2:0]   occ,
  input  wire  [3:0]   evq_count,
  input  wire  [1:0]   ml_force,
  // per clock net
  output logic [17:0]  gclk_cn,
  output logic [17:0]  rdy_cn,
  output logic [17:0]  on_cn,
  output logic [17:0]  ret_cn,
  output logic [17:0]  init_cn,
  output logic [17:0]  iso_cn,
  // observation
  output logic [95:0]  pm_state_bus,
  output logic [31:0]  dom_clk_en,
  output logic [31:0]  dom_iso,
  output logic [31:0]  dom_ret,
  output logic [31:0]  dom_pwr,
  output logic [31:0]  dom_ack,
  output logic [31:0]  dom_busy,
  output logic [31:0]  dom_ready,
  output logic [31:0]  dom_mispred,
  output logic [255:0] ml_feat
);
  //------------------------------------------------------------ maps
  localparam logic [89:0] MAPC = (GRAIN == GRAIN_FINE) ? MAP_CG_F : MAP_CG_C;
  localparam logic [89:0] MAPP = (GRAIN == GRAIN_FINE) ? MAP_PG_F : MAP_PG_C;
  localparam int          NCG  = (GRAIN == GRAIN_FINE) ? NCG_FINE : NCG_COARSE;
  localparam int          NPG  = (GRAIN == GRAIN_FINE) ? NPG_FINE : NPG_COARSE;
  // single-layer map and domain count (MODE 1 / 2)
  localparam logic [89:0] MAP  = (MODE == MODE_CG) ? MAPC : MAPP;
  localparam int          ND   = (MODE == MODE_CG) ? NCG : (MODE == MODE_PG) ? NPG : 1;
  localparam int          NONE = int'(DOM_NONE);   // "net not in a domain of this layer"

  //------------------------------------------------------------ fabric nets
  wire [17:0]  w_gclk;
  wire [17:0]  w_rdy;
  wire [17:0]  w_on;
  wire [17:0]  w_ret;
  wire [17:0]  w_init;
  wire [17:0]  w_iso;
  wire [95:0]  w_state;
  wire [31:0]  w_clk_en;
  wire [31:0]  w_diso;
  wire [31:0]  w_dret;
  wire [31:0]  w_pwr;
  wire [31:0]  w_ack;
  wire [31:0]  w_busy;
  wire [31:0]  w_ready;
  wire [31:0]  w_mis;
  wire [255:0] w_feat;

  genvar d;
  genvar c;
  genvar o;

  if ((MODE == MODE_CG) || (MODE == MODE_PG)) begin : g_single
    //========================================================== one layer
    wire [ND-1:0]   d_busy;
    wire [ND-1:0]   d_live;
    wire [ND-1:0]   d_clk_en;
    wire [ND-1:0]   d_iso;
    wire [ND-1:0]   d_ret;
    wire [ND-1:0]   d_pwr;
    wire [ND-1:0]   d_init;
    wire [ND-1:0]   d_ready;
    wire [ND-1:0]   d_ack;
    wire [ND-1:0]   d_on;
    wire [ND-1:0]   d_mis;
    wire [ND-1:0]   d_gclk;
    wire [3*ND-1:0] d_state;
    wire [17:0]     cn_busy;

    assign cn_busy = (MODE == MODE_CG) ? cn_we : cn_dem;

    for (d = 0; d < ND; d = d + 1) begin : g_dom
      wire [17:0] memb;
      for (c = 0; c < NCN; c = c + 1) begin : g_m
        assign memb[c] = (MAP[c*5 +: 5] == d) ? 1'b1 : 1'b0;
      end
      assign d_busy[d] = |(cn_busy & memb);
      assign d_live[d] = |(CN_LIVE & memb);

      pm_domain #(
        .SH_MODE   (MODE),
        .THR       ((MODE == MODE_CG) ? THR_CG : THR_PG),
        .BE        (BE),
        .HYST      (HYST),
        .WAKE_PG   (WAKE_PG),
        .POLICY_ML (0)
      ) u_dom (
        .clk        (clk),
        .rst_n      (rst_n),
        .busy       (d_busy[d]),
        .live       (d_live[d]),
        .trap_win   (trap_win),
        .ml_force   (2'b00),
        .model_dec  (3'b000),
        .clk_en     (d_clk_en[d]),
        .iso        (d_iso[d]),
        .ret        (d_ret[d]),
        .pwr_req    (d_pwr[d]),
        .init       (d_init[d]),
        .ready      (d_ready[d]),
        .ack        (d_ack[d]),
        .pd_on      (d_on[d]),
        .pm_state   (d_state[3*d +: 3]),
        .mispredict (d_mis[d])
      );

      icg_cell u_icg (
        .clk  (clk),
        .en   (d_clk_en[d]),
        .gclk (d_gclk[d])
      );
    end

    // per clock-net fabric
    for (c = 0; c < NCN; c = c + 1) begin : g_cn
      localparam int DM = int'(MAP[c*5 +: 5]);       // domain of this clock net (NONE = not gated)
      if ((MODE == MODE_CG) && (DM != NONE)) begin : g_cg
        assign w_gclk[c] = d_gclk[DM];
        assign w_rdy[c]  = 1'b1;
        assign w_on[c]   = 1'b1;
        assign w_ret[c]  = 1'b0;
        assign w_init[c] = 1'b0;
        assign w_iso[c]  = 1'b0;
      end else if ((MODE == MODE_PG) && (DM != NONE)) begin : g_pg
        assign w_gclk[c] = d_gclk[DM];
        assign w_rdy[c]  = d_ready[DM];
        assign w_on[c]   = d_on[DM];
        assign w_ret[c]  = d_ret[DM];
        assign w_init[c] = d_init[DM];
        assign w_iso[c]  = d_iso[DM];
      end else begin : g_aon
        assign w_gclk[c] = clk;
        assign w_rdy[c]  = 1'b1;
        assign w_on[c]   = 1'b1;
        assign w_ret[c]  = 1'b0;
        assign w_init[c] = 1'b0;
        assign w_iso[c]  = 1'b0;
      end
    end

    // observation slots
    for (o = 0; o < 32; o = o + 1) begin : g_obs
      if (o < ND) begin : g_used
        assign w_state[3*o +: 3] = d_state[3*o +: 3];
        assign w_clk_en[o]       = d_clk_en[o];
        assign w_diso[o]         = d_iso[o];
        assign w_dret[o]         = d_ret[o];
        assign w_pwr[o]          = d_pwr[o];
        assign w_ack[o]          = d_ack[o];
        assign w_busy[o]         = d_busy[o];
        assign w_ready[o]        = d_ready[o];
        assign w_mis[o]          = d_mis[o];
      end else begin : g_unused
        assign w_state[3*o +: 3] = PM_ON;
        assign w_clk_en[o]       = 1'b1;
        assign w_diso[o]         = 1'b0;
        assign w_dret[o]         = 1'b0;
        assign w_pwr[o]          = 1'b1;
        assign w_ack[o]          = 1'b1;
        assign w_busy[o]         = 1'b0;
        assign w_ready[o]        = 1'b1;
        assign w_mis[o]          = 1'b0;
      end
    end

    assign w_feat = 256'd0;

  end else if ((MODE == MODE_CGPG) || (MODE == MODE_CGPG_ML)) begin : g_dual
    //========================================================== two layers
    // clock layer
    wire [NCG-1:0]   c_busy;
    wire [NCG-1:0]   c_clk_en;
    wire [NCG-1:0]   c_iso;
    wire [NCG-1:0]   c_ret;
    wire [NCG-1:0]   c_pwr;
    wire [NCG-1:0]   c_init;
    wire [NCG-1:0]   c_ready;
    wire [NCG-1:0]   c_ack;
    wire [NCG-1:0]   c_on;
    wire [NCG-1:0]   c_mis;
    wire [3*NCG-1:0] c_state;
    // power layer
    wire [NPG-1:0]   p_busy;
    wire [NPG-1:0]   p_live;
    wire [NPG-1:0]   p_clk_en;
    wire [NPG-1:0]   p_iso;
    wire [NPG-1:0]   p_ret;
    wire [NPG-1:0]   p_pwr;
    wire [NPG-1:0]   p_init;
    wire [NPG-1:0]   p_ready;
    wire [NPG-1:0]   p_ack;
    wire [NPG-1:0]   p_on;
    wire [NPG-1:0]   p_mis;
    wire [3*NPG-1:0] p_state;
    // ML
    wire [255:0]     feat;
    wire [23:0]      mdec;

    //---------------- clock domains: reactive CG, one controller each
    for (d = 0; d < NCG; d = d + 1) begin : g_cd
      wire [17:0] memb;
      for (c = 0; c < NCN; c = c + 1) begin : g_m
        assign memb[c] = (MAPC[c*5 +: 5] == d) ? 1'b1 : 1'b0;
      end
      assign c_busy[d] = |(cn_we & memb);

      pm_domain #(
        .SH_MODE   (MODE_CG),
        .THR       (THR_CG),
        .BE        (BE),
        .HYST      (HYST),
        .WAKE_PG   (WAKE_PG),
        .POLICY_ML (0)
      ) u_dom (
        .clk        (clk),
        .rst_n      (rst_n),
        .busy       (c_busy[d]),
        .live       (1'b0),
        .trap_win   (trap_win),
        .ml_force   (2'b00),
        .model_dec  (3'b000),
        .clk_en     (c_clk_en[d]),
        .iso        (c_iso[d]),
        .ret        (c_ret[d]),
        .pwr_req    (c_pwr[d]),
        .init       (c_init[d]),
        .ready      (c_ready[d]),
        .ack        (c_ack[d]),
        .pd_on      (c_on[d]),
        .pm_state   (c_state[3*d +: 3]),
        .mispredict (c_mis[d])
      );
    end

    //---------------- power domains: reactive (MODE 3) or ML (MODE 4) PG
    for (d = 0; d < NPG; d = d + 1) begin : g_pd
      wire [17:0] memb;
      for (c = 0; c < NCN; c = c + 1) begin : g_m
        assign memb[c] = (MAPP[c*5 +: 5] == d) ? 1'b1 : 1'b0;
      end
      assign p_busy[d] = |(cn_dem & memb);
      assign p_live[d] = |(CN_LIVE & memb);

      if (MODE == MODE_CGPG_ML) begin : g_ml
        wire [21:0] f;
        ml_feature_block u_feat (
          .clk   (clk),
          .rst_n (rst_n),
          .busy  (p_busy[d]),
          .live  (p_live[d]),
          .wfi   (wfi_sleep),
          .occ   (occ),
          .evq   (evq_count),
          .feat  (f)
        );
        assign feat[32*d +: 32] = {10'd0, f};
      end else begin : g_re
        assign feat[32*d +: 32] = 32'd0;
      end

      pm_domain #(
        .SH_MODE   (MODE_PG),
        .THR       (THR_PG),
        .BE        (BE),
        .HYST      (HYST),
        .WAKE_PG   (WAKE_PG),
        .POLICY_ML ((MODE == MODE_CGPG_ML) ? 1 : 0)
      ) u_dom (
        .clk        (clk),
        .rst_n      (rst_n),
        .busy       (p_busy[d]),
        .live       (p_live[d]),
        .trap_win   (trap_win),
        .ml_force   (ml_force),
        .model_dec  (mdec[3*d +: 3]),
        .clk_en     (p_clk_en[d]),
        .iso        (p_iso[d]),
        .ret        (p_ret[d]),
        .pwr_req    (p_pwr[d]),
        .init       (p_init[d]),
        .ready      (p_ready[d]),
        .ack        (p_ack[d]),
        .pd_on      (p_on[d]),
        .pm_state   (p_state[3*d +: 3]),
        .mispredict (p_mis[d])
      );
    end
    if (NPG < 8) begin : g_fpad
      assign feat[255:32*NPG] = {(256-32*NPG){1'b0}};
    end

    //---------------- exported ML models (generated by ml/train_ml.py)
    if ((MODE == MODE_CGPG_ML) && (GRAIN == GRAIN_FINE)) begin : g_model_f
      ml_models_fine u_models (
        .feat (feat),
        .dec  (mdec)
      );
    end else if (MODE == MODE_CGPG_ML) begin : g_model_c
      ml_models_coarse u_models (
        .feat (feat),
        .dec  (mdec)
      );
    end else begin : g_nomodel
      assign mdec = 24'd0;
    end
    assign w_feat = feat;

    //---------------- clock nets: enable = clock-domain AND power-domain enable
    for (c = 0; c < NCN; c = c + 1) begin : g_cn
      localparam int CD = int'(MAPC[c*5 +: 5]);      // clock domain of this net (NONE = none)
      localparam int PD = int'(MAPP[c*5 +: 5]);      // power domain of this net (NONE = none)
      wire cge;
      wire pge;
      if (CD != NONE) begin : g_c
        assign cge = c_clk_en[CD];
      end else begin : g_nc
        assign cge = 1'b1;
      end
      if (PD != NONE) begin : g_p
        assign pge       = p_clk_en[PD];
        assign w_rdy[c]  = p_ready[PD];
        assign w_on[c]   = p_on[PD];
        assign w_ret[c]  = p_ret[PD];
        assign w_init[c] = p_init[PD];
        assign w_iso[c]  = p_iso[PD];
      end else begin : g_np
        assign pge       = 1'b1;
        assign w_rdy[c]  = 1'b1;
        assign w_on[c]   = 1'b1;
        assign w_ret[c]  = 1'b0;
        assign w_init[c] = 1'b0;
        assign w_iso[c]  = 1'b0;
      end
      if ((CD == NONE) && (PD == NONE)) begin : g_aon
        assign w_gclk[c] = clk;
      end else begin : g_icg
        icg_cell u_icg (
          .clk  (clk),
          .en   (cge & pge),
          .gclk (w_gclk[c])
        );
      end
    end

    //---------------- observation slots
    for (o = 0; o < 32; o = o + 1) begin : g_obs
      if (o < NCG) begin : g_oc
        assign w_state[3*o +: 3] = c_state[3*o +: 3];
        assign w_clk_en[o]       = c_clk_en[o];
        assign w_diso[o]         = c_iso[o];
        assign w_dret[o]         = c_ret[o];
        assign w_pwr[o]          = c_pwr[o];
        assign w_ack[o]          = 1'b1;
        assign w_busy[o]         = c_busy[o];
        assign w_ready[o]        = c_ready[o];
        assign w_mis[o]          = c_mis[o];
      end else if (o < NCG + NPG) begin : g_op
        assign w_state[3*o +: 3] = p_state[3*(o-NCG) +: 3];
        assign w_clk_en[o]       = p_clk_en[o-NCG];
        assign w_diso[o]         = p_iso[o-NCG];
        assign w_dret[o]         = p_ret[o-NCG];
        assign w_pwr[o]          = p_pwr[o-NCG];
        assign w_ack[o]          = p_ack[o-NCG];
        assign w_busy[o]         = p_busy[o-NCG];
        assign w_ready[o]        = p_ready[o-NCG];
        assign w_mis[o]          = p_mis[o-NCG];
      end else begin : g_ou
        assign w_state[3*o +: 3] = PM_ON;
        assign w_clk_en[o]       = 1'b1;
        assign w_diso[o]         = 1'b0;
        assign w_dret[o]         = 1'b0;
        assign w_pwr[o]          = 1'b1;
        assign w_ack[o]          = 1'b1;
        assign w_busy[o]         = 1'b0;
        assign w_ready[o]        = 1'b1;
        assign w_mis[o]          = 1'b0;
      end
    end

  end else begin : g_base
    //========================================================== no gating
    assign w_gclk   = {NCN{clk}};
    assign w_rdy    = {NCN{1'b1}};
    assign w_on     = {NCN{1'b1}};
    assign w_ret    = {NCN{1'b0}};
    assign w_init   = {NCN{1'b0}};
    assign w_iso    = {NCN{1'b0}};
    assign w_state  = 96'd0;
    assign w_clk_en = {32{1'b1}};
    assign w_diso   = 32'd0;
    assign w_dret   = 32'd0;
    assign w_pwr    = {32{1'b1}};
    assign w_ack    = {32{1'b1}};
    assign w_busy   = 32'd0;
    assign w_ready  = {32{1'b1}};
    assign w_mis    = 32'd0;
    assign w_feat   = 256'd0;
  end

  //------------------------------------------------------------ outputs
  assign gclk_cn      = w_gclk;
  assign rdy_cn       = w_rdy;
  assign on_cn        = w_on;
  assign ret_cn       = w_ret;
  assign init_cn      = w_init;
  assign iso_cn       = w_iso;
  assign pm_state_bus = w_state;
  assign dom_clk_en   = w_clk_en;
  assign dom_iso      = w_diso;
  assign dom_ret      = w_dret;
  assign dom_pwr      = w_pwr;
  assign dom_ack      = w_ack;
  assign dom_busy     = w_busy;
  assign dom_ready    = w_ready;
  assign dom_mispred  = w_mis;
  assign ml_feat      = w_feat;
endmodule : pmu_top

`default_nettype wire
