//============================================================================
//  Arcade: Ultimate Mortal Kombat 3 (Midway Wolf-unit) for MiSTer — emu wrapper
//
//  Open, anti-paywall TMS34010 Wolf-unit core. This emu wraps rtl/wolf/wolf_top.sv
//  (the whole synthesizable core: TMS34010 + wolf memory map + wolf_dma blitter +
//  video + 15-bit palette + internal PIC + SDRAM controller) in the standard
//  Template_MiSTer chassis. wolf_top OWNS the SDRAM controller, so this wrapper just
//  passes the SDRAM pins through and feeds it clocks, inputs, ioctl ROM data, RGB out.
//
//  FIRST FLASH SCOPE: program ROM only (u54/u63). gfx + DCS (ADSP-2105) sound are
//  DEFERRED — the goal is a DIAG_BOOT plumbing validation (reset-vector + PC advance),
//  mirroring the Smash T.V. bring-up. Silicon fixes P0019 + P0022 are baked into
//  wolf_top from day one.
//
//  GPL. No ROM data distributed. See VENDOR.md.
//============================================================================
module emu
(
	input         CLK_50M,
	input         RESET,
	inout  [48:0] HPS_BUS,

	output        CLK_VIDEO,
	output        CE_PIXEL,
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER,
	output        VGA_DISABLE,

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	output  [1:0] BUTTONS,

	input         CLK_AUDIO,
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,

	inout   [3:0] ADC_BUS,

	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

// ---- unused chassis features -------------------------------------------------
assign VGA_F1 = 0;
assign VGA_SCALER = 0;   // VGA_SL is driven by arcade_video
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
assign FB_FORCE_BLANK = 0;
assign {FB_EN, FB_FORMAT, FB_WIDTH, FB_HEIGHT, FB_BASE, FB_STRIDE} = 0;
assign {FB_PAL_CLK, FB_PAL_ADDR, FB_PAL_DOUT, FB_PAL_WR} = 0;
// HPS DDR3 (f2h_sdram1) hosts VRAM under USE_DDR3_VRAM (frees the SDRAM port so scanout no longer
// starves the CPU). DDRAM_CLK is driven from clk_sys — the whole ram1 f2sdram bridge + safe-
// terminator run off this core-supplied clock (sys_top.v:603,1811 + sysmem.sv:203,325,311,421-423),
// so the agent on clk_sys sees NO clock-domain crossing. The 6 master outputs are driven by
// yunit_top (tied to 0 there when USE_DDR3_VRAM is off).
assign DDRAM_CLK = clk_sys;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign USER_OUT = '1;
// Queue-pressure telemetry for cabinet stress tests. MiSTer's LED_DISK bus is
// {override, state} for one physical LED, so keep overflow on LED_USER where it
// remains independently visible after the ROM-download indication clears.
assign LED_DISK  = {1'b1, (dbg_dma_q_highwater >= 9'd128)};
assign LED_POWER = 0;
assign LED_USER  = ioctl_download | dbg_dma_q_overflow;
assign BUTTONS   = 0;

// Smash T.V. is a horizontal 4:3 game.
assign VIDEO_ARX = status[1] ? 12'd16 : 12'd4;
assign VIDEO_ARY = status[1] ? 12'd9  : 12'd3;

assign AUDIO_S   = 1;              // yunit_top emits signed PCM
assign AUDIO_MIX = 0;

// SDRAM_CLK is forwarded from the phase-shifted PLL output (clk_sdram = outclk_1, -3515ps)
// straight to the pin, exactly like the proven tecmo/jtframe MiSTer cores on this DE10 —
// and rtl/sdram.sdc sources the SDRAM_CLK generated clock from that same general[1] output,
// so the fitter closes the read window against the REAL pin clock. (An earlier build drove
// SDRAM_CLK from a DDIO on clk_sys, which did NOT match the SDC -> reads captured against a
// phantom edge -> black screen on silicon. The stock controller keeps its proven CAS-latency
// capture; only the clock forward reverts to this proven scheme.)
assign SDRAM_CLK = clk_sdram;

`include "build_id.v"
localparam CONF_STR = {
	`ifdef WOLF_MASTER
	"A.Wolf Unit;;",
	`elsif OPEN_ICE
	"A.NHL Open Ice;;",
	`elsif WWF_MANIA
	"A.WWF WrestleMania;;",
	`elsif MK3
	"A.Mortal Kombat 3;;",
	`elsif NBA_HANGTIME
	"A.NBA Hangtime;;",
	`elsif RAMPAGE_WT
	"A.Rampage World Tour;;",
	`else
	"A.UMK3;;",
	`endif
	"O1,Aspect Ratio,4:3,16:9;",
	`ifndef WOLF_MASTER
	"O3,Direct Video,Off,On;",
	`endif
	`ifdef DCS_ONLY_TEST
	"O2,DCS Test Audio,DCS,Tone;",
	`endif
	"O46,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	`ifndef WOLF_MASTER
	`ifndef OPEN_ICE
	"O7,CRT Geometry Adjust,Off,On;",
	`endif
	`endif
	"-;",
	"DIP;",
	"O8,Test Switch,Off,On;",
	"O9,Service Credit,Off,On;",
	"OA,Volume Down,Off,On;",
	"OB,Volume Up,Off,On;",
	`ifdef WOLF_MASTER
	"OC,Sports Cabinet,2 Players,4 Players;",
	`elsif NBA_HANGTIME
	"OC,Cabinet,2 Players,4 Players;",
	`elsif OPEN_ICE
	"OC,Cabinet,2 Players,4 Players;",
	`endif
	"-;",
	"OD,Autosave NVRAM,On,Off;",
	"TE,Save NVRAM;",
	"TF,Clear NVRAM;",
	"-;",
	"R0,Reset;",
	`ifdef WOLF_MASTER
	"J1,Button 1,Button 2,Button 3,Button 4,Button 5,Button 6,Start,Coin;",
	"jn,A,B,X,Y,L,R,Start,Select;",
	`elsif OPEN_ICE
	"J1,Turbo,Shoot / Block,Pass / Steal,Start,Coin;",
	"jn,A,X,Y,Start,Select;",
	`elsif WWF_MANIA
	"J1,Punch,Defense,Power Punch,Kick,Power Kick,Start,Coin;",
	"jn,A,X,Y,B,L,Start,Select;",
	`elsif NBA_HANGTIME
	"J1,Turbo,Shoot / Block,Pass / Steal,Start,Coin;",
	"jn,A,X,Y,Start,Select;",
	`elsif RAMPAGE_WT
	// Order matches the staged MRA <buttons names="Jump,Punch,Kick,Start,Coin">
	// (MRA-NOTES.md): joystick[4]=Jump(B1) [5]=Punch(B2) [6]=Kick(B3).
	"J1,Jump,Punch,Kick,Start,Coin;",
	"jn,A,X,Y,Start,Select;",
	`else
	"J1,High Punch,Low Punch,Block,High Kick,Low Kick,Run,Start,Coin;",
	"jn,X,Y,A,B,R,L,Start,Select;",
	`endif
	"V,v",`BUILD_DATE
};

////////////////////////////////////////////////////////////////////////////////
// CLOCKS — clk_sys/clk_sdram = fitted 80 MHz, clk_snd = 12 MHz (legacy port)
////////////////////////////////////////////////////////////////////////////////
wire clk_sys, clk_sdram, clk_snd, clk_cpu;
wire locked;

pll pll
(
	.rst(RESET),
	.refclk(CLK_50M),
	.outclk_0(clk_sys),      // 80 MHz
	.outclk_1(clk_sdram),    // 80 MHz, phase-shifted for the SDRAM chip
	.outclk_2(clk_snd),      // 12 MHz sound-board clock
	.outclk_3(clk_cpu),      // 24 MHz CPU clock (TMS34010 execute path maxes ~30 MHz)
	.locked(locked)
);

// pixel-clock enable: 80 MHz / 10 = 8 MHz (was 96/12; PLL dropped to 80 for timing margin, ce_pix unchanged)
reg [3:0] cediv = 0;
wire ce_pix = (cediv == 4'd0);
always @(posedge clk_sys) cediv <= (cediv == 4'd9) ? 4'd0 : cediv + 4'd1;

////////////////////////////////////////////////////////////////////////////////
// HPS IO
////////////////////////////////////////////////////////////////////////////////
wire  [1:0] buttons;
wire [31:0] status;
wire        forced_scandoubler;
wire [21:0] gamma_bus;
wire        direct_video;

wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wr;
wire        ioctl_download;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire  [7:0] ioctl_index;
wire  [7:0] ioctl_din;
// Runtime profile byte supplied by every master MRA at index 3.
// 0 Open Ice, 1 WWF, 2 MK3, 3 UMK3, 4 Hangtime, 5 Maximum, 6 Rampage.
`ifdef OPEN_ICE
localparam logic [2:0] DEFAULT_GAME_PROFILE = 3'd0;
`elsif WWF_MANIA
localparam logic [2:0] DEFAULT_GAME_PROFILE = 3'd1;
`elsif MK3
localparam logic [2:0] DEFAULT_GAME_PROFILE = 3'd2;
`elsif NBA_HANGTIME
localparam logic [2:0] DEFAULT_GAME_PROFILE = 3'd4;
`elsif NBA_MAXIMUM
localparam logic [2:0] DEFAULT_GAME_PROFILE = 3'd5;
`elsif RAMPAGE_WT
localparam logic [2:0] DEFAULT_GAME_PROFILE = 3'd6;
`else
localparam logic [2:0] DEFAULT_GAME_PROFILE = 3'd3;
`endif
reg   [2:0] game_profile = DEFAULT_GAME_PROFILE;
`ifdef WOLF_MASTER
wire  [2:0] active_game_profile = game_profile;
`else
// A dedicated build must never silently inherit another game's PIC/status
// behavior merely because its MRA omitted or corrupted the master selector.
wire  [2:0] active_game_profile = DEFAULT_GAME_PROFILE;
`endif

wire [15:0] joystick_0, joystick_1, joystick_2, joystick_3;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.buttons(buttons),
	.status(status),
	.status_menumask(direct_video),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),

	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wr(ioctl_wr),
	.ioctl_wait(combined_ioctl_wait), // SDRAM (index0) OR gfx-DDR3 (index1) FIFO backpressure
	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(8'd4),
	.ioctl_din(ioctl_din),
	.ioctl_index(ioctl_index),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(joystick_2),
	.joystick_3(joystick_3)
);
wire yt_ioctl_wait;
wire gfxdl_wait;
wire dcsdl_wait;
wire combined_ioctl_wait = yt_ioctl_wait | gfxdl_wait | dcsdl_wait;

////////////////////////////////////////////////////////////////////////////////
// VIDEO
////////////////////////////////////////////////////////////////////////////////
wire [7:0] r, g, b;
wire       hsync, vsync, hblank, vblank, de;

// boot-instrument taps + overlay video (driven later by the core + smashtv_diag2_overlay)
wire [31:0] dbg_pc; wire dbg_illegal, dbg_core_rst, dbg_sdram_ready, dbg_unp_done, dbg_cpu_req, dbg_mem_ack;
wire dbg_int1, dbg_vblank_irq, dbg_cpu_ce;
wire dbg_derailed; wire [31:0] dbg_culprit_pc, dbg_derail_pc; wire [15:0] dbg_culprit_instr;
wire [31:0] dbg_iol_drop, dbg_iol_wrs;   // P0020 download audit (dropped / accepted FIFO pushes)
wire [25:0] dbg_gfx_wbeats;              // gfx-DDR3 audit (constants 0 unless USE_DDR3_GFX)
wire [15:0] dbg_gfx_srd, dbg_gfx_cgrd;
wire dbg_dma_q_overflow;
wire [8:0] dbg_dma_q_highwater;
wire [7:0] ov_r, ov_g, ov_b; wire ov_hs, ov_vs, ov_hb, ov_vb, ov_de;

// arcade_video source: the boot overlay under +define+DIAG_BOOT, else the real core.
// DIAG_GFX (the gfx-download audit rows) rides the same overlay — auto-enable it.
`ifdef DIAG_GFX
  `ifndef DIAG_BOOT
    `define DIAG_BOOT
  `endif
`endif
// DIAG_ILLEGAL freezes the first opcode the TMS34010 decoder rejects.
`ifdef DIAG_ILLEGAL
  `ifndef DIAG_BOOT
    `define DIAG_BOOT
  `endif
`endif
// DIAG_SRT: SRT (shift-register-transfer) sideband counters — latches/transfers per
// frame + sticky bit11-seen. Rows computed in wolf_top's DIAG_SRT arm; rides the
// same boot overlay.
`ifdef DIAG_SRT
  `ifndef DIAG_BOOT
    `define DIAG_BOOT
  `endif
`endif
// The Hangtime backdrop ledger reuses the existing DIAG_FLIP tap bundle and
// boot overlay, but selects its own counters inside wolf_top.
`ifdef DIAG_BACKDROP
  `ifndef DIAG_FLIP
    `define DIAG_FLIP
  `endif
`endif
// DIAG_FLIP (blit-busy vs DPYSTRT-flip race) rides the DIAG_BOOT overlay too — auto-enable it.
`ifdef DIAG_FLIP
  `ifndef DIAG_BOOT
    `define DIAG_BOOT
  `endif
`endif
`ifdef DCS_ONLY_TEST
reg [9:0] dcs_v_hcnt = 10'd0;
reg [8:0] dcs_v_vcnt = 9'd0;
reg [7:0] dcs_diag_stage = 8'd0;
always @(posedge clk_sys) begin
	if (ce_pix) begin
		if (dcs_v_hcnt == 10'd639) begin
			dcs_v_hcnt <= 10'd0;
			dcs_v_vcnt <= (dcs_v_vcnt == 9'd261) ? 9'd0 : dcs_v_vcnt + 9'd1;
		end else begin
			dcs_v_hcnt <= dcs_v_hcnt + 10'd1;
		end
	end
end
wire       dcs_v_visible = (dcs_v_hcnt < 10'd512) && (dcs_v_vcnt < 9'd240);
wire [2:0] dcs_diag_idx = dcs_v_hcnt[8:6];
wire       dcs_diag_area = dcs_v_visible && (dcs_v_vcnt < 9'd64);
wire       dcs_diag_edge = (dcs_v_hcnt[5:0] == 6'd63);
wire       dcs_diag_ok = dcs_diag_stage[dcs_diag_idx];
wire [7:0] av_r = !dcs_v_visible ? 8'h00 :
                  dcs_diag_area ? (dcs_diag_edge ? 8'hff : (dcs_diag_ok ? 8'h10 : 8'hb0)) :
                  {dcs_v_vcnt[4:0], 3'b000};
wire [7:0] av_g = !dcs_v_visible ? 8'h00 :
                  dcs_diag_area ? (dcs_diag_edge ? 8'hff : (dcs_diag_ok ? 8'hd0 : 8'h10)) :
                  {dcs_v_hcnt[5:0], 2'b00};
wire [7:0] av_b = !dcs_v_visible ? 8'h00 :
                  dcs_diag_area ? (dcs_diag_edge ? 8'hff : 8'h10) : 8'h30;
wire       av_hs = (dcs_v_hcnt >= 10'd552) && (dcs_v_hcnt < 10'd608);
wire       av_vs = (dcs_v_vcnt >= 9'd244) && (dcs_v_vcnt < 9'd248);
wire       av_hb = !dcs_v_visible;
wire       av_vb = (dcs_v_vcnt >= 9'd240);
`else
`ifdef DIAG_BOOT
wire [7:0] av_r = ov_r, av_g = ov_g, av_b = ov_b;
wire       av_hs = ov_hs, av_vs = ov_vs, av_hb = ov_hb, av_vb = ov_vb;
`elsif DIAG_GEOM
wire [7:0] av_r = ov_r, av_g = ov_g, av_b = ov_b;
wire       av_hs = ov_hs, av_vs = ov_vs, av_hb = ov_hb, av_vb = ov_vb;
`else
wire [7:0] av_r = r, av_g = g, av_b = b;
wire       av_hs = hsync, av_vs = vsync, av_hb = hblank, av_vb = vblank;
`endif
`endif

arcade_video #(.WIDTH(512), .DW(24)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(ce_pix),
	.RGB_in({av_r, av_g, av_b}),
	.HBlank(av_hb),
	.VBlank(av_vb),
	.HSync(av_hs),
	.VSync(av_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_HS(VGA_HS),
	.VGA_VS(VGA_VS),
	.VGA_DE(VGA_DE),
	.VGA_SL(VGA_SL),

	.fx(status[6:4]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

////////////////////////////////////////////////////////////////////////////////
// ROM DOWNLOAD — UMK3 PROGRAM ROM ONLY (gfx + DCS sound DEFERRED for the first flash).
//   The MRA presents the 34010 maincpu region as its two raw 0x80000-byte EPROMs:
//     [0x000000, 0x080000)  u54  -> program-ROM LOW  byte lane (34010 D0-7, EVEN)
//     [0x080000, 0x100000)  u63  -> program-ROM HIGH byte lane (34010 D8-15, ODD)
//   Each 34010 word j = {u63[j], u54[j]} -> SDRAM word ROMW_BASE + j. The emu writes
//   u54 to the LOW lane (be=01) and u63 to the HIGH lane (be=10) of word j — a
//   deterministic on-chip interleave reproducing sim/make_maindata_hex.py EXACTLY
//   (mame-gospel midwunit.cpp:877-879, ROM_LOAD16_BYTE even/odd). No MRA interleave map.
////////////////////////////////////////////////////////////////////////////////
localparam [24:0] DL_ROMHI_BASE = 25'h080000;  // u63 (high lane) block start (download byte)
localparam [24:0] DL_END        = 25'h100000;  // total download size (2 x 0x80000)
localparam [24:0] ROMW_BASE_DL  = 25'h0C0000;  // SDRAM word base for the program ROM

wire rom_download = ioctl_download & (ioctl_index == 0);
wire dl_is_romlo  = (ioctl_addr <  DL_ROMHI_BASE);                            // u54 -> low
wire dl_is_romhi  = (ioctl_addr >= DL_ROMHI_BASE) && (ioctl_addr < DL_END);   // u63 -> high

wire [24:0] dl_romlo_word = ROMW_BASE_DL + ioctl_addr;                        // 34010 word j = byte j
wire [24:0] dl_romhi_word = ROMW_BASE_DL + (ioctl_addr - DL_ROMHI_BASE);

reg        yt_ioctl_wr;
reg [24:0] yt_ioctl_addr;
reg [15:0] yt_ioctl_dout;
reg  [1:0] yt_ioctl_be;
always @(posedge clk_sys) begin
	yt_ioctl_wr <= 1'b0;
	if (rom_download & ioctl_wr) begin
		if (dl_is_romlo) begin                                       // u54 -> LOW byte (D0-7)
			yt_ioctl_addr <= dl_romlo_word;
			yt_ioctl_dout <= {8'h00, ioctl_dout};
			yt_ioctl_be   <= 2'b01;
			yt_ioctl_wr   <= 1'b1;
		end else if (dl_is_romhi) begin                             // u63 -> HIGH byte (D8-15)
			yt_ioctl_addr <= dl_romhi_word;
			yt_ioctl_dout <= {ioctl_dout, 8'h00};
			yt_ioctl_be   <= 2'b10;
			yt_ioctl_wr   <= 1'b1;
		end
	end
end

// ---- P0021 download-path disambiguation (emu-side, reset on ~locked so it SURVIVES the core
//      reset — unlike yunit_top's FIFO counters). ytwr_cnt = # writes the remap FSM emitted
//      (NOT gated by reset). rst_during_dl = did the core reset overlap the download.
//   overlay row3 = {rst_during_dl, 11'b0, ytwr_cnt[19:0]}:
//     8xxxxxxx = reset was HIGH during download -> (b) FIFO frozen (row2 accepted=0 confirms)
//     000xxxxx, xxxxx>0 = FSM DID emit -> if row2 accepted still 0 & no rst-bit, it's a yt_ioctl_wr
//                         WIRING break between emu and yunit_top
//     00000000 = FSM never emitted -> (a) rom_download & ioctl_wr never true (index/connection)
reg [31:0] dl_ytwr_cnt;
reg        dl_rst_during;
always @(posedge clk_sys) begin
	if (~locked) begin dl_ytwr_cnt <= 32'd0; dl_rst_during <= 1'b0; end
	else begin
		if (yt_ioctl_wr)          dl_ytwr_cnt   <= dl_ytwr_cnt + 1'b1;
		if (rom_download & reset) dl_rst_during <= 1'b1;
	end
end
wire [31:0] dl_diag = {dl_rst_during, 11'b0, dl_ytwr_cnt[19:0]};

////////////////////////////////////////////////////////////////////////////////
// USE_DDR3_GFX only: gfx ROM boot-copy (MRA <rom index="1">, 20 chips, byte stream).
// Byte-granular (no word-lane interleave needed like prog ROM -- wolf_gfx_ddr_top's write
// side does its own beat-accumulation). wolf_gfx_interleave transforms the linear MRA-part
// stream address into the real byte-interleaved gfx-region address (sim/make_wolf_gfx_hex.py
// / sim/tb_wolf_gfx_interleave.sv: 5040/5040 verified). Same 512-deep/HWM=256 FIFO depth as
// the proven prog-ROM iol_fifo above (ioctl_wait round-trip-latency headroom is a function of
// the HPS polling round-trip, not total transfer size, so the same depth that measured 0
// drops there applies here too). Unused/inert (gfxdl_wait tied 0, gfx_dl_active stays high
// forever so wolf_gfx_ddr_top's read side just never activates) when the sv2v'd wolf_top blob
// wasn't built with USE_DDR3_GFX -- gfx_dl_ack simply never pulses in that config.
////////////////////////////////////////////////////////////////////////////////
wire gfx_download = ioctl_download & (ioctl_index == 1);
wire [24:0] gfx_dest_addr;
`ifdef MK3
localparam bit GAME_MK3_GFX_LAYOUT = 1'b1;
`else
localparam bit GAME_MK3_GFX_LAYOUT = 1'b0;
`endif
wolf_gfx_interleave #(.MK3_LAYOUT(GAME_MK3_GFX_LAYOUT)) u_gfxinterleave
	(.mk3_layout_i(active_game_profile == 3'd2),
	 .lin_addr(ioctl_addr[24:0]), .dest_addr(gfx_dest_addr));

// FIFO extracted to rtl/wolf/wolf_gfxdl_fifo.sv (simulable seam). The first cut's
// gfx_dl_active phase latch is GONE — it dropped in the PLL-lock->download idle gap
// (before the HPS sent a single byte) and gated wolf_gfx_ddr_top's write side off; the
// gfx DDR3 block now arbitrates write-vs-read per transaction with no phase input at all.
wire        gfxdl_dl_wr;
wire [24:0] gfxdl_dl_addr;
wire [7:0]  gfxdl_dl_data;
wire        gfx_dl_ack;
wire        gfx_fifo_idle;
wire        gfx_writer_idle;
wire [25:0] gfx_push_cnt;
wolf_gfxdl_fifo u_gfxdlfifo (
	.clk(clk_sys), .sdram_por(sdram_por),
	.push(gfx_download & ioctl_wr), .push_addr(gfx_dest_addr), .push_data(ioctl_dout[7:0]),
	.wait_o(gfxdl_wait), .idle_o(gfx_fifo_idle),
	.dl_wr(gfxdl_dl_wr), .dl_addr(gfxdl_dl_addr), .dl_data(gfxdl_dl_data), .dl_ack(gfx_dl_ack),
	.dbg_pushes(gfx_push_cnt));

// Arm reset at index 0, carry it across any framework gap before index 1, then
// hold through the index-1 FIFO/DDR drain and a post-acceptance quiet period.
wire gfx_download_hold;
wolf_gfxdl_guard u_gfxdl_guard (
	.clk(clk_sys), .sdram_por(sdram_por), .rom_download(rom_download),
	.gfx_download(gfx_download),
	.fifo_idle(gfx_fifo_idle), .writer_idle(gfx_writer_idle),
	.core_hold(gfx_download_hold));
wire profile_download = ioctl_download & (ioctl_index == 3);
wire game_download = gfx_download_hold | profile_download;

// latch the raw ioctl_index seen on any non-index-0 download write: confirms on the DIAG
// overlay whether the MRA <rom index="1"> stream really arrives as ioctl_index==1 (the
// convention this whole path assumes; the STV donor only ever used index 0 + 254).
reg [7:0] gfx_idx_seen;
always @(posedge clk_sys) begin
	if (sdram_por) gfx_idx_seen <= 8'h00;
	else if (ioctl_download & ioctl_wr & (ioctl_index != 0) & (ioctl_index != 254))
		gfx_idx_seen <= ioctl_index[7:0];
end

// ---- DCS (ADSP-2105) sound: DEFERRED for the first flash — no sound ROMs in the MRA.
//      wolf_top's snd_dl_* download port is tied off at the instance below.

// ---- DCS1 sound ROM (MRA index 2): dense raw U2|U3|U4|U5 byte stream ---------
// The DCS core addresses this packed 4 MB layout (chip select = address bits
// 21:20). Reuse the proven HPS backpressure FIFO; the address width carries the
// 22-bit DCS byte address.
wire dcs_download = ioctl_download & (ioctl_index == 2);
wire        dcsdl_dl_wr;
wire [24:0] dcsdl_dl_addr;
wire [7:0]  dcsdl_dl_data;
wire        dcs_dl_ack;
wire        dcs_fifo_idle;
wolf_gfxdl_fifo u_dcsdlfifo (
	.clk(clk_sys), .sdram_por(sdram_por),
	.push(dcs_download & ioctl_wr), .push_addr({3'b000, ioctl_addr[21:0]}), .push_data(ioctl_dout[7:0]),
	.wait_o(dcsdl_wait), .idle_o(dcs_fifo_idle),
	.dl_wr(dcsdl_dl_wr), .dl_addr(dcsdl_dl_addr), .dl_data(dcsdl_dl_data), .dl_ack(dcs_dl_ack),
	.dbg_pushes());

////////////////////////////////////////////////////////////////////////////////
// CONTROLS -> Wolf-unit input word {DSW, IN2, IN1, IN0} (active-low).
`ifdef WOLF_MASTER
wire [15:0] in0, in1, in2, dsw;
wolf_game_inputs #(.PROFILE(3), .RUNTIME_SELECT(1'b1)) u_game_inputs (
	.game_profile(active_game_profile),
	.joystick_0(joystick_0), .joystick_1(joystick_1),
	.joystick_2(joystick_2), .joystick_3(joystick_3),
	.status(status), .in0(in0), .in1(in1), .in2(in2), .dsw(dsw)
);
`elsif OPEN_ICE
wire [15:0] in0, in1, in2, dsw;
wolf_game_inputs #(.PROFILE(0)) u_game_inputs (
	.game_profile(3'd0),
	.joystick_0(joystick_0), .joystick_1(joystick_1),
	.joystick_2(joystick_2), .joystick_3(joystick_3),
	.status(status), .in0(in0), .in1(in1), .in2(in2), .dsw(dsw)
);
`elsif WWF_MANIA
wire [15:0] in0, in1, in2, dsw;
wolf_game_inputs #(.PROFILE(1)) u_game_inputs (
	.game_profile(3'd1),
	.joystick_0(joystick_0), .joystick_1(joystick_1),
	.joystick_2(joystick_2), .joystick_3(joystick_3),
	.status(status), .in0(in0), .in1(in1), .in2(in2), .dsw(dsw)
);
`elsif MK3
wire [15:0] in0, in1, in2, dsw;
wolf_game_inputs #(.PROFILE(2)) u_game_inputs (
	.game_profile(3'd2),
	.joystick_0(joystick_0), .joystick_1(joystick_1),
	.joystick_2(joystick_2), .joystick_3(joystick_3),
	.status(status), .in0(in0), .in1(in1), .in2(in2), .dsw(dsw)
);
`elsif NBA_HANGTIME
// Hangtime: IN0=P1/P2, IN1=P3/P4; each player has Turbo, Shoot/Block,
// Pass/Steal, Start, and Coin. joystick_2/3 provide the four-player cabinet.
wire p1_up=joystick_0[3], p1_dn=joystick_0[2], p1_lf=joystick_0[1], p1_rt=joystick_0[0];
wire p1_turbo=joystick_0[4], p1_shoot=joystick_0[5], p1_pass=joystick_0[6];
wire p1_start=joystick_0[7], p1_coin=joystick_0[8];
wire p2_up=joystick_1[3], p2_dn=joystick_1[2], p2_lf=joystick_1[1], p2_rt=joystick_1[0];
wire p2_turbo=joystick_1[4], p2_shoot=joystick_1[5], p2_pass=joystick_1[6];
wire p2_start=joystick_1[7], p2_coin=joystick_1[8];
wire p3_up=joystick_2[3], p3_dn=joystick_2[2], p3_lf=joystick_2[1], p3_rt=joystick_2[0];
wire p3_turbo=joystick_2[4], p3_shoot=joystick_2[5], p3_pass=joystick_2[6];
wire p3_start=joystick_2[7], p3_coin=joystick_2[8];
wire p4_up=joystick_3[3], p4_dn=joystick_3[2], p4_lf=joystick_3[1], p4_rt=joystick_3[0];
wire p4_turbo=joystick_3[4], p4_shoot=joystick_3[5], p4_pass=joystick_3[6];
wire p4_start=joystick_3[7], p4_coin=joystick_3[8];

wire [15:0] in0 = ~{1'b0, p2_turbo, p2_pass, p2_shoot, p2_rt, p2_lf, p2_dn, p2_up,
                    1'b0, p1_turbo, p1_pass, p1_shoot, p1_rt, p1_lf, p1_dn, p1_up};
wire [15:0] in1 = ~{1'b0, p4_turbo, p4_pass, p4_shoot, p4_rt, p4_lf, p4_dn, p4_up,
                    1'b0, p3_turbo, p3_pass, p3_shoot, p3_rt, p3_lf, p3_dn, p3_up};
wire test_switch    = status[8];
wire service_credit = status[9]  | (test_switch & p1_start);
wire vol_down       = status[10] | (test_switch & p1_dn);
wire vol_up         = status[11] | (test_switch & p1_up);
wire [15:0] in2_active =
	(p1_coin        ? 16'h0001 : 16'h0000) |
	(p2_coin        ? 16'h0002 : 16'h0000) |
	(p1_start       ? 16'h0004 : 16'h0000) |
	(p2_start       ? 16'h0020 : 16'h0000) |
	(service_credit ? 16'h0040 : 16'h0000) |
	(p3_coin        ? 16'h0080 : 16'h0000) |
	(p4_coin        ? 16'h0100 : 16'h0000) |
	(p3_start       ? 16'h0200 : 16'h0000) |
	(p4_start       ? 16'h0400 : 16'h0000) |
	(vol_down       ? 16'h0800 : 16'h0000) |
	(vol_up         ? 16'h1000 : 16'h0000);
wire [15:0] in2 = ~in2_active;
// MAME defaults: powerup test off, 2-player cabinet, CMOS coinage. OC only
// changes the cabinet bit for four-player operation.
wire [15:0] dsw_base = status[12] ? 16'h7FFD : 16'h7F7D;
wire [15:0] dsw = test_switch ? (dsw_base & ~16'h0001) : dsw_base;
`elsif RAMPAGE_WT
// Rampage World Tour gospel: mame-gospel/midway/midwunit.cpp
// INPUT_PORTS_START(rmpgwt):437-527 (D:/deck/fpga/rampageworldtour/DRIVER-SPEC.md §4).
// 3 players x 3 buttons, ACTIVE-LOW. IN0: [3:0]=P1 U/D/L/R, [4]=P1 Punch(BUTTON2),
// [5]=P1 Kick(BUTTON3), [6]=P1 Jump(BUTTON1), [7] unused; P2 mirrors on [14:8],
// [15] unused. IN1: P3 same layout on [6:0], [15:7] unused (0xff80 -> read 1s).
// CONF_STR "J1,Jump,Punch,Kick,Start,Coin" puts Jump/Punch/Kick at joystick[4]/[5]/[6],
// Start=[7], Coin=[8] (framework: buttons start at bit4 in J1-list order) — the MRA
// buttons element assumes exactly this wiring (MRA-NOTES.md): B1(Jump)->io bit6,
// B2(Punch)->io bit4, B3(Kick)->io bit5.
wire p1_up=joystick_0[3], p1_dn=joystick_0[2], p1_lf=joystick_0[1], p1_rt=joystick_0[0];
wire p1_jump=joystick_0[4], p1_punch=joystick_0[5], p1_kick=joystick_0[6];
wire p1_start=joystick_0[7], p1_coin=joystick_0[8];
wire p2_up=joystick_1[3], p2_dn=joystick_1[2], p2_lf=joystick_1[1], p2_rt=joystick_1[0];
wire p2_jump=joystick_1[4], p2_punch=joystick_1[5], p2_kick=joystick_1[6];
wire p2_start=joystick_1[7], p2_coin=joystick_1[8];
wire p3_up=joystick_2[3], p3_dn=joystick_2[2], p3_lf=joystick_2[1], p3_rt=joystick_2[0];
wire p3_jump=joystick_2[4], p3_punch=joystick_2[5], p3_kick=joystick_2[6];
wire p3_start=joystick_2[7], p3_coin=joystick_2[8];

wire [15:0] in0 = ~{1'b0, p2_jump, p2_kick, p2_punch, p2_rt, p2_lf, p2_dn, p2_up,
                    1'b0, p1_jump, p1_kick, p1_punch, p1_rt, p1_lf, p1_dn, p1_up};
wire [15:0] in1 = ~{9'd0, p3_jump, p3_kick, p3_punch, p3_rt, p3_lf, p3_dn, p3_up};
wire test_switch    = status[8];
wire service_credit = status[9]  | (test_switch & p1_start);
wire vol_down       = status[10] | (test_switch & p1_dn);
wire vol_up         = status[11] | (test_switch & p1_up);
// IN2 (midwunit.cpp:511-526): COIN1/2=bits0-1, START1=bit2, TILT=bit3, SERVICE
// (test toggle)=bit4, START2=bit5, SERVICE1(credit)=bit6, COIN3/4=bits7-8,
// START3=bit9, START4=bit10 (harness has 4 slots; only 3 players wired), VOL-=11,
// VOL+=12, INTERLOCK=13, BILL1=15. Same bit positions as the Hangtime harness.
wire [15:0] in2_active =
	(p1_coin        ? 16'h0001 : 16'h0000) |
	(p2_coin        ? 16'h0002 : 16'h0000) |
	(p1_start       ? 16'h0004 : 16'h0000) |
	(p2_start       ? 16'h0020 : 16'h0000) |
	(service_credit ? 16'h0040 : 16'h0000) |
	(p3_coin        ? 16'h0080 : 16'h0000) |
	(p3_start       ? 16'h0200 : 16'h0000) |
	(vol_down       ? 16'h0800 : 16'h0000) |
	(vol_up         ? 16'h1000 : 16'h0000);
wire [15:0] in2 = ~in2_active;
// DSW live idle value, per-field gospel defaults OR'd with the active-low
// IPT_UNUSED bits (an inactive active-low input READS 1), midwunit.cpp:466-508:
//   CoinageSource=CMOS(bit0=0) | Coinage=USA-1(0x003E) | Counters=Two(bit6=0)
//   | UNUSED bit7(0x0080) | BillValidator=Off(0x0100) | UNUSED bit9(0x0200)
//   | PowerupTest=Off(bit10=0) | UNUSED bits14:11(0x7800) | TestSwitch=Off(0x8000)
//   = 0xFBBE.  NOTE: Test Switch is DSW bit 15 here (openice/hangtime-family
// layout), NOT bit 0 as on mk3 — the donor-audit point from MRA-NOTES.md §4.
wire [15:0] dsw = test_switch ? (16'hFBBE & ~16'h8000) : 16'hFBBE;
`else
// UMK3 gospel:
// mame-gospel/midway/midwunit.cpp INPUT_PORTS_START(mk3):136-215 (umk3 shares the "mk3"
// ioport tag per its GAME() macro). Bit map (ACTIVE-LOW; unlisted bits = IPT_UNUSED, tied
// inactive/1): IN0[3:0]=P1 U/D/L/R, [6:4]=P1 HP/Block/HK, [11:8]=P2 U/D/L/R, [14:12]=P2
// HP/Block/HK. IN1[2:0]=P1 LP/LK/Run, [6:4]=P2 LP/LK/Run. IN2[0]=Coin1 [1]=Coin2 [2]=Start1
// [5]=Start2 (Tilt/Service/Coin3-4/Volume/Interlock/Bill left inactive -- not needed for
// basic play). CONF_STR's "J1,High Punch,Low Punch,Block,High Kick,Low Kick,Run,Start,Coin"
// puts these at joystick_0/1[11:4] in that order (framework standard: buttons start at bit4
// in J1-list order, Start/Coin appended after) -- [3:0] directions follow the same
// bit0=Right/bit1=Left/bit2=Down/bit3=Up convention the proven STV core uses (Arcade-SmashTV
// .sv:377-381 in the Smash TV tree).
wire p1_up=joystick_0[3], p1_dn=joystick_0[2], p1_lf=joystick_0[1], p1_rt=joystick_0[0];
wire p1_hp=joystick_0[4], p1_lp=joystick_0[5], p1_blk=joystick_0[6], p1_hk=joystick_0[7];
wire p1_lk=joystick_0[8], p1_run=joystick_0[9], p1_start=joystick_0[10], p1_coin=joystick_0[11];
wire p2_up=joystick_1[3], p2_dn=joystick_1[2], p2_lf=joystick_1[1], p2_rt=joystick_1[0];
wire p2_hp=joystick_1[4], p2_lp=joystick_1[5], p2_blk=joystick_1[6], p2_hk=joystick_1[7];
wire p2_lk=joystick_1[8], p2_run=joystick_1[9], p2_start=joystick_1[10], p2_coin=joystick_1[11];

wire [15:0] in0 = ~{1'b0, p2_hk, p2_blk, p2_hp, p2_rt, p2_lf, p2_dn, p2_up,
                    1'b0, p1_hk, p1_blk, p1_hp, p1_rt, p1_lf, p1_dn, p1_up};
wire [15:0] in1 = ~{8'd0, 1'b0, p2_run, p2_lk, p2_lp, 1'b0, p1_run, p1_lk, p1_lp};
wire test_switch    = status[8];
wire service_credit = status[9]  | (test_switch & p1_start);
wire vol_down       = status[10] | (test_switch & p1_dn);
wire vol_up         = status[11] | (test_switch & p1_up);
wire [15:0] in2_active =
	(p1_coin        ? 16'h0001 : 16'h0000) |
	(p2_coin        ? 16'h0002 : 16'h0000) |
	(p1_start       ? 16'h0004 : 16'h0000) |
	(p2_start       ? 16'h0020 : 16'h0000) |
	(service_credit ? 16'h0040 : 16'h0000) |
	(vol_down       ? 16'h0800 : 16'h0000) |
	(vol_up         ? 16'h1000 : 16'h0000);
wire [15:0] in2 = ~in2_active;
// DSW: gospel-exact MAME defaults (mame-gospel/midway/midwunit.cpp INPUT_PORTS_START(mk3):
// 166-213), NOT a blanket 0xFFFF. That blanket value matched most fields by coincidence
// (Test Switch=Off, Coinage=USA-1 both happen to be "all associated bits=1") but got
// **Powerup Test (bit9, 0x0200) wrong: default is OFF (0), blanket-FFFF set it ON (1).**
// Powerup Test runs a boot-time ROM CHECKSUM self-test (confirmed via the sibling T-unit
// game NBA Hangtime's real source, SRC/DIAG.ASM ~1690-1725: PROMCHIPS/IROMCHIPS_8MEG via
// ROMCHECK, bank-switched through SYSCTRL — sits directly beside the SRAMCHIPS test this
// core already passes, i.e. part of NORMAL POST, not a hidden test-menu-only routine) —
// with Powerup Test wrongly forced ON, the CPU would checksum the gfx ROM, which has never
// been loaded by any build so far (GFX_BYTES deferred/undersized) and would report an
// error, plausibly explaining the "ERRORS DETECTED" screen. Per-field gospel defaults, OR'd:
// TestSwitch(0x0001) | Counters=Two(0x0000) | Coinage=USA-1(0x007c) | CoinageSrc=CMOS(0x0000)
// | PowerupTest=Off(0x0000) | BillValidator=Off(0x0400) | AttractSound=On(0x1000)
// | Blood=On(0x4000) | Violence=On(0x8000) = 0xD47D field defaults. The three
// IPT_UNUSED bits 8/11/13 are IP_ACTIVE_LOW (midwunit.cpp:196,203,207 = 0x2900) and
// an inactive active-low input READS 1, so the LIVE port value = 0xD47D | 0x2900 =
// 0xFD7D — exactly what MAME measures on every idle DSW read (mame-gospel/trace/
// exp2b_iobreak.txt:3 off=0187FFA0 lastval=FD7D; freshreg.tr:45657 A0=FFFFFD7D
// right after the FFBA2190 DSW read). Leaving them 0 was wrong-by-measurement.
wire [15:0] dsw = test_switch ? (16'hFD7D & ~16'h0001) : 16'hFD7D;
`endif

wire [63:0] inputs = {dsw, in2, in1, in0};

////////////////////////////////////////////////////////////////////////////////
// GAME
////////////////////////////////////////////////////////////////////////////////
wire reset = RESET | status[0] | buttons[1] | ~locked;
reg  rst_pon = 1'b1;
always @(posedge clk_sys) rst_pon <= RESET | ~locked;   // power-on only (sound board full reset)
// P0022: TRUE power-on for the PERSISTENT SDRAM/download subsystem. ~locked (PLL) synchronized
// into clk_sys (2-FF, clean removal). It is LOW during ANY ROM download (which always follows
// PLL lock), so the capture path keeps running even if the framework holds RESET high across
// the download — the black-screen root cause was that RESET froze the whole SDRAM path. This
// does NOT include RESET (rst_pon does), which is the whole point: rst_pon would freeze too.
reg  sdram_por_m = 1'b1, sdram_por = 1'b1;
always @(posedge clk_sys) begin sdram_por_m <= ~locked; sdram_por <= sdram_por_m; end

always @(posedge clk_sys) begin
	if (sdram_por)
		game_profile <= DEFAULT_GAME_PROFILE;
	else if (profile_download && ioctl_wr && (ioctl_addr == 0)) begin
		case (ioctl_dout[2:0])
			3'd0, 3'd1, 3'd2, 3'd3, 3'd4, 3'd5, 3'd6:
				game_profile <= ioctl_dout[2:0];
			default:
				game_profile <= DEFAULT_GAME_PROFILE;
		endcase
	end
end

wire        nvram_busy;
wire        nvram_ext_en;
wire        nvram_ext_wr;
wire [15:0] nvram_ext_addr;
wire  [7:0] nvram_ext_wdata;
wire  [7:0] nvram_ext_rdata;
wire        nvram_cpu_write;
wire        nvram_dirty;

wolf_nvram_bridge #(.NVRAM_BYTES(49152)) u_nvram_bridge (
	.clk(clk_sys),
	.rst_pon(rst_pon),
	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_upload_req(ioctl_upload_req),
	.autosave(~status[13]), // option is displayed On first; status bit means Off
	.manual_save(status[14]),
	.clear_nvram(status[15]),
	.osd_status(OSD_STATUS),
	.cpu_write_pulse(nvram_cpu_write),
	.nvram_ext_en(nvram_ext_en),
	.nvram_ext_wr(nvram_ext_wr),
	.nvram_ext_addr(nvram_ext_addr),
	.nvram_ext_wdata(nvram_ext_wdata),
	.nvram_ext_rdata(nvram_ext_rdata),
	.nvram_busy(nvram_busy),
	.nvram_dirty(nvram_dirty)
);

reg [7:0] sw[2];
always @(posedge clk_sys)
	if (ioctl_wr && (ioctl_index == 254) && !ioctl_addr[24:1]) sw[ioctl_addr[0]] <= ioctl_dout;

// Core-top selection: the real Y-unit core, or (with +define+DIAG_SDRAM) the self-contained
// SDRAM loopback diagnostic (rtl/diag/smashtv_diag_top.sv) — same ports, so no rewiring. The
// diagnostic discards the CPU and paints the SDRAM read/write self-test result to the screen.
`ifdef DCS_ONLY_TEST
assign yt_ioctl_wait = 1'b0;
assign gfx_dl_ack = 1'b1;
assign gfx_writer_idle = 1'b1;
assign dbg_gfx_wbeats = 26'd0;
assign dbg_gfx_srd = 16'd0;
assign dbg_gfx_cgrd = 16'd0;
assign {SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = 7'b0001111;
assign SDRAM_A = 13'd0;
assign SDRAM_BA = 2'd0;
assign SDRAM_DQ = 16'hzzzz;

wire        dcs_rom_req;
wire [18:0] dcs_rom_addr;
wire        dcs_rom_rdy;
wire [63:0] dcs_rom_q;
wire        dcs_dl_busy;
wolf_dcs_ddr_top u_dcs_ddr (
	.clk(clk_sys),
	.sdram_por(sdram_por),
	.dl_wr(dcsdl_dl_wr),
	.dl_addr(dcsdl_dl_addr[21:0]),
	.dl_data(dcsdl_dl_data),
	.dl_ack(dcs_dl_ack),
	.dl_busy(dcs_dl_busy),
	.rom_req(dcs_rom_req),
	.rom_addr(dcs_rom_addr),
	.rom_rdy(dcs_rom_rdy),
	.rom_q(dcs_rom_q),
	.ddram_addr(DDRAM_ADDR),
	.ddram_burstcnt(DDRAM_BURSTCNT),
	.ddram_rd(DDRAM_RD),
	.ddram_we(DDRAM_WE),
	.ddram_din(DDRAM_DIN),
	.ddram_be(DDRAM_BE),
	.ddram_busy(DDRAM_BUSY),
	.ddram_dout(DDRAM_DOUT),
	.ddram_dout_ready(DDRAM_DOUT_READY)
);

reg dcs_download_seen = 1'b0;
reg [23:0] dcs_start_delay = 24'd0;
wire dcs_rom_drained = dcs_download_seen & ~ioctl_download & dcs_fifo_idle & ~dcs_dl_busy;
wire dcs_start_ready = dcs_rom_drained & (dcs_start_delay == 24'd9600000);
always @(posedge clk_sys) begin
	if (sdram_por) begin
		dcs_download_seen <= 1'b0;
		dcs_start_delay <= 24'd0;
	end else begin
		if (dcs_download & ioctl_wr)
			dcs_download_seen <= 1'b1;
		if (reset | !dcs_rom_drained)
			dcs_start_delay <= 24'd0;
		else if (dcs_start_delay != 24'd9600000)
			dcs_start_delay <= dcs_start_delay + 24'd1;
	end
end

wire [7:0] dcs_host_resp_data;
wire [15:0] dcs_host_status;
wire signed [15:0] dcs_only_audio;
wire dcs_dbg_valid;
wire dcs_dbg_unimpl;
wire dcs_dbg_pcm_push;
wire [13:0] dcs_dbg_pc;
reg [31:0] dcs_retired = 32'd0;
reg        dcs_host_reset = 1'b0;
reg        dcs_host_cmd_wr = 1'b0;
reg [7:0]  dcs_host_cmd_data = 8'h00;

// Standalone DCS bring-up must reproduce the board events captured by the
// bit-exact MAME trace. The previous wall-clock sequencer skipped both warm
// resets and the two mailbox-initialization writes, so the firmware consumed
// the later track command but never armed its PCM path.
always @(posedge clk_sys) begin
	dcs_host_reset <= 1'b0;
	dcs_host_cmd_wr <= 1'b0;
	if (reset | ~dcs_start_ready) begin
		dcs_retired <= 32'd0;
		dcs_host_cmd_data <= 8'h00;
	end else if (dcs_dbg_valid) begin
		dcs_retired <= dcs_retired + 32'd1;
		case (dcs_retired + 32'd1)
			32'd37,
			32'd1043886: dcs_host_reset <= 1'b1;
			32'd1075988,
			32'd1076027: begin dcs_host_cmd_data <= 8'h00; dcs_host_cmd_wr <= 1'b1; end
			32'd2700000: begin dcs_host_cmd_data <= 8'h55; dcs_host_cmd_wr <= 1'b1; end
			32'd2720000: begin dcs_host_cmd_data <= 8'hAA; dcs_host_cmd_wr <= 1'b1; end
			32'd2740000: begin dcs_host_cmd_data <= 8'hFF; dcs_host_cmd_wr <= 1'b1; end
			32'd2760000: begin dcs_host_cmd_data <= 8'h00; dcs_host_cmd_wr <= 1'b1; end
			// DCSExplorer catalogues command 0005 as a 26.642-second looping
			// music track. Use it for the hardware audio proof: unlike the old
			// 046A effect (61 ms), it cannot be missed while the core boots.
			32'd2800000: begin dcs_host_cmd_data <= 8'h00; dcs_host_cmd_wr <= 1'b1; end
			32'd2820000: begin dcs_host_cmd_data <= 8'h05; dcs_host_cmd_wr <= 1'b1; end
			default: ;
		endcase
	end
end

wolf_dcs_board u_dcs_only_board (
	.clk(clk_sys),
	.rst(reset | ~dcs_start_ready),
	.host_reset(dcs_host_reset),
	.host_cmd_wr(dcs_host_cmd_wr),
	.host_cmd_data(dcs_host_cmd_data),
	.host_resp_rd(1'b0),
	.host_resp_data(dcs_host_resp_data),
	.host_status(dcs_host_status),
	.rom_req(dcs_rom_req),
	.rom_addr(dcs_rom_addr),
	.rom_rdy(dcs_rom_rdy),
	.rom_q(dcs_rom_q),
	.audio(dcs_only_audio),
	.dbg_valid(dcs_dbg_valid),
	.dbg_unimpl(dcs_dbg_unimpl),
	.dbg_pcm_push(dcs_dbg_pcm_push),
	.dbg_pc(dcs_dbg_pc)
);

reg dcs_cmd_full_seen = 1'b0;
always @(posedge clk_sys) begin
	if (sdram_por) begin
		dcs_diag_stage <= 8'd0;
		dcs_cmd_full_seen <= 1'b0;
	end else begin
		if (dcs_download_seen) dcs_diag_stage[0] <= 1'b1;
		if (dcs_rom_drained)   dcs_diag_stage[1] <= 1'b1;
		if (dcs_start_ready)   dcs_diag_stage[2] <= 1'b1;
		if (dcs_rom_req)       dcs_diag_stage[3] <= 1'b1;
		if (dcs_rom_rdy)       dcs_diag_stage[4] <= 1'b1;
		if (dcs_dbg_valid)     dcs_diag_stage[5] <= 1'b1;
		if (!dcs_host_status[11]) dcs_cmd_full_seen <= 1'b1;
		if (dcs_cmd_full_seen && dcs_host_status[11]) dcs_diag_stage[6] <= 1'b1;
		// The final block proves that a nonzero DCS sample reached the board
		// output. A raw PCM push alone is insufficient: it may be the trailing
		// zero sample of a half-buffer.
		if (dcs_only_audio != 16'sh0000) dcs_diag_stage[7] <= 1'b1;
	end
end

reg [15:0] dcs_tone_div = 16'd0;
always @(posedge clk_sys) dcs_tone_div <= dcs_tone_div + 16'd1;
wire signed [15:0] dcs_test_audio = status[2] ? (dcs_tone_div[15] ? 16'sh2800 : -16'sh2800) : dcs_only_audio;
assign AUDIO_L = dcs_test_audio;
assign AUDIO_R = dcs_test_audio;

assign {r,g,b,hsync,vsync,hblank,vblank,de} = '0;
assign {dbg_pc, dbg_culprit_pc, dbg_derail_pc, dbg_iol_drop, dbg_iol_wrs} = '0;
assign {dbg_illegal, dbg_core_rst, dbg_sdram_ready, dbg_unp_done, dbg_cpu_req, dbg_mem_ack,
        dbg_int1, dbg_vblank_irq, dbg_cpu_ce, dbg_derailed, dbg_culprit_instr} = '0;
assign {ov_r,ov_g,ov_b,ov_hs,ov_vs,ov_hb,ov_vb,ov_de} = '0;
`else
`ifdef NBA_HANGTIME
localparam logic [127:0] GAME_PIC_RESPONSE =
	128'h0000_4A0E_A018_4580_0614_C3B2_0301_8444; // accepted game-528 dev PIC
`elsif OPEN_ICE
localparam logic [127:0] GAME_PIC_RESPONSE =
	128'h0000_4A0E_A018_4580_0614_C3B2_0301_8444; // accepted game-528 dev PIC
`elsif WWF_MANIA
localparam logic [127:0] GAME_PIC_RESPONSE =
	128'h0000_4A0E_A018_4580_0614_C3B2_0301_8444; // accepted game-528 dev PIC
`elsif MK3
localparam logic [127:0] GAME_PIC_RESPONSE =
	128'h0000_4A0E_A018_4580_0614_C3B2_0301_8444; // accepted game-528 dev PIC
`elsif RAMPAGE_WT
// rmpgwt = wunit_picemu serial 465 (midwunit.cpp:1767; dump 465_rampage_wt.u64).
// 16-byte table captured live from MAME 0.280 (two fresh-NVRAM runs byte-identical):
// idx0..F = 5B 08 03 10 10 41 0D D7 61 7F 19 25 CD 69 09 8C, byte0 in [7:0].
// Gospel: D:/deck/fpga/rampageworldtour/gospel/rmpgwt_pic_response_table.txt.
localparam logic [127:0] GAME_PIC_RESPONSE =
	128'h8C09_69CD_2519_7F61_D70D_4110_1003_085B; // captured RWT 465 picemu
`else
localparam logic [127:0] GAME_PIC_RESPONSE =
	128'h2B1E_4A0E_0217_6C60_B408_2509_DB01_9AF6; // captured UMK3 PIC
`endif
`ifdef WWF_MANIA
localparam bit GAME_WWF_IO_SHUFFLE = 1'b1;
`else
localparam bit GAME_WWF_IO_SHUFFLE = 1'b0;
`endif
// Preserve the Wolf ASIC/MAME completion cadence that feeds each game's
// software DMA queue. Page publication remains independently fenced on the
// renderer and downstream VRAM write drain inside wolf_video/wolf_dma.
localparam bit GAME_TIMED_IRQ_PUMP = 1'b1;
`ifdef OPEN_ICE
localparam bit GAME_PIC_STATUS_DELAY = 1'b0;
`elsif WWF_MANIA
localparam bit GAME_PIC_STATUS_DELAY = 1'b0;
`elsif MK3
localparam bit GAME_PIC_STATUS_DELAY = 1'b0;
`else
// Preserve the cabinet-confirmed timing of every established build profile,
// including NBA Hangtime, Rampage, and UMK3.
localparam bit GAME_PIC_STATUS_DELAY = 1'b1;
`endif
wolf_top #(
	.ROM_HEX(""),
	.PIC_RESPONSE_BYTES(GAME_PIC_RESPONSE),
	.WWF_IO_SHUFFLE(GAME_WWF_IO_SHUFFLE),
	.PIC_STATUS_DELAY(GAME_PIC_STATUS_DELAY),
	.TIMED_IRQ_PUMP(GAME_TIMED_IRQ_PUMP)
) wolf_top
(
	.clk(clk_sys),
	.clk_cpu(clk_cpu),
	.ce_pix(ce_pix),
	.clk_snd(clk_snd),
	.rst(reset),
	.rst_pon(rst_pon),
	.sdram_por(sdram_por),

	.inputs(inputs),
	.status(status),
	.game_profile(active_game_profile),
	.nvram_busy(nvram_busy),
	.nvram_ext_en(nvram_ext_en),
	.nvram_ext_wr(nvram_ext_wr),
	.nvram_ext_addr(nvram_ext_addr),
	.nvram_ext_wdata(nvram_ext_wdata),
	.nvram_ext_rdata(nvram_ext_rdata),
	.nvram_cpu_write(nvram_cpu_write),

	.ioctl_download(game_download),
	.ioctl_wr(yt_ioctl_wr),
	.ioctl_addr(yt_ioctl_addr),
	.ioctl_dout(yt_ioctl_dout),
	.ioctl_be(yt_ioctl_be),
	.ioctl_wait(yt_ioctl_wait),

	.snd_dl_wr(1'b0),
	.snd_dl_addr(18'd0),
	.snd_dl_data(8'd0),
	// Hold the Wolf/DCS reset through the outer FIFO tail. The inner DDR
	// writer's dcs_dl_busy covers the final accepted byte; together these
	// terms prevent reset chatter between packed sound-ROM beats.
	.dcs_dl_active(dcs_download | ~dcs_fifo_idle),
	.dcs_dl_wr(dcsdl_dl_wr),
	.dcs_dl_addr(dcsdl_dl_addr[21:0]),
	.dcs_dl_data(dcsdl_dl_data),
	.dcs_dl_ack(dcs_dl_ack),

	.gfx_dl_wr(gfxdl_dl_wr),
	.gfx_dl_addr(gfxdl_dl_addr),
	.gfx_dl_data(gfxdl_dl_data),
	.gfx_dl_ack(gfx_dl_ack),
	.gfx_dl_idle(gfx_writer_idle),
	.dbg_gfx_wbeats(dbg_gfx_wbeats),
	.dbg_gfx_srd(dbg_gfx_srd),
	.dbg_gfx_cgrd(dbg_gfx_cgrd),
	.dbg_dma_q_overflow(dbg_dma_q_overflow),
	.dbg_dma_q_highwater(dbg_dma_q_highwater),

	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_A(SDRAM_A),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_nWE(SDRAM_nWE),
	.SDRAM_CKE(SDRAM_CKE),

	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),

	.vid_r(r), .vid_g(g), .vid_b(b),
	.hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank), .de(de),

	.audio_l(AUDIO_L), .audio_r(AUDIO_R),

	.pc_dbg(dbg_pc), .illegal_dbg(dbg_illegal),
	.dbg_core_rst(dbg_core_rst), .dbg_sdram_ready(dbg_sdram_ready), .dbg_unp_done(dbg_unp_done),
	.dbg_cpu_req(dbg_cpu_req), .dbg_mem_ack(dbg_mem_ack),
	.dbg_int1(dbg_int1), .dbg_vblank_irq(dbg_vblank_irq), .dbg_cpu_ce(dbg_cpu_ce),
	.dbg_derailed(dbg_derailed), .dbg_culprit_pc(dbg_culprit_pc),
	.dbg_culprit_instr(dbg_culprit_instr), .dbg_derail_pc(dbg_derail_pc),
	.dbg_iol_drop(dbg_iol_drop), .dbg_iol_wrs(dbg_iol_wrs)
);

// ---- boot-instrument overlay (+define+DIAG_BOOT): paints the real core's boot state ----
`ifdef DIAG_BOOT
smashtv_diag2_overlay u_diag2 (
	.clk(clk_sys), .ce_pix(ce_pix), .rst(reset),
	.core_rst(dbg_core_rst), .sdram_ready(dbg_sdram_ready), .unp_done(dbg_unp_done),
	.ioctl_download(game_download), .cpu_req(dbg_cpu_req), .mem_ack(dbg_mem_ack),
	.int1(dbg_int1), .vblank_irq(dbg_vblank_irq), .cpu_ce(dbg_cpu_ce),
	.pc(dbg_pc), .illegal(dbg_illegal),
	.derailed(dbg_derailed), .culprit_pc(dbg_culprit_pc),
	// P0021 download-path disambiguation on the (idle, no-derail) rows 2 & 3:
	//   row2 = words ACCEPTED into the yunit_top FIFO / 16  (0 on HW = FIFO got nothing)
	//   row3 = {rst_during_dl, 0, emu remap-FSM emit count} — 8xxxxxxx=(b) reset froze FIFO,
	//          000xxxxx>0=FSM fired (wiring break if row2 still 0), 00000000=(a) FSM never fired
`ifdef DIAG_ILLEGAL
	// First illegal decode: exact opcode address, opcode word, and already-advanced PC.
	.culprit_instr(dbg_culprit_instr),
	.derail_pc(dbg_derail_pc),
`elsif DIAG_GFX
	// gfx-DDR3 pipeline audit variant: row2 = gfx bytes pushed >>10 (full download shows
	// 0x5000); row3 = {ioctl index seen (expect 01), DDR3 byte-writes >>10 (full = 0x5000,
	// same as row2 when nothing dropped), blitter reads low nibble, cgfx reads low nibble
	// (both ticking = read paths live)}.
	.culprit_instr(gfx_push_cnt[25:10]),
	.derail_pc({gfx_idx_seen, dbg_gfx_wbeats[25:10], dbg_gfx_srd[3:0], dbg_gfx_cgrd[3:0]}),
`elsif DIAG_FLIP
	// FLIP-race: row2 = {13'd0, raced_sticky, busy_ever, blit_busy_now};
	//   row3 = busy_total (free-running blit_busy-high cycle count; 00000000 = blit_busy STUCK LOW).
	.culprit_instr(dbg_culprit_instr),
	.derail_pc(dbg_derail_pc),
`elsif DIAG_SRT
	// SRT sideband: row1 = {latches_last_frame, transfers_last_frame} (DIRQ expectation
	// 0001|007F); row2 = {14'd0, srt_seen_sticky (bit11-seen proxy), srt_now};
	// row3 = {latch_total, transfer_total}. Computed in wolf_top's DIAG_SRT arm.
	.culprit_instr(dbg_culprit_instr),
	.derail_pc(dbg_derail_pc),
`else
	.culprit_instr(dbg_iol_wrs[19:4]), .derail_pc(dl_diag),
`endif
	// game video in -> overlay COMPOSITES (diag in top-left quadrant, game shows elsewhere)
	.g_r(r), .g_g(g), .g_b(b),
	.g_hs(hsync), .g_vs(vsync), .g_hb(hblank), .g_vb(vblank), .g_de(de),
	.vid_r(ov_r), .vid_g(ov_g), .vid_b(ov_b),
	.hsync(ov_hs), .vsync(ov_vs), .hblank(ov_hb), .vblank(ov_vb), .de(ov_de));
`elsif DIAG_GEOM
// ---- geometry instrument (+define+DIAG_GEOM): screen-as-ruler for the squished-screen
// localization (active-width / graticule / content-extent). Self-contained: only the core raster.
wolf_diag_geom_overlay u_diag_geom (
	.clk(clk_sys), .ce_pix(ce_pix), .rst(reset),
	.g_r(r), .g_g(g), .g_b(b),
	.g_hs(hsync), .g_vs(vsync), .g_hb(hblank), .g_vb(vblank), .g_de(de),
	.vid_r(ov_r), .vid_g(ov_g), .vid_b(ov_b),
	.hsync(ov_hs), .vsync(ov_vs), .hblank(ov_hb), .vblank(ov_vb), .de(ov_de));
`else
assign {ov_r,ov_g,ov_b,ov_hs,ov_vs,ov_hb,ov_vb,ov_de} = '0;
`endif
`endif

endmodule
