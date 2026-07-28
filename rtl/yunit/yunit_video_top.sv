// yunit_video_top.sv — Phase 6 W3: video subsystem. Combines yunit_video (VRAM word ->
// pen_map6 -> palette -> RGB, external raster) with yunit_scanline (double-buffered VRAM
// line fetch over the SDRAM scan_* channel). yunit_video is UNCHANGED — the line-buffer
// transparently serves its per-pixel 1-clk VRAM read from SDRAM. The palette read port
// (pal_raddr/pal_rdata) passes through to a palette BRAM the emu provides.
`timescale 1ns/1ps
`default_nettype none
module yunit_video_top
  import yunit_pkg::*;
#(
  parameter int H_ACT=410, H_FP=6, H_SYNC=40, H_BP=50,
  parameter int V_ACT=256, V_FP=13, V_SYNC=8, V_BP=12,
  parameter int DISP_ROW0=0,
  parameter int NCOL=512
)(
  input  logic        clk,
  input  logic        rst,
  input  logic        ce_pix,
  // palette read (to the emu's palette BRAM; 1-clk registered)
  output logic [11:0] pal_raddr,
  input  logic [15:0] pal_rdata,
  // SDRAM scanout read channel (to yunit_sdram_arb / vram_sdram_top)
  output logic        scan_req,
  output logic [17:0] scan_addr,
  input  logic [15:0] scan_data,
  input  logic        scan_ack,
  // video output
  output logic [7:0]  vid_r, vid_g, vid_b,
  output logic        hsync, vsync, hblank, vblank, de,
  output logic        vblank_irq
);
  // yunit_video <-> yunit_scanline VRAM read
  logic [FB_ADDR_W-1:0] vram_raddr; logic [15:0] vram_rdata;
  logic vblank_i;

  yunit_video #(
    .H_ACT(H_ACT), .H_FP(H_FP), .H_SYNC(H_SYNC), .H_BP(H_BP),
    .V_ACT(V_ACT), .V_FP(V_FP), .V_SYNC(V_SYNC), .V_BP(V_BP), .DISP_ROW0(DISP_ROW0)
  ) u_video (
    .clk(clk), .rst(rst), .ce_pix(ce_pix),
    .vram_raddr(vram_raddr), .vram_rdata(vram_rdata),
    .pal_raddr(pal_raddr), .pal_rdata(pal_rdata),
    .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
    .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank_i), .de(de),
    .vblank_irq(vblank_irq));
  assign vblank = vblank_i;

  yunit_scanline #(.FB_ADDR_W(FB_ADDR_W), .NCOL(NCOL), .FIRST_ROW(DISP_ROW0)) u_scan (
    .clk(clk), .rst(rst), .ce_pix(ce_pix), .vblank(vblank_i), .frame_row0((FB_ADDR_W-9)'(DISP_ROW0)),
    .vram_raddr(vram_raddr), .vram_rdata(vram_rdata),
    .scan_req(scan_req), .scan_addr(scan_addr), .scan_data(scan_data), .scan_ack(scan_ack));
endmodule
`default_nettype wire
