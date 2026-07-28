// yunit_memsys.sv — Y-unit memory subsystem: yunit_mem + yunit_dma glued into
// one slave on the TMS34010 core's request-valid memory interface.
//
// This is the block the CPU talks to. It routes:
//   - the DMA blitter register region (0x01A00000, mirror +0x80000) -> yunit_dma
//   - everything else                                               -> yunit_mem
// and wires the blitter back into VRAM: yunit_dma.fb_* -> yunit_mem VRAM write
// port, yunit_dma.dma_palette -> yunit_mem CPU vram_w byte-lane.
//
// The unpacked gfx-ROM read (yunit_dma.src_*) is exposed as ports — on HW it is
// backed by SDRAM; in sim by a gfx model. (CPU reads of the gfx *window*
// 0x02000000, used only by the boot checksum, are still handled by yunit_mem
// and currently return 0 — wired when the boot checksum path is exercised.)
//
// Interrupts (P0016, corrects the 2026-07-04 "poll-driven only" misread): the
// POST/self-test polls DMA_COMMAND bit15, but the GAME's per-frame draw uses a
// blit QUEUE pumped by the INT1 ISR (vector -> ffe00000): DMA-done ASSERTS
// LINT1 (MAME dma_callback), any COMMAND write CLEARS it (MAME dma_w). That is
// yunit_dma.blit_irq -> the int1 output -> tms34010_core.lint1_in.

`default_nettype none

// Mirror yunit_mem's synthesis auto-defines so the guarded ports/wiring here match
// (macros defined in yunit_mem.sv also persist in a single compile, but be explicit).
`ifdef SYNTHESIS
  `ifndef USE_EXT_GFX
    `define USE_EXT_GFX
  `endif
  `ifndef USE_EXT_ROM
    `define USE_EXT_ROM
  `endif
  `ifndef USE_SDRAM_VRAM
    `define USE_SDRAM_VRAM
  `endif
  `ifndef USE_HW_RAM
    `define USE_HW_RAM
  `endif
`endif
`ifdef USE_EXT_GFX
  `define YM_EXT_RD
`endif
`ifdef USE_EXT_ROM
  `ifndef YM_EXT_RD
    `define YM_EXT_RD
  `endif
`endif

module yunit_memsys
  import yunit_pkg::*;
#(
  parameter ROM_HEX = "smashtv_maindata.hex"
)(
  input  logic        clk,
  input  logic        rst,

  // CPU (TMS34010 core) request-valid memory interface.
  input  logic        mem_req,
  input  logic        mem_we,
  input  logic [31:0] mem_addr,          // bit address
  input  logic  [5:0] mem_size,          // field width 1..32
  input  logic [31:0] mem_wdata,
  output logic [31:0] mem_rdata,
  output logic        mem_ack,

  // Unpacked-gfx source (to external gfx ROM / SDRAM): 1 byte/pixel.
  output logic        src_req,
  output logic [23:0] src_addr,
  input  logic  [7:0] src_data,
  input  logic        src_ack,

  // Player inputs (Phase 4): packed {DSW, IN2, IN1, IN0}, active-low.
  input  logic [63:0] inputs,

  // P0016: DMA-done interrupt line -> TMS34010 LINT1. yunit_dma.blit_irq
  // already implements the MAME semantics (dma_callback ASSERTs on blit
  // completion; any DMA COMMAND write CLEARs — midyunit_v.cpp:370-374/433).
  // The game's blit-queue pump ISR (INT1 vector -> ffe00000) depends on it.
  output logic        int1,

  // Sound latch (Phase 5) -> williams_cvsd_board (see yunit_mem).
  output logic [7:0]  snd_select,
  output logic        snd_trig,
  output logic        snd_reset,

  // Autoerase sweep (SQUAD CHARLIE): frame-paced trigger into yunit_mem's
  // erase engine (MAME midyunit_v.cpp:534-560 semantics; see yunit_mem).
  // System-level intent: pulse from yunit_video's vblank_irq with
  // erase_row0 = DISP_ROW0 and erase_lines = V_ACT; Phase-6 form re-paces
  // this per scanline off the live raster. Left unconnected in legacy TBs.
  input  logic        erase_start,
  input  logic [8:0]  erase_row0,
  input  logic [9:0]  erase_lines,
  output logic        erase_busy,

  // Observability
  output logic        blit_busy
`ifdef YM_EXT_RD
  // CPU read-only external port (gfx/ROM in SDRAM) — exposed to the top controller.
  , output logic        cpu_gfx_rd
  , output logic [23:0] cpu_gfx_raddr
  , input  logic [7:0]  cpu_gfx_rdata
  , input  logic        cpu_gfx_rack
`endif
`ifdef USE_SDRAM_VRAM
  // VRAM SDRAM channel + video scanout read port — exposed to the top controller/video.
  , input  logic        scan_req
  , input  logic [17:0] scan_addr
  , output logic [15:0] scan_data
  , output logic        scan_ack
  , output logic [24:0] vsd_addr
  , output logic [15:0] vsd_din
  , output logic [1:0]  vsd_be
  , output logic        vsd_rd
  , output logic        vsd_wr
  , input  logic [15:0] vsd_dout
  , input  logic        vsd_ack
`endif
`ifdef USE_HW_RAM
  // W3: palette write-tap -> video scanout mirror (yunit_palram, in yunit_top).
  , output logic        palv_we_a
  , output logic [12:0] palv_aa
  , output logic [15:0] palv_awd
  , output logic        palv_we_b
  , output logic [12:0] palv_ba
  , output logic [15:0] palv_bwd
`endif
);

  // ---- DMA-region detect (0x01A00000 and its 0x080000 mirror) -----------
  wire is_dma_now = (mem_addr[31:20] == 12'h01A);

  // ---- yunit_mem (all non-DMA regions, incl. VRAM/PAL/RAM/ROM/CMOS/CTRL) --
  logic        mem_req_m;
  logic [31:0] mem_rdata_m;
  logic        mem_ack_m;

  // ---- yunit_dma blitter ------------------------------------------------
  logic        dma_reg_we;
  logic  [3:0] dma_reg_addr;
  logic [15:0] dma_reg_wdata;
  logic [15:0] dma_reg_rdata;
  logic        dma_fb_we;
  logic [FB_ADDR_W-1:0] dma_fb_addr;
  logic [15:0] dma_fb_wdata;
  logic [15:0] dma_palette;

  // blitter fb write completion: SDRAM path drives it from yunit_mem; BRAM path = 1-cycle.
`ifdef USE_SDRAM_VRAM
  logic mem_fb_ack;
  wire  dma_fb_ack = mem_fb_ack;
`else
  wire  dma_fb_ack = 1'b1;
`endif

  yunit_mem #(.ROM_HEX(ROM_HEX)) u_mem (
    .clk(clk), .rst(rst),
    .mem_req(mem_req_m), .mem_we(mem_we), .mem_addr(mem_addr),
    .mem_size(mem_size), .mem_wdata(mem_wdata),
    .mem_rdata(mem_rdata_m), .mem_ack(mem_ack_m),
    .fb_we(dma_fb_we), .fb_addr(dma_fb_addr), .fb_wdata(dma_fb_wdata),
    .dma_palette(dma_palette),
    .inputs(inputs),
    .snd_select(snd_select), .snd_trig(snd_trig), .snd_reset(snd_reset),
    .erase_start(erase_start), .erase_row0(erase_row0),
    .erase_lines(erase_lines), .erase_busy(erase_busy)
`ifdef YM_EXT_RD
    , .gfx_rd(cpu_gfx_rd), .gfx_raddr(cpu_gfx_raddr),
      .gfx_rdata(cpu_gfx_rdata), .gfx_rack(cpu_gfx_rack)
`endif
`ifdef USE_SDRAM_VRAM
    , .fb_ack(mem_fb_ack)
    , .scan_req(scan_req), .scan_addr(scan_addr), .scan_data(scan_data), .scan_ack(scan_ack)
    , .vsd_addr(vsd_addr), .vsd_din(vsd_din), .vsd_be(vsd_be), .vsd_rd(vsd_rd), .vsd_wr(vsd_wr)
    , .vsd_dout(vsd_dout), .vsd_ack(vsd_ack)
`endif
`ifdef USE_HW_RAM
    , .palv_we_a(palv_we_a), .palv_aa(palv_aa), .palv_awd(palv_awd)
    , .palv_we_b(palv_we_b), .palv_ba(palv_ba), .palv_bwd(palv_bwd)
`endif
  );

  yunit_dma u_dma (
    .clk(clk), .rst(rst),
    .reg_we(dma_reg_we), .reg_addr(dma_reg_addr),
    .reg_wdata(dma_reg_wdata), .reg_rdata(dma_reg_rdata),
    .src_req(src_req), .src_addr(src_addr), .src_data(src_data), .src_ack(src_ack),
    .fb_we(dma_fb_we), .fb_addr(dma_fb_addr), .fb_wdata(dma_fb_wdata),
    .fb_ack(dma_fb_ack),   // SDRAM: yunit_mem.fb_ack (blitter self-paces); BRAM: 1'b1
    .busy(blit_busy), .blit_irq(int1), .dma_palette(dma_palette)   // P0016: -> LINT1
  );

  // ---- DMA register access FSM ------------------------------------------
  // The DMA registers are 16-bit at word-aligned bit addresses (reg index =
  // addr[7:4]). The 34010 memory system splits a >16-bit field write into
  // consecutive word writes, so a 32-bit field write to reg N updates reg N
  // (low word) AND reg N+1 (high word) — MAME calls dma_w twice. The custom-
  // chip test relies on this: `MOVE A14,@1A80060h,1` (32-bit) sets WIDTH(6)
  // AND HEIGHT(7). A 16-bit-only FSM dropped HEIGHT -> blit height 0 -> no-op.
  // So: writes visit D_LO (reg idx, wdata[15:0]) then, if size>16, D_HI
  // (reg idx+1, wdata[31:16]); reads go straight to D_ACKR (combinational
  // reg_rdata). One dma_ack pulse per access, after all register writes land.
  typedef enum logic [1:0] { D_IDLE, D_LO, D_HI, D_ACKR } dstate_t;
  dstate_t dstate;
  logic [31:0] d_addr_q;
  logic        d_we_q;
  logic [31:0] d_wd_q;
  logic  [5:0] d_sz_q;
  logic        dma_ack;

  wire d_second = (dstate == D_HI);
  assign dma_reg_addr  = d_second ? (d_addr_q[7:4] + 4'd1) : d_addr_q[7:4];
  assign dma_reg_wdata = d_second ? d_wd_q[31:16]          : d_wd_q[15:0];
  assign dma_reg_we    = (dstate == D_LO) || (dstate == D_HI); // only entered on writes

  always_ff @(posedge clk) begin
    if (rst) begin
      dstate  <= D_IDLE;
      dma_ack <= 1'b0;
    end else begin
      unique case (dstate)
        D_IDLE: begin
          dma_ack <= 1'b0;
          if (mem_req && is_dma_now && !mem_ack) begin
            d_addr_q <= mem_addr;
            d_we_q   <= mem_we;
            d_wd_q   <= mem_wdata;
            d_sz_q   <= mem_size;
            dstate   <= mem_we ? D_LO : D_ACKR;
          end
        end
        D_LO:   dstate <= (d_sz_q > 6'd16) ? D_HI : D_ACKR; // reg idx written this edge
        D_HI:   dstate <= D_ACKR;                           // reg idx+1 written this edge
        D_ACKR: begin dma_ack <= 1'b1; dstate <= D_IDLE; end
        default: dstate <= D_IDLE;
      endcase
    end
  end

  // ---- output mux -------------------------------------------------------
  // Route the request: DMA region -> the DMA FSM (mem_req_m held low so
  // yunit_mem ignores it); everything else -> yunit_mem.
  assign mem_req_m = mem_req && !is_dma_now;
  assign mem_ack   = is_dma_now ? dma_ack : mem_ack_m;
  assign mem_rdata = is_dma_now ? {16'h0000, dma_reg_rdata} : mem_rdata_m;

endmodule

`default_nettype wire
