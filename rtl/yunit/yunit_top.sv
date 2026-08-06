// yunit_top.sv — Phase 6 W2: the synthesizable Y-unit core (everything below the
// Template_MiSTer chassis). Composes the proven pieces into one top the emu wraps:
//
//   tms34010_core  <-> yunit_memsys (CPU + DMA blitter + memory map; SYNTHESIS
//                      selects the external gfx/ROM/VRAM SDRAM ports)
//   yunit_sdram_arb + sdram_phy  : all SDRAM traffic (gfx ROM, prog ROM, VRAM,
//                      + ioctl ROM download) onto one MT48LC16M16 word port
//   yunit_video_top : VRAM(SDRAM) -> line buffer -> pen_map6 -> palette -> RGB
//   yunit_palram    : palette mirror (video read port, fed by CPU palette writes)
//   williams_cvsd_board : Y-unit sound (6809 + YM2151 + CVSD), on its own ~12 MHz
//                      clock; the sound latch is crossed clk -> clk_snd (CDC).
//
// Clocking: `clk` runs the CPU / memory / SDRAM / video logic; `ce_pix` gates the
// raster; `clk_snd` (~12 MHz) runs the sound board. Game/CPU speed calibration
// (the real 34010 runs far slower than the SDRAM clock) is a later tuning knob.
`default_nettype none

import yunit_pkg::*;
import tms34010_pkg::*;

module yunit_top
#(
  parameter ROM_HEX = "smashtv_maindata.hex",
  // video geometry (Smash T.V. stdres; see yunit_video)
  parameter int H_ACT=410, H_FP=6,  H_SYNC=40, H_BP=50,
  parameter int V_ACT=256, V_FP=13, V_SYNC=8,  V_BP=12,
  parameter int DISP_ROW0=0,
  // SDRAM word-address map (see rtl/sdram/yunit_sdram_arb.sv, tb_sdram_full)
  parameter [24:0] GFXW_BASE = 25'h000000,
  parameter [24:0] ROMW_BASE = 25'h0C0000,
  parameter [24:0] VRAMW_BASE= 25'h0E0000,
  parameter [23:0] GFX_BYTES = 24'h180000,
  parameter [24:0] SCRATCH_WBASE = 25'h120000,   // raw gfx planes (boot scratch)
  parameter [23:0] PLANE_WORDS   = 24'h30000     // words/plane (E2E sim overrides small)
)(
  input  logic        clk,        // core clock (memory + SDRAM + video logic), ~96 MHz
  input  logic        clk_cpu,    // CPU clock, ~24 MHz (TMS34010 execute path maxes ~30 MHz)
  input  logic        ce_pix,     // pixel-clock enable (video raster)
  input  logic        clk_snd,    // ~12 MHz sound-board clock
  input  logic        rst,        // core reset (active high)
  input  logic        rst_pon,    // power-on reset (sound board full init)

  input  logic [63:0] inputs,     // {DSW, IN2, IN1, IN0}, active-low

  // ioctl ROM download -> SDRAM word writes (gfx@GFXW_BASE, prog ROM@ROMW_BASE).
  // The MRA/loader presents a linear WORD address matching the SDRAM layout.
  input  logic        ioctl_download,  // held high during ROM load (holds the CPU in reset)
  input  logic        ioctl_wr,
  input  logic [24:0] ioctl_addr,   // SDRAM word address (gfx planes -> scratch, prog ROM)
  input  logic [15:0] ioctl_dout,
  input  logic [1:0]  ioctl_be,     // byte lane(s): 11=packed plane word, 01/10=interleaved ROM
  output logic        ioctl_wait,

  // MRA sound-ROM download (BYTE stream, clk domain). addr[17:16]=chip (0=U4 1=U19
  // 2=U20), addr[15:0]=byte within the 64KB chip. Routed to the CVSD board's BRAMs.
  input  logic        snd_dl_wr,
  input  logic [17:0] snd_dl_addr,
  input  logic [7:0]  snd_dl_data,

  // SDRAM (MT48LC16M16) pins
  inout  wire  [15:0] SDRAM_DQ,
  output logic [12:0] SDRAM_A,
  output logic [1:0]  SDRAM_BA,
  output logic        SDRAM_DQML, SDRAM_DQMH,
  output logic        SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE,
  output logic        SDRAM_CKE,
  // NOTE: SDRAM_CLK is NOT a port here — the emu forwards it from clk_sdram (outclk_1,
  // -3515ps) directly to the pin, matching rtl/sdram.sdc (general[1]) and the proven
  // tecmo/jtframe cores. Keeping it out of the core avoids double-driving the pin.

  // video out
  output logic [7:0]  vid_r, vid_g, vid_b,
  output logic        hsync, vsync, hblank, vblank, de,

  // audio out (signed PCM)
  output logic signed [15:0] audio_l, audio_r,

  // debug
  output logic [31:0] pc_dbg,
  output logic        illegal_dbg,
  // boot-instrument taps (observability only; read by the DIAG_BOOT overlay). Unconnected
  // in the normal build — pure outputs, no behavioral effect.
  output logic        dbg_core_rst,
  output logic        dbg_sdram_ready,
  output logic        dbg_unp_done,
  output logic        dbg_cpu_req,
  output logic        dbg_mem_ack
);
  // Hold the CPU / memory / video in reset until the SDRAM controller has finished
  // its power-up init (the real MiSTer pattern: the core waits for SDRAM ready +
  // ROM load). Without this the CPU's first fetch rises DURING init and the phy's
  // rising-edge accept misses it -> the held request deadlocks. The SDRAM phy +
  // arbiter run on the raw `rst` so init can proceed while the core is held.
  // sdram_ready is driven by the stock-SDRAM adapter (sticky: it latches the controller's
  // first `ready` = power-up init complete). The adapter + sdram_stock run on raw `rst`.
  logic sdram_ready;
  // Boot-time SDRAM scratch for the raw gfx planes (see yunit_gfx_unpack): plane0 @
  // SCRATCH_WBASE, plane1 @ +PLANE_WORDS, plane2 @ +2*PLANE_WORDS (module parameters).
  // unp_done: gfx unpack complete. 1 in sim (the tb preloads flat gfx directly);
  // in synth it rises only after the boot-time planar->flat pass finishes.
  logic unp_done;
  // Hold the core during ROM download AND the subsequent gfx-unpack pass: SDRAM stays
  // initialized (ready) so the ioctl/unpack channels can write it, while the CPU/video
  // wait until the ROMs are loaded and the gfx is unpacked.
  wire  core_rst = rst | ~sdram_ready | ioctl_download | ~unp_done;

  // ---- CPU (clk_cpu ~24 MHz) <-> memsys (clk_sys 96 MHz) via CDC adapter -------
  // The vendored TMS34010's combinational execute path maxes ~30 MHz; memsys/SDRAM/
  // video need 96 MHz. So the CPU runs on clk_cpu and yunit_mem_cdc bridges its
  // req/ack memory interface to memsys on clk_sys. Reset + the DMA interrupt (int1)
  // are synchronized into clk_cpu.
  logic core_rst_cpu_m, core_rst_cpu;
  always_ff @(posedge clk_cpu) begin core_rst_cpu_m <= core_rst; core_rst_cpu <= core_rst_cpu_m; end
  logic int1, int1_m, int1_cpu;
  always_ff @(posedge clk_cpu) begin int1_m <= int1; int1_cpu <= int1_m; end

  // CPU-domain memory interface (clk_cpu)
  logic cpu_req, cpu_we; logic [ADDR_WIDTH-1:0] cpu_addr; logic [FIELD_SIZE_WIDTH-1:0] cpu_size;
  logic [DATA_WIDTH-1:0] cpu_wdata, cpu_rdata; logic cpu_ack;
  core_state_t state_w; instr_word_t instr_w;

  tms34010_core u_core (
    .clk(clk_cpu), .rst(core_rst_cpu),
    .mem_req(cpu_req), .mem_we(cpu_we), .mem_addr(cpu_addr), .mem_size(cpu_size),
    .mem_wdata(cpu_wdata), .mem_rdata(cpu_rdata), .mem_ack(cpu_ack),
    .state_o(state_w), .pc_o(pc_dbg), .instr_word_o(instr_w),
    .illegal_opcode_o(illegal_dbg), .lint1_in(int1_cpu));

  // memsys-domain memory interface (clk_sys); fed by the CDC's memsys side
  logic mem_req, mem_we; logic [ADDR_WIDTH-1:0] mem_addr; logic [FIELD_SIZE_WIDTH-1:0] mem_size;
  logic [DATA_WIDTH-1:0] mem_wdata, mem_rdata; logic mem_ack;

  yunit_mem_cdc #(.AW(ADDR_WIDTH), .DW(DATA_WIDTH), .SW(FIELD_SIZE_WIDTH)) u_memcdc (
    .clk_cpu(clk_cpu), .rst_cpu(core_rst_cpu),
    .c_req(cpu_req), .c_we(cpu_we), .c_addr(cpu_addr), .c_size(cpu_size), .c_wdata(cpu_wdata),
    .c_ack(cpu_ack), .c_rdata(cpu_rdata),
    .clk_sys(clk), .rst_sys(core_rst),
    .m_req(mem_req), .m_we(mem_we), .m_addr(mem_addr), .m_size(mem_size), .m_wdata(mem_wdata),
    .m_rdata(mem_rdata), .m_ack(mem_ack));

  // ---- memsys external channels ----------------------------------------------
  logic        src_req;  logic [23:0] src_addr;  logic [7:0] src_data;  logic src_ack;
  logic        cgfx_rd;  logic [23:0] cgfx_addr; logic [7:0] cgfx_data; logic cgfx_ack;
  logic        scan_req; logic [17:0] scan_addr; logic [15:0] scan_data; logic scan_ack;
  logic [24:0] vsd_addr; logic [15:0] vsd_din, vsd_dout; logic [1:0] vsd_be;
  logic        vsd_rd, vsd_wr, vsd_ack;
  logic [7:0]  snd_select; logic snd_trig, snd_reset;
  logic        erase_busy, blit_busy;
  // palette write-tap
  logic        palv_we_a, palv_we_b; logic [12:0] palv_aa, palv_ba; logic [15:0] palv_awd, palv_bwd;

  // autoerase: whole-frame sweep triggered at vblank (post-scanout model, frame-
  // gate verified). row0 = DISP_ROW0, lines = V_ACT.
  logic vblank_irq;

  yunit_memsys #(.ROM_HEX(ROM_HEX)) u_sys (
    .clk(clk), .rst(core_rst),
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_size(mem_size),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack),
    .src_req(src_req), .src_addr(src_addr), .src_data(src_data), .src_ack(src_ack),
    .inputs(inputs), .int1(int1),
    .snd_select(snd_select), .snd_trig(snd_trig), .snd_reset(snd_reset),
    .erase_start(vblank_irq), .erase_row0(9'(DISP_ROW0)), .erase_lines(10'(V_ACT)),
    .erase_busy(erase_busy), .blit_busy(blit_busy),
    // external gfx/ROM read (CPU gfx window)
    .cpu_gfx_rd(cgfx_rd), .cpu_gfx_raddr(cgfx_addr), .cpu_gfx_rdata(cgfx_data), .cpu_gfx_rack(cgfx_ack),
    // VRAM SDRAM channel + video scanout (memsys's fb_ack is internal — not a port)
    .scan_req(scan_req), .scan_addr(scan_addr), .scan_data(scan_data), .scan_ack(scan_ack),
    .vsd_addr(vsd_addr), .vsd_din(vsd_din), .vsd_be(vsd_be), .vsd_rd(vsd_rd), .vsd_wr(vsd_wr),
    .vsd_dout(vsd_dout), .vsd_ack(vsd_ack),
    // palette write-tap
    .palv_we_a(palv_we_a), .palv_aa(palv_aa), .palv_awd(palv_awd),
    .palv_we_b(palv_we_b), .palv_ba(palv_ba), .palv_bwd(palv_bwd));

  // ---- video subsystem -------------------------------------------------------
  logic [11:0] pal_raddr; logic [15:0] pal_rdata;
  yunit_video_top #(
    .H_ACT(H_ACT), .H_FP(H_FP), .H_SYNC(H_SYNC), .H_BP(H_BP),
    .V_ACT(V_ACT), .V_FP(V_FP), .V_SYNC(V_SYNC), .V_BP(V_BP),
    .DISP_ROW0(DISP_ROW0), .NCOL(512)
  ) u_video (
    .clk(clk), .rst(core_rst), .ce_pix(ce_pix),
    .pal_raddr(pal_raddr), .pal_rdata(pal_rdata),
    .scan_req(scan_req), .scan_addr(scan_addr), .scan_data(scan_data), .scan_ack(scan_ack),
    .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
    .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank), .de(de),
    .vblank_irq(vblank_irq));

  // ---- palette mirror (video read port) --------------------------------------
  yunit_palram #(.AW(13)) u_pal (
    .clk(clk), .rst(core_rst),
    .we_a(palv_we_a), .aa(palv_aa), .awd(palv_awd),
    .we_b(palv_we_b), .ba(palv_ba), .bwd(palv_bwd),
    .raddr({1'b0, pal_raddr}), .rdata(pal_rdata));

  // ---- SDRAM arbiter + physical controller -----------------------------------
  logic [24:0] sd_addr; logic [15:0] sd_din, sd_dout; logic [1:0] sd_be; logic sd_rd, sd_wr, sd_ack;
  logic        iol_ack;

  // ioctl SDRAM-write latch + HPS backpressure. The emu presents each SDRAM ROM write
  // as a 1-cycle pulse (ioctl_wr) + addr/data/be; latch it and HOLD the arbiter iol
  // request until the phy acks (a bare pulse can land in the arbiter's inter-command
  // bubble and be dropped). ioctl_wait pauses the HPS while a write is outstanding so
  // the download can't outrun the SDRAM (assert on the issue cycle too, to cover the
  // 1-cycle latch latency). Boot: iol is top priority + video is held, so it drains fast.
  logic        iol_hold;
  logic [24:0] iol_addr_r; logic [15:0] iol_din_r; logic [1:0] iol_be_r;
  always_ff @(posedge clk) begin
    if (rst) iol_hold <= 1'b0;
    else if (ioctl_wr && !iol_hold) begin
      iol_addr_r <= ioctl_addr; iol_din_r <= ioctl_dout; iol_be_r <= ioctl_be; iol_hold <= 1'b1;
    end else if (iol_hold && iol_ack) iol_hold <= 1'b0;
  end
  // Backpressure the HPS while a ROM-download word is latched/outstanding: assert on the
  // issue cycle (ioctl_wr) AND until the phy acks it (iol_hold). WITHOUT this, a fast HPS
  // burst delivers the next word while iol_hold is still set for the previous one, and the
  // `else if (ioctl_wr && !iol_hold)` guard above SILENTLY DROPS it -> Swiss-cheesed program
  // ROM in SDRAM -> the CPU wedges on boot (black/silent). (Was tied to 1'b0 during bring-up
  // on the false premise that "no loading boxes" meant a stuck wait — small ROMs simply never
  // draw boxes; the wait was never stuck. Restored.)
  assign ioctl_wait = iol_hold | ioctl_wr;

  // gfx-unpack master (boot only). unp_rd/wr/addr/din come FROM the unpack FSM; its
  // dout/ack are driven from the shared boot iol channel below.
  logic        unp_rd, unp_wr, unp_ack;
  logic [24:0] unp_addr; logic [15:0] unp_din, unp_dout;

  // Boot SDRAM channel = ioctl download (write, via the iol_hold latch) MUXED WITH the
  // gfx-unpack (rd+wr) — disjoint in time (download drains, THEN unpack runs; the unpack
  // start is gated on iol_hold==0 below). Folding them into the arbiter's single iol
  // channel keeps the run-time sd_addr mux 4-way (was 5 with a separate unp channel),
  // shortening the scan_req -> SDRAM_A address path.
  wire        boot_unp   = unp_rd | unp_wr;
  wire        b_iol_rd   = unp_rd;
  wire        b_iol_wr   = boot_unp ? unp_wr   : iol_hold;
  wire [24:0] b_iol_addr = boot_unp ? unp_addr : iol_addr_r;
  wire [15:0] b_iol_din  = boot_unp ? unp_din  : iol_din_r;
  wire [1:0]  b_iol_be   = boot_unp ? 2'b11    : iol_be_r;
  wire [15:0] iol_dout;
  assign unp_dout = iol_dout;
  assign unp_ack  = iol_ack & boot_unp;

  yunit_sdram_arb #(
    .SD_AW(25), .GFXW_BASE(GFXW_BASE), .ROMW_BASE(ROMW_BASE),
    .VRAMW_BASE(VRAMW_BASE), .GFX_BYTES(GFX_BYTES)
  ) u_arb (
    .clk(clk), .rst(rst),
    .vsd_addr(vsd_addr), .vsd_din(vsd_din), .vsd_be(vsd_be), .vsd_rd(vsd_rd), .vsd_wr(vsd_wr),
    .vsd_dout(vsd_dout), .vsd_ack(vsd_ack),
    .cgfx_rd(cgfx_rd), .cgfx_addr(cgfx_addr), .cgfx_data(cgfx_data), .cgfx_ack(cgfx_ack),
    .src_rd(src_req), .src_addr(src_addr), .src_data(src_data), .src_ack(src_ack),
    .iol_rd(b_iol_rd), .iol_wr(b_iol_wr), .iol_addr(b_iol_addr), .iol_din(b_iol_din),
    .iol_be(b_iol_be), .iol_dout(iol_dout), .iol_ack(iol_ack),
    .sd_addr(sd_addr), .sd_din(sd_din), .sd_be(sd_be), .sd_rd(sd_rd), .sd_wr(sd_wr),
    .sd_dout(sd_dout), .sd_ack(sd_ack));

  // ---- gfx planar->flat unpack (boot only) -----------------------------------
  // Synth: run the pass once when the ROM download drops, holding the core (via
  // unp_done) until it completes. Sim: the tb preloads the flat gfx directly, so we
  // tie unp_done=1 and leave the unp channel idle (identical to the proven boot tb).
`ifdef SYNTHESIS
  logic dl_q, dl_seen, unp_pending, unp_start, unp_fsm_done;
  always_ff @(posedge clk) begin
    dl_q      <= ioctl_download;
    unp_start <= 1'b0;
    if (rst) begin dl_seen <= 1'b0; unp_pending <= 1'b0; end
    else begin
      if (ioctl_download) dl_seen <= 1'b1;                 // a ROM download occurred
      if (dl_q & ~ioctl_download)      unp_pending <= 1'b1; // download just ended
      else if (unp_pending & ~iol_hold) begin              // last iol write drained ->
        unp_pending <= 1'b0; unp_start <= 1'b1;             // fire the unpack (1-cyc pulse)
      end
    end
  end
  yunit_gfx_unpack #(
    .SD_AW(25), .SCRATCH_WBASE(SCRATCH_WBASE), .GFXW_BASE(GFXW_BASE),
    .PLANE_WORDS(PLANE_WORDS)
  ) u_unpack (
    .clk(clk), .rst(rst), .start(unp_start), .busy(), .done(unp_fsm_done),
    .unp_rd(unp_rd), .unp_wr(unp_wr), .unp_addr(unp_addr), .unp_din(unp_din),
    .unp_dout(unp_dout), .unp_ack(unp_ack));
  // Only REQUIRE the unpack once a download has actually happened. With no download
  // (a soft reset that keeps the already-unpacked gfx in SDRAM, or a preloaded sim),
  // dl_seen=0 -> unp_done=1 so the CPU boots on the existing flat gfx.
  assign unp_done = ~dl_seen | unp_fsm_done;
`else
  assign unp_done = 1'b1;
  assign unp_rd = 1'b0; assign unp_wr = 1'b0; assign unp_addr = 25'd0; assign unp_din = 16'd0;
`endif

  // ---- stock SDRAM controller (Sorgelig) + arbiter adapter ----------------------
  // Replaces the hand-rolled sdram_phy. The stock controller forwards SDRAM_CLK via a DDIO
  // I/O cell (not a fabric assign) and uses the DE10-proven CAS-latency read capture — the
  // fix for reads landing in the wrong window on real silicon. The adapter bridges the
  // arbiter's held sd_rd/sd_wr/ack handshake to the controller's edge we/rd + `ready` level.
  // `init`=rst (level high during reset); the controller runs its power-up sequence when it
  // drops. sdram_ready comes from the adapter (latches the controller's first ready).
  logic [24:0] ctl_addr; logic [15:0] ctl_din, ctl_dout; logic [1:0] ctl_wtbt;
  logic        ctl_rd, ctl_we, ctl_ready;

  yunit_sdram_adapter u_sdadapt (
    .clk(clk), .rst(rst),
    .sd_addr(sd_addr), .sd_din(sd_din), .sd_be(sd_be), .sd_rd(sd_rd), .sd_wr(sd_wr),
    .sd_dout(sd_dout), .sd_ack(sd_ack), .sdram_ready(sdram_ready),
    .ctl_addr(ctl_addr), .ctl_din(ctl_din), .ctl_wtbt(ctl_wtbt),
    .ctl_rd(ctl_rd), .ctl_we(ctl_we), .ctl_dout(ctl_dout), .ctl_ready(ctl_ready));

  sdram_stock u_sdram (
    .init(rst), .clk(clk),
    .addr(ctl_addr), .din(ctl_din), .wtbt(ctl_wtbt), .we(ctl_we), .rd(ctl_rd),
    .dout(ctl_dout), .ready(ctl_ready),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE));

  // ---- sound-latch CDC: clk -> clk_snd ---------------------------------------
  // snd_select is a held bus; snd_trig is a 1-clk pulse (new command). Cross with
  // a toggle: flip on each trig, 2-FF sync into clk_snd, edge-detect -> 1-(snd)clk
  // pulse. snd_reset is a level (2-FF sync).
  logic        cmd_toggle;
  logic [7:0]  cmd_sel_q;
  always_ff @(posedge clk) begin
    if (rst) begin cmd_toggle <= 1'b0; cmd_sel_q <= 8'h00; end
    else if (snd_trig) begin cmd_toggle <= ~cmd_toggle; cmd_sel_q <= snd_select; end
  end
  (* preserve *) logic [2:0] tgl_sync;
  (* preserve *) logic [1:0] rst_sync;
  logic [7:0]  sel_sync;
  logic        strig_snd;
  always_ff @(posedge clk_snd) begin
    tgl_sync <= {tgl_sync[1:0], cmd_toggle};
    rst_sync <= {rst_sync[0], snd_reset};
    sel_sync <= cmd_sel_q;                       // slow bus; stable at sample
    strig_snd <= tgl_sync[2] ^ tgl_sync[1];      // edge -> 1-clk pulse
  end

  logic [7:0]  pia_audio; logic [15:0] speech_out;
  logic signed [15:0] ym_l, ym_r; logic [31:0] snd_dbg;
  williams_cvsd_board u_board (
    .clock_12(clk_snd), .reset(rst_sync[1]), .reset_pon(rst_pon),
    .sound_select(sel_sync), .sound_trig(strig_snd),
    .pia_audio(pia_audio), .speech_out(speech_out),
    .ym2151_left(ym_l), .ym2151_right(ym_r), .dbg_out(snd_dbg),
    // MRA sound-ROM load (ioctl clk domain -> board's dual-clock ROM BRAMs)
    .snd_dl_clk(clk), .snd_dl_addr(snd_dl_addr),
    .snd_dl_data(snd_dl_data), .snd_dl_we(snd_dl_wr));

  // ---- audio mix -------------------------------------------------------------
  // YM2151 (signed) + CVSD speech DAC (unsigned, centered) + PIA DAC (unsigned).
  // Simple summed mix with headroom; exact levels are a later tuning pass.
  wire signed [15:0] speech_s = $signed({1'b0, speech_out}) - 16'sd16384;   // ~center
  wire signed [15:0] pia_s    = {{8{pia_audio[7]}}, pia_audio} <<< 6;        // small DAC, scaled
  always_ff @(posedge clk_snd) begin
    audio_l <= ym_l + (speech_s >>> 1) + (pia_s >>> 2);
    audio_r <= ym_r + (speech_s >>> 1) + (pia_s >>> 2);
  end

  // ---- boot-instrument taps (DIAG_BOOT overlay reads these; harmless in normal build) ----
  assign dbg_core_rst    = core_rst;
  assign dbg_sdram_ready = sdram_ready;
  assign dbg_unp_done    = unp_done;
  assign dbg_cpu_req     = cpu_req;
  assign dbg_mem_ack     = mem_ack;
endmodule
`default_nettype wire
