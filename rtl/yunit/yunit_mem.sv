// yunit_mem.sv — Williams Y-unit memory controller / bit-address decoder.
//
// Slave on the TMS34010 core's request-valid memory interface (birdybro
// TMS34010_sv): bit-addressed, `mem_size` = field width in bits (1..32).
// Implements the same bit-field access semantics as the core's reference
// sim_memory_model (the store the core's 122 instruction TBs pass against):
// a field of 1..32 bits at ANY bit address, straddling at most three 16-bit
// words, read-modify-write for writes. See docs/HARDWARE-REFERENCE.md §3.
//
// Address model (confirmed): word_idx = mem_addr[31:4], bit_off = mem_addr[3:0].
// MAME's midyunit map values ARE these bit-addresses directly (e.g. ROM region
// 0xFF800000-0xFFFFFFFF = 0x80000 words = the 1MB program region). No shift.
//
// Phase 1 scope: ROM (maindata) + main RAM are backed and field-exact. The
// other regions (VRAM/PAL/CMOS/DMA/INPUT/PROT/SOUND/CTRL/GFX) are DECODED but
// stubbed (reads return 0, writes dropped) — they are wired to real blocks in
// Phase 2-3. The I/O register space (0xC0000000) is serviced INSIDE the core,
// so it never reaches this module.
//
// Verified by sim/tb_yunit_mem.sv (Icarus): reset-vector read, first-instr
// read, and cross-16-bit-word field RMW (de-risks birdybro A0005).
//
// NOTE: this is a functional model (single-cycle 3-word window). The real HW
// memory controller (SDRAM, multi-cycle) is Phase 6; the field semantics here
// are the contract it must preserve.

`default_nettype none

// Phase-6 external-read machinery guard: shared FSM/ports for serving CPU
// read-only regions (GFX, program ROM) from an external memory (SDRAM). Active
// if EITHER region is externalized. SYNTHESIS implies both. USE_EXT_GFX /
// USE_EXT_ROM alone drive the focused equivalence TBs (tb_yunit_gfx/tb_yunit_rom).
`ifdef SYNTHESIS
  `ifndef USE_EXT_GFX
    `define USE_EXT_GFX
  `endif
  `ifndef USE_EXT_ROM
    `define USE_EXT_ROM
  `endif
  `ifndef USE_HW_RAM
    `define USE_HW_RAM
  `endif
  `ifndef USE_SDRAM_VRAM
    `define USE_SDRAM_VRAM
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
// VRAM has two synthesizable backends: USE_HW_VRAM (2-port BRAM — the sim-testable
// intermediate) and USE_SDRAM_VRAM (vram_sdram_top — the real DE10 path; SYNTHESIS picks
// this since 4Mbit VRAM won't fit BRAM). YM_VRAM_HW = either -> the functional VRAM
// accessors (read_word R_VRAM, the R_VRAM write case, blitter fb_we, autoerase) are
// guarded out and handled by the selected backend.
`ifdef USE_HW_VRAM
  `define YM_VRAM_HW
`endif
`ifdef USE_SDRAM_VRAM
  `ifndef YM_VRAM_HW
    `define YM_VRAM_HW
  `endif
`endif

module yunit_mem
  import yunit_pkg::*;
#(
  parameter int ROM_WORDS  = 32'h20000,  // 256 KB program (0x20000 x 16b)
  parameter int RAM_WORDS  = 32'h10000,  // main RAM = MAME m_mainram 0x01000000-0x010FFFFF
                                         // (0x100000 bit-addrs / 16 = 0x10000 words = 128KB, same
                                         // /16 convention as PAL below). Was 0x20000 (2x over) —
                                         // halving frees ~100 M10K so the CVSD sound ROMs fit in
                                         // BRAM. Decode is subtract+compare (NOT masked) so addrs
                                         // >= 0x10000 fall through to unmapped, matching MAME (no
                                         // mirror on m_mainram). Boot smoke re-verified after.
  parameter int VRAM_WORDS = 32'h40000,  // frame buffer PIXELS (512x512): each 34010 VRAM
                                         // word maps to 2 pixels (MAME local_videoram, offset*2)
  parameter int PAL_WORDS  = 32'h2000,   // palette RAM: region 0x01800000-0x0181FFFF = 0x2000 words
                                         // (8192 words; only low 4096 are live colors at 6bpp)
  parameter int CMOS_WORDS = 32'h8000,   // battery NVRAM
  parameter int GFX_PIXELS = 32'h180000, // unpacked gfx-ROM pixels (real data; rest fill)
  parameter     ROM_HEX    = "smashtv_maindata.hex",
  parameter     GFX_HEX    = "build/smashtv_gfx.hex" // unpacked 1 byte/pixel (make_gfx_hex.py)
)(
  input  logic        clk,
  input  logic        rst,

  input  logic        mem_req,
  input  logic        mem_we,
  input  logic [31:0] mem_addr,          // bit address
  input  logic  [5:0] mem_size,          // field width 1..32
  input  logic [31:0] mem_wdata,
  output logic [31:0] mem_rdata,
  output logic        mem_ack,

  // Blitter VRAM write port (yunit_dma fb_*): writes a full 16-bit
  // {palette,pixel} local_videoram word at a PIXEL index, bypassing the
  // videobank byte-lane (matches MAME dma_draw's direct local_videoram store).
  input  logic                  fb_we,
  input  logic [FB_ADDR_W-1:0]  fb_addr,
  input  logic [15:0]           fb_wdata,
  // Blitter DMA_PALETTE reg — the CPU vram_w byte-lane folds this into the
  // plane it is NOT writing (MAME midyunit_v.cpp:140-142). 0 until wired.
  input  logic [15:0]           dma_palette,
  // Player inputs (Phase 4). Packed {DSW, IN2, IN1, IN0}, all ACTIVE-LOW
  // (idle = all-ones). Read at 0x01C00000 region (MAME input_r): offset 0=IN0
  // (twin-stick), 1=IN1 (coins/start/service/tilt), 2=IN2, 3=DSW (coinage/dips).
  input  logic [63:0]           inputs,

  // Sound latch (Phase 5) -> williams_cvsd_board. Decoded per MAME
  // cvsd_sound_w (midyunit_m.cpp:650): a write of D to 0x01E00000 does
  // reset_write(~D[8]) and write((D&0xff)|((D&0x200)>>1)) — i.e. the board
  // sees select = D[7:0], CB1 trig = D[9], and reset asserted while D[8]=0.
  output logic [7:0]            snd_select,
  output logic                  snd_trig,
  output logic                  snd_reset,

  // ---- Autoerase sweep trigger (MAME midyunit_v.cpp:534-560) -------------
  // MAME erases each displayed VRAM row right after it is scanned (one row
  // behind the beam: scanline_update:554 calls autoerase_line(rowaddr-1),
  // and :558-559 erases the FINAL row via a timer one line later), filling
  // it with the 512-word pattern the game keeps in VRAM row 510 (even target
  // rows) / 511 (odd target rows) — autoerase_line:539. Gated on the CONTROL
  // register /autoerase bit (control_w:235, active LOW, captured below).
  //
  // This port is the frame-paced form: pulse erase_start ONCE at the end of
  // visible scanout with the displayed window (erase_row0 = the rowaddr of
  // the first visible scanline, erase_lines = visible line count) and the
  // engine sweeps rows (erase_row0-1) .. (erase_row0+erase_lines-1) mod 512,
  // which is exactly MAME's per-frame erased set. The Phase-6 (HW-honest)
  // form is scanline-paced: yunit_video pulses this once per scanline with
  // erase_row0 = that line's rowaddr, erase_lines = 0 special-cased — or
  // simply re-uses this engine with a 1-row window per hsync. Left unconnected
  // (legacy TBs) erase_start floats z and the engine never starts.
  input  logic                  erase_start,   // 1-clk pulse: run one sweep
  input  logic [8:0]            erase_row0,    // first DISPLAYED VRAM row
  input  logic [9:0]            erase_lines,   // visible scanline count
  output logic                  erase_busy
`ifdef YM_EXT_RD
  // Phase 6 W1: external read-only-region port (SDRAM-backed). The unpacked gfx
  // array (1.5 MB) and program ROM (256 KB) OOM Quartus as on-chip RAM, so the CPU
  // read-only windows — R_GFX (boot ROM-checksum; blitter reads gfx via src_*) and
  // R_ROM (instruction fetch + ROM data) — are fetched byte-by-byte through the
  // arbiter/SDRAM. ONE port: CPU R_GFX and R_ROM serialize through this FSM.
  // SDRAM byte layout: gfx @ 0, program ROM @ SDRAM_ROMB (= gfx byte size).
  , output logic        gfx_rd      // read request (held until gfx_rack)
  , output logic [23:0] gfx_raddr   // external byte address (gfx or ROM region)
  , input  logic [7:0]  gfx_rdata   // read byte
  , input  logic        gfx_rack    // data-valid strobe
`endif
`ifdef USE_SDRAM_VRAM
  // Phase 6 W1f: VRAM lives in SDRAM (4Mbit won't fit BRAM). vram_sdram_top multiplexes
  // CPU field RMW + blitter fb writes + autoerase + scanout onto ONE 16-bit SDRAM channel.
  , output logic        fb_ack      // blitter write accepted (self-paces the blitter)
  , input  logic        scan_req    // video scanout read request (held until scan_ack)
  , input  logic [17:0] scan_addr   // VRAM entry to read
  , output logic [15:0] scan_data   // scanout read data (valid at scan_ack)
  , output logic        scan_ack
  , output logic [24:0] vsd_addr    // VRAM SDRAM word address (channel out)
  , output logic [15:0] vsd_din
  , output logic [1:0]  vsd_be
  , output logic        vsd_rd
  , output logic        vsd_wr
  , input  logic [15:0] vsd_dout
  , input  logic        vsd_ack
`endif
`ifdef USE_HW_RAM
  // Phase 6 W3: palette write-tap for the video scanout mirror (yunit_palram). The
  // palette BRAM's two ports are consumed by the CPU field engine, so the video keeps
  // a mirror updated from these strobes. Port A = word0, port B = word1 (a >=17-bit
  // palette field writes both the same cycle; a 33-bit-spanning field writes word2 on
  // port A a cycle later, i.e. another palv_we_a pulse).
  , output logic        palv_we_a
  , output logic [12:0] palv_aa
  , output logic [15:0] palv_awd
  , output logic        palv_we_b
  , output logic [12:0] palv_ba
  , output logic [15:0] palv_bwd
`endif
);

  // ---- Region encoding --------------------------------------------------
  localparam logic [3:0] R_NONE=4'd0, R_VRAM=4'd1, R_RAM=4'd2, R_CMOS=4'd3,
                         R_PAL=4'd4, R_DMA=4'd5, R_INPUT=4'd6, R_PROT=4'd7,
                         R_SOUND=4'd8, R_CTRL=4'd9, R_GFX=4'd10, R_ROM=4'd11;

  // Region-base word indices (base >> 4).
  localparam logic [27:0] WB_RAM  = 28'(YMAP_RAM_BASE      >> 4); // 0x0100000
  localparam logic [27:0] WB_ROM  = 28'(YMAP_MAINDATA_BASE >> 4); // 0x0FF80000
  localparam logic [27:0] WB_VRAM = 28'(YMAP_VRAM_BASE     >> 4); // 0x0000000
  localparam logic [27:0] WB_PAL  = 28'(YMAP_PAL_BASE      >> 4); // 0x0180000
  localparam logic [27:0] WB_CMOS = 28'(YMAP_CMOS_BASE     >> 4); // 0x0140000
  localparam logic [27:0] WB_INPUT= 28'(YMAP_INPUT_BASE    >> 4); // 0x01C0000
  localparam logic [27:0] WB_GFX  = 28'(YMAP_GFX_BASE      >> 4); // 0x0200000
  localparam logic [27:0] ROM_PROG_OFF = 28'h60000;          // program sits at region word 0x60000

  // ---- Backing stores ---------------------------------------------------
`ifndef USE_EXT_ROM
  logic [15:0] rom  [0:ROM_WORDS-1];     // program ROM (externalized to SDRAM under USE_EXT_ROM)
`endif
  // ramstyle no_rw_check: infer M10K without read-during-write bypass (the field
  // engine never reads+writes the same entry in one cycle). Required for Quartus
  // 17.0 to infer these as block RAM instead of register-exploding.
  (* ramstyle = "no_rw_check" *) logic [15:0] ram  [0:RAM_WORDS-1];
`ifndef USE_SDRAM_VRAM
  (* ramstyle = "no_rw_check" *) logic [15:0] vram [0:VRAM_WORDS-1]; // 512x512 {palette_hi, pixel_lo}
`endif
  (* ramstyle = "no_rw_check" *) logic [15:0] pal  [0:PAL_WORDS-1];  // palette RAM (xRGB1555)
`ifndef USE_EXT_GFX
  logic  [7:0] gfx  [0:GFX_PIXELS-1];    // unpacked gfx ROM (1 byte/pixel, 6bpp); CPU window @0x02000000
`endif

  // Y-unit VRAM planar access state (MAME midyunit_v.cpp control_w / vram_r/w).
  logic        videobank = 1'b0;         // CONTROL bit 5: 1 = pixel plane, 0 = palette-base plane
  logic  [1:0] cmos_page = 2'd0;         // CONTROL bits 7:6: CMOS page (× 0x1000 words)
  logic        autoerase = 1'b0;         // CONTROL ~bit 4: per-frame VRAM auto-erase enable

  // Autoerase engine state (see the erase engine block in the clocked process).
  logic        er_run  = 1'b0;           // sweep in progress
  logic  [8:0] er_row;                   // current target row (mod 512)
  logic  [8:0] er_x;                     // column within the row
  logic  [9:0] er_left;                  // rows remaining (incl. current)
`ifndef USE_SDRAM_VRAM
  assign erase_busy = er_run;            // (SDRAM path: vram_sdram_top drives erase_busy)
`endif
  (* ramstyle = "no_rw_check" *) logic [15:0] nvram [0:CMOS_WORDS-1]; // battery NVRAM
`ifndef SYNTHESIS
  // sim-only preload; in synthesis the arrays init to 0 (BRAM) and ROMs load via
  // the framework ioctl download (Phase 6 W5). Quartus can't run the big for-loops
  // (>5000 iters) or $readmemh with sim paths, so guard the whole block out.
  initial begin
    // sim-only preload; ROM_HEX is generated from the user's ROM (see sim/).
    // Zero the writable stores so words the TB hasn't written read back as 0, not
    // X — matching sim_memory_model. (Uninitialized X in an unread window word
    // otherwise X-propagates through the shift/mask under Icarus.)
    for (int i = 0; i < RAM_WORDS;  i++) ram[i]  = 16'h0000;
`ifndef USE_SDRAM_VRAM
    for (int i = 0; i < VRAM_WORDS; i++) vram[i] = 16'h0000;
`endif
    for (int i = 0; i < PAL_WORDS;  i++) pal[i]  = 16'h0000;
    for (int i = 0; i < CMOS_WORDS; i++) nvram[i] = 16'h0000;
`ifndef USE_EXT_ROM
    $readmemh(ROM_HEX, rom);
`endif
`ifndef USE_EXT_GFX
    for (int i = 0; i < GFX_PIXELS; i++) gfx[i]  = 8'h00;
    $readmemh(GFX_HEX, gfx);   // unpacked gfx ROM; harmless no-op if the file is absent
`endif
  end
`endif

  // ---- Request latch / FSM ---------------------------------------------
  // FSM states (plain localparams so guarded extra states compose cleanly):
  //  M_IDLE/M_ACK    : always. M_GFX : external gfx/rom fetch (YM_EXT_RD).
  //  M_HR1/M_HR2/M_HW2 : clocked-BRAM window read / 3rd-word / 3rd-word-write
  //                      for the CPU field engine (USE_HW_RAM / USE_HW_VRAM).
  localparam logic [3:0] M_IDLE=4'd0, M_ACK=4'd1, M_GFX=4'd2,
                         M_HR1=4'd3, M_HR2=4'd4, M_HFIN=4'd5, M_HW2=4'd6,
                         // VRAM clocked BRAM engine (USE_HW_VRAM)
                         M_VRD=4'd7, M_VWR0=4'd8, M_VWR1=4'd9, M_VWW0=4'd10, M_VWW1=4'd11,
                         // VRAM SDRAM engine (USE_SDRAM_VRAM): pulse req -> wait done
                         M_VSD=4'd12,
                         // field-engine merge/extract pipeline stage (timing closure @96 MHz)
                         M_HFIN2=4'd13,
                         // non-BRAM (INPUT/PROT/CTRL) read extract pipeline stage
                         M_RDLY=4'd14;
  logic [3:0] state;
`ifdef YM_EXT_RD
  logic [23:0] gfx_base;      // byte addr of the 3-word (6-byte) window
  logic [2:0]  gfx_cnt;       // 0..5 fetch counter
  logic [7:0]  gfx_buf [0:4]; // bytes 0..4 (byte 5 = gfx_rdata on the last cycle)
  // SDRAM byte layout: gfx region @ 0, program ROM region @ SDRAM_ROMB.
  localparam logic [23:0] SDRAM_ROMB = 24'(GFX_PIXELS);   // = gfx byte size (0x180000)
`endif

  logic [31:0] a_q;
  logic        we_q;
  logic [31:0] wd_q;
  logic  [5:0] sz_q;

  // region + geometry from the latched address
  wire [27:0] widx  = a_q[31:4];
  wire  [3:0] boff  = a_q[3:0];
  wire  [5:0] sz    = sz_q;

  logic [3:0] region;
  always_comb begin
    // decode on high bits of the bit-address (see HARDWARE-REFERENCE §3)
    unique casez (a_q[31:20])
      12'h000, 12'h001:            region = R_VRAM;      // 0x00000000-0x001FFFFF
      12'h010:                     region = R_RAM;       // 0x01000000-0x010FFFFF
      12'h014:                     region = R_CMOS;      // 0x01400000
      12'h018:                     region = R_PAL;       // 0x01800000
      12'h01a:                     region = R_DMA;       // 0x01A00000
      12'h01c:                     region = (a_q[7:4] >= 4'd6) ? R_PROT : R_INPUT; // input 0..5, prot 0x60-0x7f
      12'h01e:                     region = R_SOUND;     // 0x01E00000
      12'h01f:                     region = R_CTRL;      // 0x01F00000
      12'h020,12'h021,12'h022,12'h023,12'h024,12'h025,12'h026,12'h027,
      12'h028,12'h029,12'h02a,12'h02b,12'h02c,12'h02d,12'h02e,12'h02f,
      12'h030,12'h031,12'h032,12'h033,12'h034,12'h035,12'h036,12'h037,
      12'h038,12'h039,12'h03a,12'h03b,12'h03c,12'h03d,12'h03e,12'h03f,
      12'h040,12'h041,12'h042,12'h043,12'h044,12'h045,12'h046,12'h047,
      12'h048,12'h049,12'h04a,12'h04b,12'h04c,12'h04d,12'h04e,12'h04f,
      12'h050,12'h051,12'h052,12'h053,12'h054,12'h055,12'h056,12'h057,
      12'h058,12'h059,12'h05a,12'h05b,12'h05c,12'h05d,12'h05e,12'h05f:
                                   region = R_GFX;       // 0x02000000-0x05FFFFFF
      12'hff8,12'hff9,12'hffa,12'hffb,12'hffc,12'hffd,12'hffe,12'hfff:
                                   region = R_ROM;       // 0xFF800000-0xFFFFFFFF
      default:                     region = R_NONE;
    endcase
  end

  // VRAM is a HW backend region (USE_HW_VRAM BRAM or USE_SDRAM_VRAM): the M_ACK FSM diverts
  // R_VRAM accesses to the selected engine. (Declared AFTER `region` — Questa requires
  // declaration-before-use for the continuous-assign reference.)
`ifdef YM_VRAM_HW
  wire is_hwvram = (region == R_VRAM);
`else
  wire is_hwvram = 1'b0;
`endif

  // Read one word from the selected region at global word index gw (backed
  // regions only; others / OOB return 0). Function form (continuous-assign
  // call) — inlining these array reads into an always_comb makes iverilog
  // build a huge structure over the 0x20000-word ROM and hang. This is the
  // functional model; the HW controller replaces it in Phase 6.
  localparam logic [27:0] ROMW  = ROM_WORDS[27:0];
  localparam logic [27:0] RAMW  = RAM_WORDS[27:0];
  localparam logic [27:0] VRAMW = VRAM_WORDS[27:0];
  localparam logic [27:0] PALW  = PAL_WORDS[27:0];
  localparam logic [27:0] CMOSW = CMOS_WORDS[27:0];
  localparam logic [27:0] GFXPIXW = GFX_PIXELS[27:0];

  function automatic logic [15:0] read_word(input logic [3:0] rgn, input logic [27:0] gw);
    logic [27:0] rel;
    begin
      read_word = 16'h0000;
      if (rgn == R_ROM) begin
`ifndef USE_EXT_ROM
        rel = gw - WB_ROM;                           // region-relative word
        if (rel >= ROM_PROG_OFF && (rel - ROM_PROG_OFF) < ROMW)
          read_word = rom[rel - ROM_PROG_OFF];
`endif
        // USE_EXT_ROM: in-range R_ROM reads are served by the M_GFX external fetch;
        // out-of-range reads fall here and return 0 (matches the internal array).
      end else if (rgn == R_RAM) begin
`ifndef USE_HW_RAM
        rel = gw - WB_RAM;   if (rel < RAMW)  read_word = ram[rel];
`endif
      end else if (rgn == R_VRAM) begin
`ifndef YM_VRAM_HW
        // MAME vram_r: each 34010 word offset -> 2 pixels; byte-lane per videobank.
        rel = gw - WB_VRAM;                        // 34010 VRAM word offset
        if (((rel << 1) + 28'd1) < VRAMW) begin
          if (videobank)                           // pixel plane: the two pixel low-bytes
            read_word = {vram[(rel<<1)+1][7:0], vram[rel<<1][7:0]};
          else                                     // palette-base plane: the two high-bytes
            read_word = {vram[(rel<<1)+1][15:8], vram[rel<<1][15:8]};
        end
`endif
      end else if (rgn == R_PAL) begin
`ifndef USE_HW_RAM
        rel = gw - WB_PAL;   if (rel < PALW)  read_word = pal[rel];
`endif
      end else if (rgn == R_CMOS) begin
`ifndef USE_HW_RAM
        // CMOS/NVRAM, paged: index = cmos_page*0x1000 + (offset within page).
        rel = gw - WB_CMOS;  if (rel < CMOSW) read_word = nvram[{cmos_page, rel[11:0]}];
`endif
      end else if (rgn == R_INPUT) begin
        // MAME input_r: offset 0=IN0, 1=IN1, 2=IN2, 3=DSW (all active-low).
        rel = gw - WB_INPUT;
        case (rel[1:0])
          2'd0: read_word = inputs[15:0];    // IN0 (twin-stick)
          2'd1: read_word = inputs[31:16];   // IN1 (coins/start/service/tilt)
          2'd2: read_word = inputs[47:32];   // IN2
          2'd3: read_word = inputs[63:48];   // DSW (coinage/dips)
          default: read_word = 16'hFFFF;
        endcase
        if (rel > 28'd3) read_word = 16'hFFFF; // UNK0/UNK1: idle (active-low)
      // R_PROT: protection is inert for Smash T.V. (init_smashtv m_prot_data=nullptr),
      // so protection_r returns 0 — the default read_word value. No case needed.
      end else if (rgn == R_GFX) begin
        // MAME gfxrom_r (midyunit_v.cpp:116): offset*=2 (word->byte-pair);
        // return gfx[2*rel] | gfx[2*rel+1]<<8. Unpacked 1 byte/pixel.
        rel = gw - WB_GFX;
`ifndef USE_EXT_GFX
        if (((rel << 1) + 28'd1) < GFXPIXW)
          read_word = {gfx[(rel << 1) + 28'd1], gfx[rel << 1]};
`endif
        // USE_EXT_GFX: R_GFX reads are served by the M_GFX external fetch (below),
        // not read_word — this returns 0 and is never used for R_GFX.
      end
    end
  endfunction

  // Field masks (no array dependency -> safe as continuous assigns).
  wire [47:0] rmask = (48'd1 << sz) - 48'd1;         // sz low bits
  wire [47:0] smask = rmask << boff;                 // field in place
  wire [5:0]  lastb = boff + sz - 6'd1;              // top bit (<=46)
`ifdef YM_EXT_RD
  assign gfx_raddr = gfx_base + 24'(gfx_cnt);        // current fetch byte address
  // Select which (if any) read-only region routes through the external fetch, and
  // its SDRAM byte base. R_GFX: gfx region @0. R_ROM: program ROM @SDRAM_ROMB, and
  // ONLY within the populated program range (out-of-range ROM reads fall through
  // to the normal path -> read_word()=0, byte-identical to the internal array).
  logic        ext_fetch;
  logic [23:0] ext_base;
  logic [27:0] rom_rel;
  always_comb begin
    ext_fetch = 1'b0;
    ext_base  = 24'd0;
    rom_rel   = widx - WB_ROM;
  `ifdef USE_EXT_GFX
    if (region == R_GFX && !we_q) begin
      ext_fetch = 1'b1;
      ext_base  = 24'((widx - WB_GFX) << 1);
    end
  `endif
  `ifdef USE_EXT_ROM
    if (region == R_ROM && !we_q &&
        rom_rel >= ROM_PROG_OFF && (rom_rel - ROM_PROG_OFF) < ROMW) begin
      ext_fetch = 1'b1;
      ext_base  = SDRAM_ROMB + 24'((rom_rel - ROM_PROG_OFF) << 1);
    end
  `endif
  end
`endif

`ifdef USE_HW_RAM
  // ---- Phase 6 W1c: clocked BRAM field engine for RAM / PAL / CMOS -----------
  // The functional model reads a combinational 3-word window (3+ async reads per
  // access) — un-inferrable as BRAM (register-explodes: yunit_mem alone >18 GB in
  // quartus_map). Here RAM/PAL/CMOS become true-dual-port synchronous BRAMs, and
  // the CPU field access runs a multi-cycle window RMW over the two ports. The
  // field MATH is unchanged (same win/merge as read_word/merged_s) — only how the
  // window is FILLED changes (combinational -> clocked). Reads: 3 wait cycles;
  // writes: 3-4. The req/ack handshake absorbs the latency. VRAM is separate
  // (USE_HW_VRAM). Access distribution measured in tb_yunit_frame (MEASURE_ACCESS).
  logic is_hwram;                     // region uses this engine (RAM/PAL/CMOS)
  logic [1:0]  hsel;                  // 0=ram 1=pal 2=cmos (routes ports/q)
  logic [17:0] hidx [0:2];            // per-window-word array index (region-relative/paged)
  logic        hval [0:2];            // per-word in-range validity
  logic [27:0] hr;                    // per-word region-relative index (comb temp)
  always_comb begin
    is_hwram = 1'b0; hsel = 2'd0; hr = 28'd0;
    for (int j=0;j<3;j++) begin hidx[j]=18'd0; hval[j]=1'b0; end
    if (region==R_RAM) begin
      is_hwram=1'b1; hsel=2'd0;
      for (int j=0;j<3;j++) begin
        hr = (widx + j[27:0]) - WB_RAM;
        hidx[j]=hr[17:0]; hval[j]=(hr < RAMW);
      end
    end else if (region==R_PAL) begin
      is_hwram=1'b1; hsel=2'd1;
      for (int j=0;j<3;j++) begin
        hr = (widx + j[27:0]) - WB_PAL;
        hidx[j]=hr[17:0]; hval[j]=(hr < PALW);
      end
    end else if (region==R_CMOS) begin
      is_hwram=1'b1; hsel=2'd2;
      for (int j=0;j<3;j++) begin
        hr = (widx + j[27:0]) - WB_CMOS;
        hidx[j]={4'd0, cmos_page, hr[11:0]};     // paged index, zero-extended to 18b
        hval[j]=(hr < CMOSW);
      end
    end
  end

  // captured window words + combinational window/merge (rd* are registered).
  logic [15:0] rd0, rd1, rd2;
  wire  [47:0] hwin    = {hval[2]?rd2:16'h0, hval[1]?rd1:16'h0, hval[0]?rd0:16'h0};
  wire  [47:0] hmerged = (hwin & ~smask) | (({16'h0, wd_q} << boff) & smask);

  // ---- merge/extract PIPELINE (timing closure @96 MHz) ------------------------
  // a_q -> region decode + hidx adder + hval compare + the boff/sz shifts (smask,
  // wd_q<<boff) is ~12 ns combinational. The shifts are a_q/wd_q-derived and settle
  // by M_ACK (3 cyc before use), but STA still sees a_q -> merge -> BRAM/mem_rdata/
  // palv as ONE cycle. Register the settled a_q-derived masks + the read window, then
  // do the merge/extract from registered values in a new M_HFIN2 stage. Same VALUES,
  // one cycle later (the CPU is 24 MHz + latency-tolerant via yunit_mem_cdc).
  logic [47:0] smask_q, rmask_q, wsh_q, hwin_q;   // wsh_q = {16'h0,wd_q} << boff
  logic [3:0]  boff_q;
  always @(posedge clk) begin
    smask_q <= smask; rmask_q <= rmask; boff_q <= boff;
    wsh_q   <= ({16'h0, wd_q} << boff);
    hwin_q  <= hwin;                              // valid from M_HFIN (rd* captured by M_HR2)
  end
  wire  [47:0] hmerged2 = (hwin_q & ~smask_q) | (wsh_q & smask_q);

  // shared engine ports (routed to the active array by hsel below).
  logic [17:0] eng_aa, eng_ba;  logic eng_awe, eng_bwe;  logic [15:0] eng_awd, eng_bwd;
  logic [15:0] eng_aq, eng_bq;
  // combinational engine port control by state (1-cycle BRAM read latency).
  always_comb begin
    eng_aa=hidx[0]; eng_ba=hidx[1]; eng_awe=1'b0; eng_bwe=1'b0;
    eng_awd=hmerged2[15:0]; eng_bwd=hmerged2[31:16];   // pipelined merge
    case (state)
      M_HR1: eng_aa=hidx[2];                          // pre-issue w2 read
      M_HFIN2: if (we_q) begin                        // write-back w0,w1 (pipelined stage)
               eng_aa=hidx[0]; eng_awe=hval[0];
               eng_ba=hidx[1]; eng_bwe=(lastb>=6'd16)&hval[1];
             end
      M_HW2: begin eng_aa=hidx[2]; eng_awe=(lastb>=6'd32)&hval[2]; eng_awd=hmerged2[47:32]; end
      default: ;                                      // M_ACK/M_HR2: read w0,w1 (defaults)
    endcase
  end

  // true-dual-port BRAMs (Quartus infers M10K). Plain always @posedge so the sim
  // `initial` preload can also drive the arrays (same reason as the functional path).
  logic [16:0] ram_aa,ram_ba; logic ram_awe,ram_bwe; logic [15:0] ram_awd,ram_bwd,ram_aq,ram_bq;
  logic [12:0] pal_aa,pal_ba; logic pal_awe,pal_bwe; logic [15:0] pal_awd,pal_bwd,pal_aq,pal_bq;
  logic [14:0] nv_aa, nv_ba;  logic nv_awe, nv_bwe;  logic [15:0] nv_awd, nv_bwd, nv_aq, nv_bq;
  always_comb begin
    // route shared engine ports to the selected array; deselected arrays idle.
    ram_aa=eng_aa[16:0]; ram_ba=eng_ba[16:0]; ram_awd=eng_awd; ram_bwd=eng_bwd;
    pal_aa=eng_aa[12:0]; pal_ba=eng_ba[12:0]; pal_awd=eng_awd; pal_bwd=eng_bwd;
    nv_aa =eng_aa[14:0]; nv_ba =eng_ba[14:0]; nv_awd =eng_awd; nv_bwd =eng_bwd;
    ram_awe=(hsel==2'd0)&eng_awe; ram_bwe=(hsel==2'd0)&eng_bwe;
    pal_awe=(hsel==2'd1)&eng_awe; pal_bwe=(hsel==2'd1)&eng_bwe;
    nv_awe =(hsel==2'd2)&eng_awe; nv_bwe =(hsel==2'd2)&eng_bwe;
    eng_aq = (hsel==2'd0)?ram_aq : (hsel==2'd1)?pal_aq : nv_aq;
    eng_bq = (hsel==2'd0)?ram_bq : (hsel==2'd1)?pal_bq : nv_bq;
  end
  // ONE always block per port (canonical Quartus true-dual-port template — a
  // single block driving both ports does NOT infer M10K in Quartus 17.0).
  always @(posedge clk) begin if (ram_awe) ram[ram_aa]  <= ram_awd;  ram_aq <= ram[ram_aa];  end
  always @(posedge clk) begin if (ram_bwe) ram[ram_ba]  <= ram_bwd;  ram_bq <= ram[ram_ba];  end
  always @(posedge clk) begin if (pal_awe) pal[pal_aa]  <= pal_awd;  pal_aq <= pal[pal_aa];  end
  always @(posedge clk) begin if (pal_bwe) pal[pal_ba]  <= pal_bwd;  pal_bq <= pal[pal_ba];  end
  always @(posedge clk) begin if (nv_awe)  nvram[nv_aa] <= nv_awd;   nv_aq  <= nvram[nv_aa]; end
  always @(posedge clk) begin if (nv_bwe)  nvram[nv_ba] <= nv_bwd;   nv_bq  <= nvram[nv_ba]; end

  // W3: tap palette writes for the video scanout mirror (pal_awe/pal_bwe already
  // include the hsel==PAL select, so they pulse only on real palette writes).
  // REGISTERED (timing closure): the address-decode -> tap -> yunit_palram FIFO
  // combinational chain missed 96 MHz; a 1-cycle pipeline breaks it. The mirror
  // lags pal[] by one clk — invisible (palette writes are sparse; the video reads
  // the mirror much later).
  always @(posedge clk) begin
    palv_we_a <= pal_awe;  palv_aa <= pal_aa;  palv_awd <= pal_awd;
    palv_we_b <= pal_bwe;  palv_ba <= pal_ba;  palv_bwd <= pal_bwd;
  end
`else
  wire is_hwram = 1'b0;   // engine disabled: all regions use the functional path
`endif

`ifdef USE_HW_VRAM
  // ---- Phase 6 W1c: clocked 2-port BRAM VRAM engine + accessor arbiter --------
  // VRAM (512x512, 16b/pixel {palette_hi, pixel_lo}) has 4 accessors: CPU field
  // read/write (byte-lane, videobank plane select), blitter fb_we write, and the
  // autoerase row-copy. They map onto ONE true-dual-port BRAM via a priority
  // arbiter: CPU field access > fb_we > autoerase (the accessors are time-disjoint
  // in practice — the CPU polls, not draws, during blits; autoerase is post-
  // scanout; verified by the byte-identical frame gate). Reads never straddle
  // (measured) -> 1 word = 2 entries. Video scanout (W3) will add a read port.
  // (is_hwvram is defined once above, shared by both HW backends.)
  logic [17:0] va_addr, vb_addr;  logic va_we, vb_we;  logic [15:0] va_wd, vb_wd, va_q, vb_q;

  // CPU VRAM entry geometry (WB_VRAM=0). e0/e1 = word widx; e2/e3 = word widx+1.
  wire [17:0] ve0 = (widx << 1);              wire [17:0] ve1 = (widx << 1) + 18'd1;
  wire [17:0] ve2 = ((widx+28'd1) << 1);      wire [17:0] ve3 = ((widx+28'd1) << 1) + 18'd1;
  wire [17:0] vea = (widx << 1) + {17'd0, boff[3]};   // sz<=8 single-pixel entry
  wire v01 = (((widx<<1)+28'd1) < VRAMW);
  wire v23 = ((((widx+28'd1)<<1)+28'd1) < VRAMW);
  wire vea_v = ((widx<<1)+{27'd0,boff[3]}) < VRAMW;
  // captured old entry values (for the non-videobank low-byte-preserve RMW)
  logic [15:0] o0, o1, o2, o3;
  wire [7:0] oea = boff[3] ? o1[7:0] : o0[7:0];
  // merged new entry values (exact copies of the functional vram_w byte-lane math)
  wire [15:0] vnew0  = videobank ? {dma_palette[7:0],  wd_q[7:0]}   : {wd_q[7:0],   o0[7:0]};
  wire [15:0] vnew1  = videobank ? {dma_palette[15:8], wd_q[15:8]}  : {wd_q[15:8],  o1[7:0]};
  wire [15:0] vnew2  = videobank ? {dma_palette[7:0],  wd_q[23:16]} : {wd_q[23:16], o2[7:0]};
  wire [15:0] vnew3  = videobank ? {dma_palette[15:8], wd_q[31:24]} : {wd_q[31:24], o3[7:0]};
  wire [15:0] vnewea = videobank ? {(boff[3]?dma_palette[15:8]:dma_palette[7:0]), wd_q[7:0]}
                                 : {wd_q[7:0], oea};
  // CPU field read: form the 16-bit word from the two entries' selected byte lane.
  wire [15:0] vword = videobank ? {vb_q[7:0], va_q[7:0]} : {vb_q[15:8], va_q[15:8]};

  // CPU port requests (combinational by state); cpu owns the ports when active.
  wire cpu_vram_active = ((state==M_ACK) & is_hwvram) |
                         (state==M_VRD) | (state==M_VWR0) | (state==M_VWR1) |
                         (state==M_VWW0) | (state==M_VWW1);
  logic [17:0] cv_aa, cv_ba;  logic cv_awe, cv_bwe;  logic [15:0] cv_awd, cv_bwd;
  always_comb begin
    cv_aa=ve0; cv_ba=ve1; cv_awe=1'b0; cv_bwe=1'b0; cv_awd=vnew0; cv_bwd=vnew1;
    case (state)
      M_VWR0: if (sz_q > 6'd16) begin cv_aa=ve2; cv_ba=ve3; end    // issue e2/e3 read
      M_VWW0: if (sz_q <= 6'd8) begin cv_aa=vea; cv_awe=vea_v; cv_awd=vnewea; end
              else begin cv_awe=v01; cv_awd=vnew0; cv_bwe=v01; cv_bwd=vnew1; end
      M_VWW1: begin cv_aa=ve2; cv_ba=ve3; cv_awe=v23; cv_awd=vnew2; cv_bwe=v23; cv_bwd=vnew3; end
      default: ;                                                   // M_ACK/M_VRD/M_VWR1: read e0/e1
    endcase
  end

  // autoerase 3-cycle engine (ER0 issue-read -> ER0b capture src -> ER2 write).
  // Advances only on grant (paused while CPU/fb_we own the ports); the ER0b
  // capture is unconditional (va_q one cycle after ER0's read == src, whoever
  // addresses the port that cycle). src row = 510|parity; rows 510/511 not erased.
  logic [1:0]  er_ph;           // 0=ER0(read) 1=ER0b(capture) 2=ER2(write)
  logic [15:0] er_srcval;
  wire ae_grant = er_run & ~cpu_vram_active & ~fb_we;
  wire [17:0] ae_src = {8'hFF, er_row[0], er_x};
  wire [17:0] ae_dst = {er_row, er_x};
  wire ae_dowr = (er_row != 9'd510) && (er_row != 9'd511);

  // ---- 2-port arbiter: CPU field > fb_we > autoerase --------------------------
  always_comb begin
    va_addr=18'd0; vb_addr=18'd0; va_we=1'b0; vb_we=1'b0; va_wd=16'd0; vb_wd=16'd0;
    if (cpu_vram_active) begin
      va_addr=cv_aa; vb_addr=cv_ba; va_we=cv_awe; vb_we=cv_bwe; va_wd=cv_awd; vb_wd=cv_bwd;
    end else if (fb_we) begin
      va_addr=fb_addr; va_we=1'b1; va_wd=fb_wdata;               // blitter single-entry write
    end else if (ae_grant && er_ph==2'd0) begin
      va_addr=ae_src;                                            // autoerase: read src
    end else if (ae_grant && er_ph==2'd2) begin
      va_addr=ae_dst; va_we=ae_dowr; va_wd=er_srcval;            // autoerase: write dst
    end
  end

  // true-dual-port VRAM BRAM (Quartus infers M10K). Plain always for sim preload.
  // one block per port (see RAM note above)
  always @(posedge clk) begin if (va_we) vram[va_addr] <= va_wd;  va_q <= vram[va_addr];  end
  always @(posedge clk) begin if (vb_we) vram[vb_addr] <= vb_wd;  vb_q <= vram[vb_addr];  end
`endif  // USE_HW_VRAM (2-port BRAM engine; is_hwvram defined once above for both backends)

`ifdef USE_SDRAM_VRAM
  // ---- Phase 6 W1f: VRAM in SDRAM (vram_sdram_top) ----------------------------
  // All four VRAM accessors (CPU field RMW + blitter fb writes + autoerase + scanout)
  // multiplexed onto one 16-bit SDRAM channel. The CPU field access is driven from the
  // M_ACK FSM: pulse vsd_req, M_VSD waits for vsd_done. VRAM_BASE = VRAM's word offset in
  // SDRAM (0 here — a dedicated sim model; the unified controller sets the real base).
  logic        vsd_req; logic vsd_done; logic [31:0] vsd_rdata;
  vram_sdram_top #(.VRAMW(VRAM_WORDS), .SD_AW(25), .VRAM_BASE(25'd0)) u_vram_sdram (
    .clk(clk), .rst(rst),
    .req(vsd_req), .we(we_q), .widx(widx), .boff(boff), .sz(sz_q), .wd(wd_q),
    .videobank(videobank), .dma_palette(dma_palette), .rdata(vsd_rdata), .done(vsd_done),
    .fb_we(fb_we), .fb_addr(fb_addr), .fb_wdata(fb_wdata), .fb_ack(fb_ack),
    .erase_start(erase_start), .erase_row0(erase_row0), .erase_lines(erase_lines),
    .erase_busy(erase_busy),
    .scan_req(scan_req), .scan_addr(scan_addr), .scan_data(scan_data), .scan_ack(scan_ack),
    .sd_addr(vsd_addr), .sd_din(vsd_din), .sd_be(vsd_be), .sd_rd(vsd_rd), .sd_wr(vsd_wr),
    .sd_dout(vsd_dout), .sd_ack(vsd_ack));
`endif

  // The 48-bit window and merged write value are computed SEQUENTIALLY inside
  // M_ACK (below), NOT as continuous assigns: a continuous assign that reads a
  // memory via read_word() does not re-evaluate when the array is written, so a
  // read at the same word index as the previous access would return a stale
  // value. Sampling in the clocked block reads the committed memory each cycle.
  logic [47:0] win_s, merged_s;
  logic [47:0] win_s_q;   // registered window for the pipelined non-BRAM read extract
  logic [27:0] wrel;                                  // region-relative write base

`ifdef MEASURE_ACCESS
  // Sim-only Phase-6 instrumentation: per-region access distribution, to decide
  // how simple each region's synthesizable field engine can be. A "straddle"
  // read/write spans >1 (>=word+1) or >2 (>=word+2) 16-bit words. Aligned,
  // single-word accesses need only a registered 2-port BRAM; straddles need the
  // multi-cycle window FSM. Guarded — inert unless +define+MEASURE_ACCESS.
  integer rd_cnt   [0:15]; integer wr_cnt   [0:15];   // total reads / writes
  integer rd_str1  [0:15]; integer wr_str1  [0:15];   // spans word+1
  integer rd_str2  [0:15]; integer wr_str2  [0:15];   // spans word+2
  integer rd_boffnz[0:15]; integer wr_boffnz[0:15];   // boff != 0
  integer rd_szmax [0:15]; integer wr_szmax [0:15];   // max field size
  initial begin
    for (int i=0;i<16;i++) begin
      rd_cnt[i]=0; wr_cnt[i]=0; rd_str1[i]=0; wr_str1[i]=0;
      rd_str2[i]=0; wr_str2[i]=0; rd_boffnz[i]=0; wr_boffnz[i]=0;
      rd_szmax[i]=0; wr_szmax[i]=0;
    end
  end
  function automatic string rname(input logic [3:0] r);
    case (r)
      R_VRAM:rname="VRAM"; R_RAM:rname="RAM";  R_CMOS:rname="CMOS"; R_PAL:rname="PAL";
      R_DMA:rname="DMA";  R_INPUT:rname="INPUT";R_PROT:rname="PROT"; R_SOUND:rname="SOUND";
      R_CTRL:rname="CTRL";R_GFX:rname="GFX";   R_ROM:rname="ROM";   default:rname="NONE";
    endcase
  endfunction
  final begin report_access(); end
  task automatic report_access;
    $display("=== MEASURE_ACCESS: per-region field distribution ===");
    $display("%-6s %8s %8s %8s %6s | %8s %8s %8s %6s",
             "region","rd","rd>=w+1","rd>=w+2","szmax","wr","wr>=w+1","wr>=w+2","szmax");
    for (int i=0;i<16;i++) if (rd_cnt[i]||wr_cnt[i])
      $display("%-6s %8d %8d %8d %6d | %8d %8d %8d %6d",
        rname(i[3:0]), rd_cnt[i], rd_str1[i], rd_str2[i], rd_szmax[i],
        wr_cnt[i], wr_str1[i], wr_str2[i], wr_szmax[i]);
  endtask
`endif

  // ---- sequential ------------------------------------------------------
  // Plain `always` (not `always_ff`) so `ram` can also be driven by the sim-only
  // `initial` zeroing above without violating SV's "one driving process per
  // variable" rule for always_ff (Questa vopt-7061). Same reason as birdybro's
  // sim_memory_model. This is the functional model; the synthesizable HW memory
  // controller (Phase 6) drops the initial and uses always_ff.
  always @(posedge clk) begin
    if (rst) begin
      state     <= M_IDLE;
      mem_ack   <= 1'b0;
      mem_rdata <= 32'h0;
      snd_select <= 8'h00;
      snd_trig   <= 1'b0;
      snd_reset  <= 1'b1;   // board held in reset until the game's first
                            // latch write with D[8]=1 releases it (MAME model)
      er_run     <= 1'b0;
`ifdef YM_EXT_RD
      gfx_rd     <= 1'b0;
`endif
`ifdef USE_HW_VRAM
      er_ph      <= 2'd0;
`endif
`ifdef USE_SDRAM_VRAM
      vsd_req    <= 1'b0;
`endif
    end else begin
      // Blitter VRAM write (independent of the CPU access FSM). The blitter
      // never writes the same pixel the CPU is mid-accessing (the CPU polls
      // the blitter and leaves VRAM alone while a blit runs), so a plain
      // per-index store is safe in this functional model.
`ifndef YM_VRAM_HW
      if (fb_we) vram[fb_addr] <= fb_wdata;
`endif

      // ---- Autoerase engine (MAME midyunit_v.cpp:534-560) ----------------
      // Per frame, every DISPLAYED row is refilled with the erase pattern the
      // game maintains in VRAM rows 510 (even rows) / 511 (odd rows):
      //   autoerase_line (:534): if (m_autoerase_enable && 0 <= line < 510)
      //     memcpy(&vram[512*line], &vram[512*(510 + (line & 1))], 512 words)
      // scanline_update (:554) erases rowaddr-1 after each scanned line and
      // (:558-559) the last visible rowaddr one line later, so the per-frame
      // erased set = rows (first_rowaddr - 1) .. last_rowaddr = lines+1 rows.
      // The full 16-bit {palette_hi, pixel_lo} word is copied (memcpy), NOT a
      // solid fill — rows 510/511 are a game-authored per-column pattern.
      //
      // DIVERGENCE NOTE (documented, deliberate): MAME's <510 guard tests the
      // RAW 34010 rowaddr (tms34010.cpp:1152 rowaddr = dpyadr >> 4, 12 bits)
      // while the pixel fetch masks it to 9 bits (midyunit_v.cpp:545
      // (rowaddr<<9) & 0x3fe00). We guard on the MASKED row (skip 510/511
      // only), so a window that straddles the 512-row wrap (rows 480-511 +
      // 0-31, seen on this game's boot screens) also erases the wrapped rows
      // — which is what correct video needs; MAME's raw-value guard would
      // leave them stale if the raw rowaddr ran past 511. Identical to MAME
      // whenever the raw window stays within 0..511. The row0-1 = -1 first
      // call MAME skips (line<0) maps here to masked row 511, which the
      // 510/511 guard skips — equivalent by construction.
      //
      // One pixel per clock (512 clk/row, ~132k clk/frame at 256 lines): a
      // paced read-copy loop, the same access shape the Phase-6 SDRAM
      // controller will burst. Ordered AFTER the blitter fb_we store so a
      // same-cycle collision resolves to the erase (MAME's erase timer also
      // runs after the blit that raced it).
`ifndef YM_VRAM_HW
      if (er_run) begin
        if (er_row != 9'd510 && er_row != 9'd511)     // never erase the erase-pattern rows
          vram[{er_row, er_x}] <= vram[{8'hFF, er_row[0], er_x}]; // src row = 510 | parity
        if (er_x == 9'd511) begin
          er_x   <= 9'd0;
          er_row <= er_row + 9'd1;                    // mod-512 row advance
          er_left <= er_left - 10'd1;
          if (er_left <= 10'd1) er_run <= 1'b0;       // that was the last row
        end else begin
          er_x <= er_x + 9'd1;
        end
      end else if (erase_start === 1'b1 && autoerase && erase_lines != 10'd0) begin
        // gated on the captured CONTROL /autoerase enable (control_w:235)
        er_run  <= 1'b1;
        er_row  <= erase_row0 - 9'd1;                 // one-behind first row (:554)
        er_x    <= 9'd0;
        er_left <= erase_lines + 10'd1;               // + the final-line timer row (:558)
      end
`endif
`ifdef USE_HW_VRAM
      // autoerase 3-cycle engine (ports driven by the VRAM arbiter above). ER0
      // issues the src read (on grant), ER0b captures src from va_q (unconditional
      // -- va_q one cycle after ER0 == src regardless of who addresses the port),
      // ER2 writes dst (on grant) and advances the sweep. Paused (no advance) while
      // the CPU field engine or fb_we owns the ports -> byte-identical to MAME's
      // per-row copy, just spread across contention.
      if (er_run) begin
        case (er_ph)
          2'd0: if (ae_grant) er_ph <= 2'd1;                   // read issued -> capture next
          2'd1: begin er_srcval <= va_q; er_ph <= 2'd2; end    // va_q == vram[src]
          2'd2: if (ae_grant) begin                            // dst written -> advance
                  er_ph <= 2'd0;
                  if (er_x == 9'd511) begin
                    er_x    <= 9'd0;
                    er_row  <= er_row + 9'd1;                  // mod-512 row advance
                    er_left <= er_left - 10'd1;
                    if (er_left <= 10'd1) er_run <= 1'b0;      // last row done
                  end else er_x <= er_x + 9'd1;
                end
          default: er_ph <= 2'd0;
        endcase
      end else if (erase_start === 1'b1 && autoerase && erase_lines != 10'd0) begin
        er_run  <= 1'b1;
        er_row  <= erase_row0 - 9'd1;
        er_x    <= 9'd0;
        er_left <= erase_lines + 10'd1;
        er_ph   <= 2'd0;
      end
`endif

      unique case (state)
        M_IDLE: begin
          mem_ack <= 1'b0;
          if (mem_req && !mem_ack) begin
            a_q   <= mem_addr;
            we_q  <= mem_we;
            wd_q  <= mem_wdata;
            sz_q  <= mem_size;
            state <= M_ACK;
          end
        end
        M_ACK: begin
`ifdef YM_EXT_RD
          // External read-only fetch (R_GFX and/or R_ROM): fetch the 6 window bytes
          // (words widx..widx+2 -> consecutive little-endian bytes) over
          // gfx_rd/gfx_rack, then complete. ext_fetch/ext_base select the region
          // and byte base (gfx @0, program ROM @SDRAM_ROMB). Writes + all other
          // regions (and out-of-range ROM) take the normal path below.
          if (ext_fetch) begin
            mem_ack  <= 1'b0;                          // hold ack until fetched
            gfx_base <= ext_base;                      // byte addr of word0 low byte
            gfx_cnt  <= 3'd0;
            gfx_rd   <= 1'b1;
            state    <= M_GFX;
          end else begin
`endif
          if (is_hwram) begin
            // RAM/PAL/CMOS -> clocked BRAM window engine (multi-cycle). The read
            // of w0/w1 is issued combinationally (eng ports) this cycle; captured
            // in M_HR1. Field math unchanged (hwin/hmerged mirror win_s/merged_s).
            mem_ack <= 1'b0;
            state   <= M_HR1;
          end else if (is_hwvram) begin
            mem_ack <= 1'b0;
`ifdef USE_SDRAM_VRAM
            // VRAM -> SDRAM engine (vram_sdram_top). Pulse req; M_VSD waits for done.
            vsd_req <= 1'b1;
            state   <= M_VSD;
`else
            // VRAM -> clocked 2-port BRAM engine. M_ACK issues the e0/e1 read (via
            // the arbiter); reads go to M_VRD, writes to M_VWR0 (read-modify-write).
            state   <= we_q ? M_VWR0 : M_VRD;
`endif
          end else begin
          // Sample the 3-word window FRESH from committed memory this cycle.
          win_s    = {read_word(region, widx + 28'd2),
                      read_word(region, widx + 28'd1),
                      read_word(region, widx)};
          merged_s = (win_s & ~smask) | (({16'h0, wd_q} << boff) & smask);
`ifdef MEASURE_ACCESS
          if (we_q) begin
            wr_cnt[region] <= wr_cnt[region] + 1;
            if (lastb >= 6'd16) wr_str1[region] <= wr_str1[region] + 1;
            if (lastb >= 6'd32) wr_str2[region] <= wr_str2[region] + 1;
            if (boff != 4'd0)   wr_boffnz[region] <= wr_boffnz[region] + 1;
            if (sz > wr_szmax[region][5:0]) wr_szmax[region] <= sz;
          end else begin
            rd_cnt[region] <= rd_cnt[region] + 1;
            if (lastb >= 6'd16) rd_str1[region] <= rd_str1[region] + 1;
            if (lastb >= 6'd32) rd_str2[region] <= rd_str2[region] + 1;
            if (boff != 4'd0)   rd_boffnz[region] <= rd_boffnz[region] + 1;
            if (sz > rd_szmax[region][5:0]) rd_szmax[region] <= sz;
          end
`endif
          if (we_q) begin
            // Writable regions: RAM / VRAM / palette / CMOS. ROM read-only; the
            // register regions (DMA/INPUT/CTRL/SOUND/PROT) are routed elsewhere
            // (Phase 3) and dropped here. 3-word straddle RMW per region.
            unique case (region)
`ifndef USE_HW_RAM
              R_RAM: begin
                wrel = widx - WB_RAM;
                if (wrel < RAMW)                        ram[wrel]     <= merged_s[15:0];
                if (lastb >= 6'd16 && (wrel+1) < RAMW)  ram[wrel + 1] <= merged_s[31:16];
                if (lastb >= 6'd32 && (wrel+2) < RAMW)  ram[wrel + 2] <= merged_s[47:32];
              end
`endif
`ifndef YM_VRAM_HW
              R_VRAM: begin
                // MAME vram_w byte-lane: each 34010 word offset -> 2 pixels
                // (offset*2, +1); videobank picks pixel vs palette-base plane.
                // CRITICAL: apply only the ACCESSED byte lane(s). A single 8-bit
                // pixel write (the PIXBLT binary color-expand runs psize=8, one
                // pixel per mem op) must NOT touch the neighbouring pixel — the
                // old code always wrote both, so wd_q[15:8]=0 corrupted the odd
                // pixel and garbled non-uniform content (text). Solid fills hid it.
                if (sz <= 6'd8) begin
                  // one pixel, selected by the bit offset (boff 0 -> even, 8 -> odd)
                  wrel = (widx<<1) + {27'b0, boff[3]};
                  if (wrel < VRAMW) begin
                    if (videobank)
                      vram[wrel] <= {(boff[3] ? dma_palette[15:8] : dma_palette[7:0]), wd_q[7:0]};
                    else
                      vram[wrel] <= {wd_q[7:0], vram[wrel][7:0]};
                  end
                end else begin
                // Low 16-bit sub-word (2 pixels) at offset widx:
                if (((widx<<1)+28'd1) < VRAMW) begin
                  if (videobank) begin
                    vram[ widx<<1     ] <= {dma_palette[7:0],  wd_q[7:0]};
                    vram[(widx<<1)+1  ] <= {dma_palette[15:8], wd_q[15:8]};
                  end else begin
                    vram[ widx<<1     ] <= {wd_q[7:0],  vram[ widx<<1   ][7:0]};
                    vram[(widx<<1)+1  ] <= {wd_q[15:8], vram[(widx<<1)+1][7:0]};
                  end
                end
                // High 16-bit sub-word (only on a 32-bit access) at offset widx+1:
                if (sz > 6'd16 && (((widx+1)<<1)+28'd1) < VRAMW) begin
                  if (videobank) begin
                    vram[ (widx+1)<<1   ] <= {dma_palette[7:0],  wd_q[23:16]};
                    vram[((widx+1)<<1)+1] <= {dma_palette[15:8], wd_q[31:24]};
                  end else begin
                    vram[ (widx+1)<<1   ] <= {wd_q[23:16], vram[ (widx+1)<<1   ][7:0]};
                    vram[((widx+1)<<1)+1] <= {wd_q[31:24], vram[((widx+1)<<1)+1][7:0]};
                  end
                end
                end // sz > 8 (2/4-pixel word write)
              end
`endif
`ifndef USE_HW_RAM
              R_PAL: begin
                wrel = widx - WB_PAL;
                if (wrel < PALW)                        pal[wrel]     <= merged_s[15:0];
                if (lastb >= 6'd16 && (wrel+1) < PALW)  pal[wrel + 1] <= merged_s[31:16];
                if (lastb >= 6'd32 && (wrel+2) < PALW)  pal[wrel + 2] <= merged_s[47:32];
              end
`endif
`ifndef USE_HW_RAM
              R_CMOS: begin
                // Paged: index = cmos_page*0x1000 + (offset within page). MAME's
                // cmos_w is ungated (it does not check the cmos_w_enable latch).
                wrel = widx - WB_CMOS;
                if (wrel < CMOSW)                       nvram[{cmos_page, wrel[11:0]}]         <= merged_s[15:0];
                if (lastb >= 6'd16 && (wrel+1) < CMOSW) nvram[{cmos_page, wrel[11:0]} + 14'd1] <= merged_s[31:16];
                if (lastb >= 6'd32 && (wrel+2) < CMOSW) nvram[{cmos_page, wrel[11:0]} + 14'd2] <= merged_s[47:32];
              end
`endif
              default: ; // ROM / register regions: drop (+ HW_RAM regions, handled by engine)
            endcase
            // CONTROL register write (0x01F00000, MAME control_w): videobank
            // (bit 5, VRAM byte-lane plane), CMOS page (bits 7:6 × 0x1000), and
            // autoerase enable (~bit 4). The field write lands wd_q at boff, but
            // the CPU writes CONTROL as an aligned word, so bits 4-7 are in wd_q.
            if (region == R_CTRL) begin
              videobank <= wd_q[5];
              cmos_page <= wd_q[7:6];
              autoerase <= ~wd_q[4];
            end
            // SOUND latch write (0x01E00000, MAME cvsd_sound_w): board sees
            // select = D[7:0], CB1 trig = D[9], reset while D[8] = 0.
            if (region == R_SOUND) begin
              snd_select <= wd_q[7:0];
              snd_trig   <= wd_q[9];
              snd_reset  <= ~wd_q[8];
            end
            mem_rdata <= 32'h0;
            mem_ack   <= 1'b1;         // writes/register-sets complete this cycle
            state     <= M_IDLE;
          end else begin
`ifdef USE_HW_RAM
            win_s_q <= win_s;          // pipeline the extract (synth timing closure @96 MHz)
            mem_ack <= 1'b0;
            state   <= M_RDLY;
`else
            mem_rdata <= 32'((win_s >> boff) & rmask);   // functional: 1-cycle read
            mem_ack   <= 1'b1;
            state     <= M_IDLE;
`endif
          end
          end  // else (functional single-cycle path for non-BRAM regions)
`ifdef YM_EXT_RD
          end  // else (non-external / write path)
`endif
        end
`ifdef YM_EXT_RD
        M_GFX: begin
          // Fetch 6 consecutive bytes; assemble the 48-bit window (word N =
          // {hi=byte[2N+1], lo=byte[2N]}), then extract the field. gfx_raddr is
          // driven combinationally (= gfx_base+gfx_cnt); req/ack with a 1-cycle gap
          // (deassert gfx_rd on ack) so ANY SDRAM read latency works, not just 0.
          if (gfx_rack) begin
            gfx_rd <= 1'b0;                            // consumed -> gap before next req
            if (gfx_cnt == 3'd5) begin
              mem_ack   <= 1'b1;
              mem_rdata <= 32'((({gfx_rdata, gfx_buf[4], gfx_buf[3],
                                  gfx_buf[2], gfx_buf[1], gfx_buf[0]} >> boff) & rmask));
              state     <= M_IDLE;
            end else begin
              gfx_buf[gfx_cnt] <= gfx_rdata;
              gfx_cnt          <= gfx_cnt + 3'd1;
            end
          end else if (!gfx_rd) begin
            gfx_rd <= 1'b1;                            // (re)issue request for gfx_cnt
          end
        end
`endif  // YM_EXT_RD
`ifdef USE_HW_RAM
        // Clocked BRAM window engine (RAM/PAL/CMOS). eng ports are driven
        // combinationally by `state` above; here we capture q and sequence.
        M_HR1: begin
          rd0   <= eng_aq;            // ram[hidx0] (issued in M_ACK) valid now
          rd1   <= eng_bq;            // ram[hidx1]
          state <= M_HR2;             // M_HR1 combinationally pre-issued hidx2 read
        end
        M_HR2: begin
          rd2   <= eng_aq;            // ram[hidx2] valid now (masked by hval2 in hwin)
          state <= M_HFIN;
        end
        M_HFIN: state <= M_HFIN2;   // rd*/hwin captured -> hwin_q latches this edge; merge/extract next cycle
        M_HFIN2: begin
          // hwin_q + the registered a_q-derived masks are valid -> merge/extract from registers.
          if (we_q) begin
            // write-back w0,w1 issued combinationally this cycle (eng_awe/bwe, hmerged2).
            if (lastb >= 6'd32 && hval[2]) begin
              state <= M_HW2;         // need a 3rd write (only 2 ports)
            end else begin
              mem_ack <= 1'b1;
              state   <= M_IDLE;
            end
          end else begin
            mem_rdata <= 32'((hwin_q >> boff_q) & rmask_q);   // extract field (pipelined)
            mem_ack   <= 1'b1;
            state     <= M_IDLE;
          end
        end
        M_HW2: begin                  // 3rd-word write (eng_awe drives hidx2)
          mem_ack <= 1'b1;
          state   <= M_IDLE;
        end
        M_RDLY: begin                 // non-BRAM (INPUT/PROT/CTRL) read: extract from registered window
          mem_rdata <= 32'((win_s_q >> boff_q) & rmask_q);
          mem_ack   <= 1'b1;
          state     <= M_IDLE;
        end
`endif  // USE_HW_RAM
`ifdef USE_HW_VRAM
        // Clocked VRAM engine. Ports are driven combinationally by `state` (via cv
        // + the arbiter). Read: 1 word (never straddles). Write: RMW e0/e1 (+e2/e3).
        M_VRD: begin
          mem_rdata <= 32'((({32'h0, vword} >> boff) & rmask));   // form+extract field
          mem_ack   <= 1'b1;
          state     <= M_IDLE;
        end
        M_VWR0: begin
          o0 <= va_q; o1 <= vb_q;                 // e0/e1 old values (read in M_ACK)
          state <= (sz_q > 6'd16) ? M_VWR1 : M_VWW0;  // sz>16 also needs e2/e3 (issued now)
        end
        M_VWR1: begin
          o2 <= va_q; o3 <= vb_q;                 // e2/e3 old values
          state <= M_VWW0;
        end
        M_VWW0: begin
          // e0/e1 (or ea) writes issued this cycle via cv/arbiter.
          if (sz_q > 6'd16) state <= M_VWW1;
          else begin mem_ack <= 1'b1; state <= M_IDLE; end
        end
        M_VWW1: begin                             // e2/e3 writes issued this cycle
          mem_ack <= 1'b1;
          state   <= M_IDLE;
        end
`endif  // USE_HW_VRAM
`ifdef USE_SDRAM_VRAM
        M_VSD: begin                              // VRAM access via vram_sdram_top
          vsd_req <= 1'b0;                        // req was a 1-cycle pulse (latched)
          if (vsd_done) begin
            mem_rdata <= vsd_rdata;               // read result (ignored for writes)
            mem_ack   <= 1'b1;
            state     <= M_IDLE;
          end
        end
`endif
        default: begin
          state   <= M_IDLE;
          mem_ack <= 1'b0;
        end
      endcase
    end
  end

endmodule

`default_nettype wire
