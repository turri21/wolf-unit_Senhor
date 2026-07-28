// smashtv_diag_top.sv — HARDWARE SDRAM LOOPBACK DIAGNOSTIC (drop-in for yunit_top).
//
// The behavioral sim CANNOT test real-silicon SDRAM read/write (the model returns
// correct data regardless of pin timing). Two full boots have come up BLACK + silent
// + coin-dead on the cab, and swapping a proven SDRAM controller changed nothing —
// which is exactly what you'd see if SDRAM read/write simply does not work on this
// board (bad pin timing / SDC / the chip isn't actually clocked). This module answers
// that one question directly, using the only output channel we have: the screen.
//
// It discards the entire Y-unit core and instantiates ONLY the stock SDRAM controller
// + a self-test FSM + a minimal video generator. On boot it:
//   1. waits for the controller's power-up init (ready),
//   2. WRITES an address-dependent pattern to every word region the game uses
//      (0..DIAG_NWORDS, which spans gfx + program ROM + VRAM in bank 0),
//   3. READS it all back and compares,
//   4. paints the screen by result so the cab tells us the truth:
//        color bars visible -> clk_sys + ce_pix + video path + HDMI all alive
//        BLUE   body        -> clocks/video OK but SDRAM init never completed
//        YELLOW body        -> test started but an op never finished (stuck)
//        GREEN  body        -> SDRAM read/write WORKS on silicon (bug is above SDRAM)
//        RED    body        -> SDRAM read/write BROKEN on silicon (pins/SDC/clock)
//   A moving white column proves the raster is live (not a frozen frame). The bottom
//   strip is a coarse log2(mismatch-count) bar (wider = more mismatches).
//
// Ports mirror yunit_top so the emu can `ifdef`-swap the instance with no rewiring.
`default_nettype none
module smashtv_diag_top
#(
  parameter ROM_HEX = "",
  parameter int H_ACT=410, H_FP=6,  H_SYNC=40, H_BP=50,
  parameter int V_ACT=256, V_FP=13, V_SYNC=8,  V_BP=12,
  parameter [24:0] DIAG_NWORDS = 25'h160000   // words to test (gfx+ROM+VRAM span, bank 0)
)(
  input  logic        clk,
  input  logic        clk_cpu,
  input  logic        ce_pix,
  input  logic        clk_snd,
  input  logic        rst,
  input  logic        rst_pon,
  input  logic [63:0] inputs,
  input  logic        ioctl_download,
  input  logic        ioctl_wr,
  input  logic [24:0] ioctl_addr,
  input  logic [15:0] ioctl_dout,
  input  logic [1:0]  ioctl_be,
  output logic        ioctl_wait,
  input  logic        snd_dl_wr,
  input  logic [17:0] snd_dl_addr,
  input  logic [7:0]  snd_dl_data,
  inout  wire  [15:0] SDRAM_DQ,
  output logic [12:0] SDRAM_A,
  output logic [1:0]  SDRAM_BA,
  output logic        SDRAM_DQML, SDRAM_DQMH,
  output logic        SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE,
  output logic        SDRAM_CKE,   // SDRAM_CLK forwarded by the emu from clk_sdram (see sdram.sdc)
  output logic [7:0]  vid_r, vid_g, vid_b,
  output logic        hsync, vsync, hblank, vblank, de,
  output logic signed [15:0] audio_l, audio_r,
  output logic [31:0] pc_dbg,
  output logic        illegal_dbg,
  // boot-instrument taps (unused here — the loopback diag has no CPU; stubbed so the emu's
  // core-top port list is uniform across yunit_top / smashtv_diag_top).
  output logic        dbg_core_rst,
  output logic        dbg_sdram_ready,
  output logic        dbg_unp_done,
  output logic        dbg_cpu_req,
  output logic        dbg_mem_ack
);
  assign ioctl_wait  = 1'b0;
  assign dbg_core_rst = 1'b0; assign dbg_sdram_ready = 1'b0; assign dbg_unp_done = 1'b0;
  assign dbg_cpu_req  = 1'b0; assign dbg_mem_ack     = 1'b0;
  assign audio_l     = 16'sd0;
  assign audio_r     = 16'sd0;
  assign illegal_dbg = 1'b0;

  // ---- stock SDRAM controller (same one the real core now uses) ---------------
  logic [24:0] ctl_addr; logic [15:0] ctl_din, ctl_dout; logic [1:0] ctl_wtbt;
  logic        ctl_rd, ctl_we, ctl_ready;
  sdram_stock u_sdram (
    .init(rst), .clk(clk),
    .addr(ctl_addr), .din(ctl_din), .wtbt(ctl_wtbt), .we(ctl_we), .rd(ctl_rd),
    .dout(ctl_dout), .ready(ctl_ready),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE));

  // address-dependent test pattern: folds high address bits into the data so a wrong
  // row/col/bank mapping (aliasing) mismatches, not just stuck data bits.
  function automatic [15:0] patt(input [24:0] i);
    patt = i[15:0] ^ {i[23:16], i[23:16]} ^ 16'h5AA5;
  endfunction

  // ---- self-test FSM ----------------------------------------------------------
  typedef enum logic [2:0] { D_INIT, D_WISS, D_WWAIT, D_RISS, D_RWAIT, D_PASS, D_FAIL } dstate_t;
  dstate_t ds;
  logic [24:0] idx;                 // current word under test
  logic [31:0] miscount;            // number of read-back mismatches
  logic [24:0] first_fail;          // first failing word index
  logic        failed;              // sticky: any mismatch seen
  logic        settle;              // 1-cycle settle after issuing an edge pulse
  wire  [15:0] exp = patt(idx);

  always_ff @(posedge clk) begin
    if (rst) begin
      ds <= D_INIT; idx <= 25'd0; miscount <= 32'd0; first_fail <= 25'h1FFFFFF;
      failed <= 1'b0; ctl_rd <= 1'b0; ctl_we <= 1'b0; ctl_addr <= 25'd0;
      ctl_din <= 16'd0; ctl_wtbt <= 2'b11; settle <= 1'b0;
    end else begin
      ctl_rd <= 1'b0; ctl_we <= 1'b0;               // edge pulses -> default low
      case (ds)
        D_INIT: if (ctl_ready) begin idx <= 25'd0; ds <= D_WISS; end

        D_WISS: if (ctl_ready) begin
                  ctl_addr <= {idx[23:0], 1'b0};      // word -> byte addr (addr[0]=0)
                  ctl_din  <= exp; ctl_wtbt <= 2'b11; ctl_we <= 1'b1;
                  settle <= 1'b1; ds <= D_WWAIT;
                end
        D_WWAIT: if (settle) settle <= 1'b0;          // let ready fall after the edge
                 else if (ctl_ready) begin            // write complete
                   if (idx == DIAG_NWORDS-1) begin idx <= 25'd0; ds <= D_RISS; end
                   else begin idx <= idx + 25'd1; ds <= D_WISS; end
                 end

        D_RISS: if (ctl_ready) begin
                  ctl_addr <= {idx[23:0], 1'b0}; ctl_rd <= 1'b1;
                  settle <= 1'b1; ds <= D_RWAIT;
                end
        D_RWAIT: if (settle) settle <= 1'b0;
                 else if (ctl_ready) begin            // read data valid at ready
                   if (ctl_dout != exp) begin
                     miscount <= miscount + 32'd1; failed <= 1'b1;
                     if (first_fail == 25'h1FFFFFF) first_fail <= idx;
                   end
                   if (idx == DIAG_NWORDS-1)
                     ds <= (failed || (ctl_dout != exp)) ? D_FAIL : D_PASS;
                   else begin idx <= idx + 25'd1; ds <= D_RISS; end
                 end
        D_PASS: ds <= D_PASS;
        D_FAIL: ds <= D_FAIL;
        default: ds <= D_INIT;
      endcase
    end
  end

  // ---- video raster (identical geometry to yunit_video so HDMI locks the same) --
  localparam int H_TOTAL = H_ACT + H_FP + H_SYNC + H_BP;
  localparam int V_TOTAL = V_ACT + V_FP + V_SYNC + V_BP;
  logic [11:0] hc, vc;
  logic [23:0] frame;                       // frame counter -> moving liveness column
  always_ff @(posedge clk) begin
    if (rst) begin hc<=0; vc<=0; frame<=0; end
    else if (ce_pix) begin
      if (hc==H_TOTAL-1) begin
        hc<=0;
        if (vc==V_TOTAL-1) begin vc<=0; frame<=frame+24'd1; end else vc<=vc+12'd1;
      end else hc<=hc+12'd1;
    end
  end
  wire s0_de = (hc<H_ACT) && (vc<V_ACT);
  wire s0_hb = (hc>=H_ACT);
  wire s0_vb = (vc>=V_ACT);
  wire s0_hs = (hc>=H_ACT+H_FP) && (hc<H_ACT+H_FP+H_SYNC);
  wire s0_vs = (vc>=V_ACT+V_FP) && (vc<V_ACT+V_FP+V_SYNC);

  // body color by state (BLUE=init, YELLOW=testing, GREEN=pass, RED=fail)
  logic [7:0] br,bg,bb;
  always_comb begin
    case (ds)
      D_INIT:  begin br=8'h00; bg=8'h00; bb=8'hC0; end   // blue
      D_PASS:  begin br=8'h00; bg=8'hC0; bb=8'h00; end   // green
      D_FAIL:  begin br=8'hC0; bg=8'h00; bb=8'h00; end   // red
      default: begin br=8'h80; bg=8'h80; bb=8'h00; end   // yellow (testing)
    endcase
  end

  // 8-stripe SMPTE-ish bars (compile-time thresholds, no runtime divider)
  localparam int E = H_ACT/8;               // one eighth of the active width
  logic [7:0] cbr,cbg,cbb;
  wire [2:0] bar = (hc <   E) ? 3'd0 : (hc < 2*E) ? 3'd1 : (hc < 3*E) ? 3'd2 :
                   (hc < 4*E) ? 3'd3 : (hc < 5*E) ? 3'd4 : (hc < 6*E) ? 3'd5 :
                   (hc < 7*E) ? 3'd6 : 3'd7;
  always_comb begin
    case (bar)
      3'd0: {cbr,cbg,cbb}={8'hFF,8'hFF,8'hFF}; // white
      3'd1: {cbr,cbg,cbb}={8'hFF,8'hFF,8'h00}; // yellow
      3'd2: {cbr,cbg,cbb}={8'h00,8'hFF,8'hFF}; // cyan
      3'd3: {cbr,cbg,cbb}={8'h00,8'hFF,8'h00}; // green
      3'd4: {cbr,cbg,cbb}={8'hFF,8'h00,8'hFF}; // magenta
      3'd5: {cbr,cbg,cbb}={8'hFF,8'h00,8'h00}; // red
      3'd6: {cbr,cbg,cbb}={8'h00,8'h00,8'hFF}; // blue
      default:{cbr,cbg,cbb}={8'h00,8'h00,8'h00};// black
    endcase
  end

  // mismatch-count bar (bottom eighth): width ~ log2(miscount)
  wire [5:0] milog = miscount[31] ? 6'd32 :
                     miscount[24] ? 6'd25 : miscount[20] ? 6'd21 : miscount[16] ? 6'd17 :
                     miscount[12] ? 6'd13 : miscount[8]  ? 6'd9  : miscount[4]  ? 6'd5  :
                     miscount[1]  ? 6'd2  : (miscount[0] ? 6'd1 : 6'd0);
  wire [15:0] mibar_w = (H_ACT*milog) >> 5;      // (H_ACT*milog)/32
  wire        in_bars = (vc < V_ACT/8);
  wire        in_mibar= (vc >= (V_ACT - V_ACT/8));
  wire        live_col= (hc == frame[8:0]);      // moving white column

  always_ff @(posedge clk) if (ce_pix) begin
    de<=s0_de; hsync<=s0_hs; vsync<=s0_vs; hblank<=s0_hb; vblank<=s0_vb;
    if (!s0_de)            begin vid_r<=0;     vid_g<=0;     vid_b<=0;     end
    else if (in_bars)      begin vid_r<=cbr;   vid_g<=cbg;   vid_b<=cbb;   end
    else if (live_col)     begin vid_r<=8'hFF; vid_g<=8'hFF; vid_b<=8'hFF; end
    else if (in_mibar)     begin
      if ({4'd0,hc} < mibar_w) begin vid_r<=8'hFF; vid_g<=8'h00; vid_b<=8'h00; end
      else                     begin vid_r<=8'h20; vid_g<=8'h20; vid_b<=8'h20; end
    end
    else                   begin vid_r<=br;    vid_g<=bg;    vid_b<=bb;    end
  end

  assign pc_dbg = {2'd0, ds, first_fail};   // harmless; not routed on HW
endmodule
`default_nettype wire
