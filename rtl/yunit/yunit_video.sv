// yunit_video.sv — Williams Y-unit video scanout: frame buffer -> RGB.
//
// Faithful to MAME midyunit_v.cpp scanline_update (:543):
//   src   = local_videoram[(rowaddr << 9) & 0x3fe00]   // row base (pixel idx)
//   pixel = src[coladdr++ & 0x1ff]                      // 512-col wrap
//   dest  = pen_map[pixel]                              // 6bpp: pen_map6()
// then the pen indexes palette RAM (xRGB1555) -> RGB888 (paletteram_w:250,
// pal5bit). The Y-unit uses EXTERNAL video timing (the game never programs the
// 34010 timing regs — measured 2026-07-04), so this block owns the raster.
//
// Two-stage read pipeline: addr -> vram_rdata (1 clk) -> pen_map6 -> pal_raddr
// -> pal_rdata (1 clk) -> RGB. de/sync are delayed to match.
//
// Geometry is parameterized (Smash T.V. = stdres). DISP_ROW0 is the first VRAM
// row displayed (the 34010 DPYSTRT; the game leaves it at reset so 0).

`default_nettype none

module yunit_video
  import yunit_pkg::*;
#(
  // Timing reconciled to MAME 0.280 `smashtv` set_raw (measured via -listxml):
  //   pixclock 8 MHz, htotal 506, hbend 90, hbstart 500, vtotal 289, vbend 20,
  //   vbstart 276, width 410, height 256, refresh 54.706840 Hz, rotate 0.
  //   => active 410x256; H_TOTAL 506, V_TOTAL 289; 8e6/(506*289)=54.71 Hz. ✓
  // (Phase 6 W3: was 512/616 x 256/288 = 616x288 which gave the wrong refresh.)
  parameter int H_ACT   = 410,   // visible pixels (MAME width; VRAM is 512 cols, cols 0..409 shown)
  parameter int H_FP    = 6,     // 506 - 410 active = 96 blank
  parameter int H_SYNC  = 40,
  parameter int H_BP    = 50,
  parameter int V_ACT   = 256,   // visible lines
  parameter int V_FP    = 13,    // 289 - 256 active = 33 blank
  parameter int V_SYNC  = 8,
  parameter int V_BP    = 12,
  parameter int DISP_ROW0 = 0    // first displayed VRAM row (DPYSTRT)
)(
  input  logic        clk,
  input  logic        rst,
  input  logic        ce_pix,       // pixel-clock enable

  // Frame-buffer read (registered, 1-clk latency): pixel index -> videoram word.
  output logic [FB_ADDR_W-1:0] vram_raddr,
  input  logic [15:0]          vram_rdata,
  // Palette read (registered, 1-clk latency): 12-bit pen -> xRGB1555.
  output logic [11:0]          pal_raddr,
  input  logic [15:0]          pal_rdata,

  // Video output (aligned with the 2-stage pipeline).
  output logic [7:0]  vid_r, vid_g, vid_b,
  output logic        hsync, vsync,
  output logic        hblank, vblank,
  output logic        de,
  output logic        vblank_irq    // 1-clk pulse at start of vertical blank
);

  localparam int H_TOTAL = H_ACT + H_FP + H_SYNC + H_BP;
  localparam int V_TOTAL = V_ACT + V_FP + V_SYNC + V_BP;

  // ---- raster counters (stage 0) ---------------------------------------
  logic [11:0] hc, vc;
  logic        s0_de, s0_hs, s0_vs, s0_hb, s0_vb;
  logic [11:0] s0_x, s0_y;

  always_ff @(posedge clk) begin
    if (rst) begin
      hc <= '0; vc <= '0; vblank_irq <= 1'b0;
    end else if (ce_pix) begin
      vblank_irq <= 1'b0;
      if (hc == H_TOTAL-1) begin
        hc <= '0;
        if (vc == V_TOTAL-1) vc <= '0;
        else begin
          vc <= vc + 12'd1;
          if (vc == V_ACT-1) vblank_irq <= 1'b1;   // entering vblank
        end
      end else hc <= hc + 12'd1;
    end
  end

  // active-region flags + pixel (x,y) at stage 0
  always_comb begin
    s0_x  = hc;
    s0_y  = vc;
    s0_de = (hc < H_ACT) && (vc < V_ACT);
    s0_hb = (hc >= H_ACT);
    s0_vb = (vc >= V_ACT);
    // sync sits after the front porch
    s0_hs = (hc >= H_ACT + H_FP) && (hc < H_ACT + H_FP + H_SYNC);
    s0_vs = (vc >= V_ACT + V_FP) && (vc < V_ACT + V_FP + V_SYNC);
  end

  // frame-buffer address: (DISP_ROW0 + y)*512 + (x & 0x1ff)
  assign vram_raddr = FB_ADDR_W'(((DISP_ROW0 + s0_y) << FB_ROWSHIFT) + (s0_x & 12'h1ff));

  // The color path has THREE register stages from s0: vram_rdata (external),
  // pal_rdata (external), and the vid_* output register. Delay the control
  // signals by three to keep de/sync aligned with the pixel color.
  logic s1_de,s1_hs,s1_vs,s1_hb,s1_vb;
  logic s2_de,s2_hs,s2_vs,s2_hb,s2_vb;
  always_ff @(posedge clk) begin
    if (rst) begin
      s1_de<=0;s1_hs<=0;s1_vs<=0;s1_hb<=0;s1_vb<=0;
      s2_de<=0;s2_hs<=0;s2_vs<=0;s2_hb<=0;s2_vb<=0;
    end else if (ce_pix) begin
      s1_de<=s0_de; s1_hs<=s0_hs; s1_vs<=s0_vs; s1_hb<=s0_hb; s1_vb<=s0_vb;
      s2_de<=s1_de; s2_hs<=s1_hs; s2_vs<=s1_vs; s2_hb<=s1_hb; s2_vb<=s1_vb;
    end
  end

  assign pal_raddr = pen_map6(vram_rdata);          // stage: pen map (comb)

  logic [23:0] rgb;
  assign rgb = rgb555_to_888(pal_rdata);            // stage: xRGB1555 -> 888 (comb)

  // ---- final output register (aligned with s2_*) -----------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      de<=0; hsync<=0; vsync<=0; hblank<=0; vblank<=0;
      vid_r<=0; vid_g<=0; vid_b<=0;
    end else if (ce_pix) begin
      de<=s2_de; hsync<=s2_hs; vsync<=s2_vs; hblank<=s2_hb; vblank<=s2_vb;
      vid_r <= s2_de ? rgb[23:16] : 8'h00;
      vid_g <= s2_de ? rgb[15:8]  : 8'h00;
      vid_b <= s2_de ? rgb[7:0]   : 8'h00;
    end
  end

endmodule

`default_nettype wire
