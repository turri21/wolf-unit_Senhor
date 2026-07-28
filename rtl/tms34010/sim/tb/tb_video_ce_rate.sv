// -----------------------------------------------------------------------------
// tb_video_ce_rate.sv
//
// Directed test for the DOT-CLOCK `ce` gating of tms34010_video (P00xx fix for
// the UMK3/NBA boot derail: the fork-inherited bug advanced the video counters
// at the CORE clock, so DPYINT fired ~12x too fast).
//
// Proves, with `ce` driven as a 1-in-K clock-enable (K models 96 MHz / 8 MHz):
//   (1) HCOUNT/VCOUNT advance ONCE PER ce tick -- they HOLD on non-ce clocks
//       (the discriminating property: remove the gate and they change every clk).
//   (2) DPYINT_PULSE fires EXACTLY ONCE PER FRAME, at HCOUNT==0 && VCOUNT==DPYINT.
//   (3) The clk period between successive DPYINT strobes ==
//       K * (HTOTAL+1) * (VTOTAL+1)  -- i.e. the frame period scales with the
//       dot-clock divisor K. This is the MAME cross-check: with ce = 8 MHz and
//       the game's HTOTAL/VTOTAL, DPYINT fires at MAME's frame rate; before the
//       fix (K effectively 1) it fired K-times too fast.
//
// Timing (scaled): HTOTAL=7 (8 dots/line), VTOTAL=4 (5 lines/frame), DPYINT=2.
// K=4 -> FRAME_CLKS = 4 * 8 * 5 = 160 clks/frame.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_video_ce_rate;
  import tms34010_pkg::*;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;

  // Dot-clock enable: 1-in-K (K=4 models 96 MHz core / 4 ... any K>1 proves the
  // rate scaling; the real path uses cediv==0 of a /12 counter).
  localparam int K = 4;
  logic [$clog2(K)-1:0] cediv = '0;
  logic ce;
  always_ff @(posedge clk) cediv <= (cediv == K-1) ? '0 : cediv + 1'b1;
  assign ce = (cediv == '0);

  localparam logic [15:0] HESYNC = 16'd2, HEBLNK = 16'd3, HSBLNK = 16'd6, HTOTAL = 16'd7;
  localparam logic [15:0] VESYNC = 16'd1, VEBLNK = 16'd1, VSBLNK = 16'd3, VTOTAL = 16'd4;
  localparam logic [15:0] DPYINT = 16'd2;

  localparam int FRAME_CLKS = K * (HTOTAL + 1) * (VTOTAL + 1); // = 160

  logic [15:0] hcount, vcount;
  logic        hsync, vsync, hblank, vblank, blank, dpyint_pulse;

  tms34010_video u_video (
    .clk(clk), .rst(rst), .ce(ce),
    .hesync(HESYNC), .heblnk(HEBLNK), .hsblnk(HSBLNK), .htotal(HTOTAL),
    .vesync(VESYNC), .veblnk(VEBLNK), .vsblnk(VSBLNK), .vtotal(VTOTAL),
    .dpyint(DPYINT),
    .hcount(hcount), .vcount(vcount),
    .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),
    .blank(blank), .dpyint_pulse(dpyint_pulse)
  );

  int unsigned failures;
  int unsigned dpyint_count;
  int unsigned tick;            // clk-cycle counter (negedge samples)
  int          last_strobe;     // tick of the previous DPYINT strobe (-1 = none)
  logic        have_prev;
  logic [15:0] prev_hc, prev_vc;
  logic        prev_ce;

  task automatic fail(input string msg);
    $display("TEST_RESULT: FAIL: %s (tick=%0d hc=%0d vc=%0d ce=%0b)",
             msg, tick, hcount, vcount, ce);
    failures++;
  endtask

  initial begin : main
    failures = 0; dpyint_count = 0; tick = 0; last_strobe = -1;
    have_prev = 0; prev_ce = 0;

    repeat (3) @(posedge clk);
    @(negedge clk); rst = 1'b0;

    // Run ~5 full frames.
    for (int unsigned k = 0; k < 5*FRAME_CLKS + 8; k++) begin
      @(negedge clk);

      // (1) dot-rate gating: counters HOLD on non-ce clocks. Between this
      //     negedge and the previous one, the intervening posedge advanced the
      //     counters iff ce was high just before it (== prev_ce). If prev_ce==0,
      //     hcount/vcount MUST be unchanged. (Discriminating: without the gate
      //     they change every clk -> fails whenever prev_ce==0.)
      if (have_prev && !prev_ce) begin
        if (hcount !== prev_hc) fail("HCOUNT changed on a non-ce clock");
        if (vcount !== prev_vc) fail("VCOUNT changed on a non-ce clock");
      end

      // (2) DPYINT strobe: exactly at HCOUNT==0 && VCOUNT==DPYINT, one clk wide.
      if (dpyint_pulse) begin
        if (hcount !== 16'd0)   fail("DPYINT strobe with HCOUNT != 0");
        if (vcount !== DPYINT)  fail("DPYINT strobe at wrong VCOUNT");
        dpyint_count++;
        // (3) rate: clk-spacing between strobes == one frame period.
        if (last_strobe >= 0) begin
          if ((tick - last_strobe) != FRAME_CLKS) begin
            $display("TEST_RESULT: FAIL: DPYINT spacing = %0d clks, expected %0d (K*(HTOTAL+1)*(VTOTAL+1))",
                     tick - last_strobe, FRAME_CLKS);
            failures++;
          end
        end
        last_strobe = tick;
      end

      prev_hc = hcount; prev_vc = vcount; prev_ce = ce; have_prev = 1;
      tick++;
    end

    // Over 5 frames we must have seen at least 4 full inter-strobe intervals.
    if (dpyint_count < 4) begin
      $display("TEST_RESULT: FAIL: DPYINT fired %0d times over ~5 frames (expected >= 4)",
               dpyint_count);
      failures++;
    end

    if (failures == 0)
      $display("TEST_RESULT: PASS (video ce-rate: dot-gated counters, 1 DPYINT/frame, spacing==%0d clks)",
               FRAME_CLKS);
    else
      $display("TEST_RESULT: FAIL: %0d check(s) failed", failures);
    $finish;
  end

  initial begin : watchdog
    #2_000_000;
    $display("TEST_RESULT: FAIL: tb_video_ce_rate hard timeout");
    $fatal(1);
  end

endmodule : tb_video_ce_rate
