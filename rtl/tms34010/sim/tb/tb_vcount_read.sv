// -----------------------------------------------------------------------------
// tb_vcount_read.sv
//
// Directed test for LIVE VCOUNT/HCOUNT reads through tms34010_io_regs (P00xx).
// Reproduces NBA Hangtime's display_blank-style spin (SRC/BB.ASM #nxt):
//
//     movi VCOUNT,a7
//   #lp   move *a7,a0      ; read VCOUNT
//         jrnz #lp         ; wait while VCOUNT != 0
//   #lp2  move *a7,a0      ; read VCOUNT
//         jrz  #lp2        ; wait while VCOUNT == 0   <-- hangs forever if VCOUNT dead
//
// Before the fix, CPU reads of VCOUNT returned the STORED io_reg (never written
// by the game -> constant 0), so #lp2 spun forever = the guaranteed hang. This
// TB drives the real ce_pix enable, programs a raster, and requires BOTH spin
// loops to TERMINATE within a watchdog. Discriminating: revert the rdata mux to
// io_reg[idx] and #lp2 never leaves 0 -> watchdog FAIL.
//
// Also spot-checks HCOUNT liveness.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_vcount_read;
  import tms34010_pkg::*;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;

  // Real dot-clock enable (1-in-2) threaded into io_regs -> u_video.
  logic ce_div = 1'b0;
  logic ce_pix;
  always_ff @(posedge clk) ce_div <= ~ce_div;
  assign ce_pix = ce_div;

  logic                  req, we;
  logic [ADDR_WIDTH-1:0] addr;
  logic [FIELD_SIZE_WIDTH-1:0] size = FIELD_SIZE_WIDTH'(16);
  logic [15:0]           wdata, rdata;
  logic                  is_io;
  logic [15:0]           psize_w, convdp_w, convsp_w, control_w, pmask_w;
  logic [15:0]           intenb_w, intpend_w, hstctlh_w;

  tms34010_io_regs u_io (
    .clk(clk), .rst(rst),
    .req(req), .we(we), .addr(addr), .size(size), .wdata(wdata),
    .ce_pix(ce_pix),
    .rdata(rdata), .is_io(is_io),
    .psize_o(psize_w), .convdp_o(convdp_w), .convsp_o(convsp_w),
    .control_o(control_w), .pmask_o(pmask_w),
    .intenb_o(intenb_w), .intpend_o(intpend_w),
    .hstctlh_o(hstctlh_w), .nmi_clear(1'b0), .wvp_set(1'b0)
  );

  // Raster: small so VCOUNT sweeps quickly. HTOTAL=3 (4 dots/line),
  // VTOTAL=5 (VCOUNT sweeps 0..5).
  localparam logic [15:0] HTOTAL = 16'd3, VTOTAL = 16'd5;
  localparam logic [15:0] DPYINT = 16'd2;

  function automatic logic [ADDR_WIDTH-1:0] io_addr(input logic [IO_REG_IDX_W-1:0] i);
    return IO_BASE_ADDR + (ADDR_WIDTH'(i) << 4);
  endfunction

  localparam logic [ADDR_WIDTH-1:0] A_VCOUNT = IO_BASE_ADDR + (32'(IO_IDX_VCOUNT) << 4);
  localparam logic [ADDR_WIDTH-1:0] A_HCOUNT = IO_BASE_ADDR + (32'(IO_IDX_HCOUNT) << 4);

  int unsigned failures;

  task automatic io_write(input logic [IO_REG_IDX_W-1:0] i, input logic [15:0] d);
    @(negedge clk);
    req = 1'b1; we = 1'b1; addr = io_addr(i); wdata = d;
    @(negedge clk);
    req = 1'b0; we = 1'b0;
  endtask

  // Advance one clk, then read the addressed reg (async rdata).
  task automatic step_read(input logic [ADDR_WIDTH-1:0] a, output logic [15:0] d);
    @(posedge clk);
    addr = a; we = 1'b0; req = 1'b1;
    #1;
    d = rdata;
  endtask

  localparam int unsigned MAXI = 500;  // >> one frame (K*(HTOTAL+1)*(VTOTAL+1)=48 clks)

  logic [15:0] v, h0, h1;
  int unsigned iters;
  logic        saw_nonzero;
  logic [15:0] max_vc;

  initial begin : main
    failures = 0; req = 0; we = 0; addr = '0; wdata = '0;
    saw_nonzero = 0; max_vc = '0;

    repeat (3) @(posedge clk);
    @(negedge clk); rst = 1'b0;

    // Program the raster (only the regs the counters need).
    io_write(IO_IDX_HTOTAL, HTOTAL);
    io_write(IO_IDX_VTOTAL, VTOTAL);
    io_write(IO_IDX_DPYINT, DPYINT);

    // -- display_blank spin, loop 1: wait while VCOUNT != 0 --------------------
    iters = 0;
    do begin
      step_read(A_VCOUNT, v);
      if (v > max_vc) max_vc = v;
      iters++;
      if (iters > MAXI) begin fail_hang("loop1 (wait VCOUNT==0)"); disable main; end
    end while (v != 16'd0);

    // -- loop 2: wait while VCOUNT == 0 (THE loop that hangs on a dead VCOUNT) -
    iters = 0;
    do begin
      step_read(A_VCOUNT, v);
      if (v != 16'd0) saw_nonzero = 1;
      if (v > max_vc) max_vc = v;
      iters++;
      if (iters > MAXI) begin fail_hang("loop2 (wait VCOUNT!=0) -- VCOUNT reads dead/stored 0"); disable main; end
    end while (v == 16'd0);

    if (!saw_nonzero) begin
      $display("TEST_RESULT: FAIL: loop2 terminated but VCOUNT never observed nonzero");
      failures++;
    end

    // VCOUNT must sweep the full range (proves a real live counter, not a glitch).
    // Keep reading for two frames; capture the peak.
    for (int unsigned k = 0; k < 4*(HTOTAL+1)*(VTOTAL+1); k++) begin
      step_read(A_VCOUNT, v);
      if (v > max_vc) max_vc = v;
    end
    if (max_vc != VTOTAL) begin
      $display("TEST_RESULT: FAIL: VCOUNT peaked at %0d, expected VTOTAL=%0d", max_vc, VTOTAL);
      failures++;
    end

    // HCOUNT liveness: two reads a few clks apart must differ at some point.
    step_read(A_HCOUNT, h0);
    @(posedge clk); @(posedge clk);
    step_read(A_HCOUNT, h1);
    if (h0 === h1) begin
      // one more spread in case we straddled equal phase
      @(posedge clk); step_read(A_HCOUNT, h1);
    end
    if (h0 === h1) begin
      $display("TEST_RESULT: FAIL: HCOUNT did not advance across reads (h0=%0d h1=%0d)", h0, h1);
      failures++;
    end

    if (failures == 0)
      $display("TEST_RESULT: PASS (VCOUNT/HCOUNT live: display_blank spin terminates, VCOUNT sweeps 0..%0d)", VTOTAL);
    else
      $display("TEST_RESULT: FAIL: %0d check(s) failed", failures);
    $finish;
  end

  task automatic fail_hang(input string which);
    $display("TEST_RESULT: FAIL: display_blank spin HUNG in %s (>%0d clks)", which, MAXI);
    failures++;
  endtask

  initial begin : watchdog
    #5_000_000;
    $display("TEST_RESULT: FAIL: tb_vcount_read hard timeout");
    $fatal(1);
  end

endmodule : tb_vcount_read
