// yunit_gfx_unpack.sv — Phase 6 W5: boot-time gfx planar->flat unpacker.
//
// The MRA delivers the raw Y-unit gfx ROMs as MAME's 6bpp *planar* layout (three
// 2-bit planes), but the blitter/CPU read UNPACKED gfx (one 6-bit pixel per byte,
// 2 pixels per 16-bit SDRAM word @ GFXW_BASE). MAME does this unpack in software at
// load time (init_gfxrom, midyunit_m.cpp); an MRA can't, so we do it on-chip once,
// right after the ROM download, before the CPU is released.
//
// Layout: the loader writes the three planes CONTIGUOUSLY into an SDRAM scratch
// region — plane0 @ SCRATCH_WBASE, plane1 @ +PLANE_WORDS, plane2 @ +2*PLANE_WORDS
// (each plane = PLANE_WORDS 16-bit words = 0x60000 bytes). For each scratch word w
// (holding plane bytes 2w and 2w+1) we read the same word from all three planes and
// emit 8 pixels (bytes 2w,2w+1 x 4 px/byte) as 4 flat words @ GFXW_BASE + 4w.
//
// Pixel math (verbatim from make_gfx_hex.py / init_gfxrom 6bpp):
//   pixel = plane0_bits | plane1_bits<<2 | plane2_bits<<4,  bits = (byte >> 2*m) & 3
// with m = pixel & 3 the 2-bit group within the plane byte.
`timescale 1ns/1ps
`default_nettype none
module yunit_gfx_unpack #(
  parameter int SD_AW = 25,
  parameter [SD_AW-1:0] SCRATCH_WBASE = 25'h120000,  // plane0 word base in SDRAM
  parameter [SD_AW-1:0] GFXW_BASE     = 25'h000000,  // flat-gfx word base
  parameter [23:0]      PLANE_WORDS   = 24'h30000    // words per plane (0x60000 bytes)
)(
  input  logic clk,
  input  logic rst,
  input  logic start,          // 1-cycle pulse: begin the pass
  output logic busy,
  output logic done,           // held high once the whole pass is complete
  // arbiter unp channel (word master; rd XOR wr per grant, held until ack)
  output logic             unp_rd,
  output logic             unp_wr,
  output logic [SD_AW-1:0] unp_addr,
  output logic [15:0]      unp_din,
  input  logic [15:0]      unp_dout,
  input  logic             unp_ack
);
  // one unpacked 6-bit pixel from the three plane bytes at group m
  function automatic [7:0] mkpix(input [7:0] b0, input [7:0] b1, input [7:0] b2,
                                 input [1:0] m);
    logic [1:0] d0, d1, d2;
    begin
      d0 = (b0 >> {m, 1'b0}) & 2'b11;   // >> 2*m
      d1 = (b1 >> {m, 1'b0}) & 2'b11;
      d2 = (b2 >> {m, 1'b0}) & 2'b11;
      mkpix = {2'b00, d2, d1, d0};      // d0 | d1<<2 | d2<<4
    end
  endfunction

  typedef enum logic [3:0] {IDLE, RD0, RD1, RD2, WR0, WR1, WR2, WR3, NXT, FINI} st_t;
  st_t st;
  logic [23:0] w;                       // current plane-word index
  logic [15:0] p0, p1;                  // plane0/1 words (plane2 taken from unp_dout)
  logic [15:0] fw0, fw1, fw2, fw3;      // the 4 flat words to write

  wire [25:0] fourw     = {w, 2'b00};                // 4*w (26-bit intermediate)
  wire [SD_AW-1:0] a0    = SCRATCH_WBASE + {{(SD_AW-24){1'b0}}, w};
  wire [SD_AW-1:0] a1    = SCRATCH_WBASE +   PLANE_WORDS + {{(SD_AW-24){1'b0}}, w};
  wire [SD_AW-1:0] a2    = SCRATCH_WBASE + 2*PLANE_WORDS + {{(SD_AW-24){1'b0}}, w};
  wire [SD_AW-1:0] wbase = GFXW_BASE + fourw[SD_AW-1:0];  // flat gfx word = 4*w (fits: <2^25)

  always_comb begin
    unp_rd = 1'b0; unp_wr = 1'b0; unp_addr = '0; unp_din = 16'h0;
    case (st)
      RD0: begin unp_rd = 1'b1; unp_addr = a0; end
      RD1: begin unp_rd = 1'b1; unp_addr = a1; end
      RD2: begin unp_rd = 1'b1; unp_addr = a2; end
      WR0: begin unp_wr = 1'b1; unp_addr = wbase;         unp_din = fw0; end
      WR1: begin unp_wr = 1'b1; unp_addr = wbase + 25'd1; unp_din = fw1; end
      WR2: begin unp_wr = 1'b1; unp_addr = wbase + 25'd2; unp_din = fw2; end
      WR3: begin unp_wr = 1'b1; unp_addr = wbase + 25'd3; unp_din = fw3; end
      default: ;
    endcase
  end

  assign busy = (st != IDLE) && (st != FINI);
  assign done = (st == FINI);

  always_ff @(posedge clk) begin
    if (rst) begin
      st <= IDLE; w <= 24'd0;
    end else begin
      case (st)
        IDLE: if (start) begin w <= 24'd0; st <= RD0; end
        RD0:  if (unp_ack) begin p0 <= unp_dout; st <= RD1; end
        RD1:  if (unp_ack) begin p1 <= unp_dout; st <= RD2; end
        RD2:  if (unp_ack) begin
                // plane2 = unp_dout (this cycle); p0/p1 already latched
                fw0 <= {mkpix(p0[ 7:0], p1[ 7:0], unp_dout[ 7:0], 2'd1),
                        mkpix(p0[ 7:0], p1[ 7:0], unp_dout[ 7:0], 2'd0)};
                fw1 <= {mkpix(p0[ 7:0], p1[ 7:0], unp_dout[ 7:0], 2'd3),
                        mkpix(p0[ 7:0], p1[ 7:0], unp_dout[ 7:0], 2'd2)};
                fw2 <= {mkpix(p0[15:8], p1[15:8], unp_dout[15:8], 2'd1),
                        mkpix(p0[15:8], p1[15:8], unp_dout[15:8], 2'd0)};
                fw3 <= {mkpix(p0[15:8], p1[15:8], unp_dout[15:8], 2'd3),
                        mkpix(p0[15:8], p1[15:8], unp_dout[15:8], 2'd2)};
                st <= WR0;
              end
        WR0:  if (unp_ack) st <= WR1;
        WR1:  if (unp_ack) st <= WR2;
        WR2:  if (unp_ack) st <= WR3;
        WR3:  if (unp_ack) st <= NXT;
        NXT:  if (w == PLANE_WORDS - 24'd1) st <= FINI;
              else begin w <= w + 24'd1; st <= RD0; end
        FINI: st <= FINI;
        default: st <= IDLE;
      endcase
    end
  end
endmodule
`default_nettype wire
