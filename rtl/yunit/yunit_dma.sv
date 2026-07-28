// yunit_dma.sv — Williams Y-unit sprite DMA blitter.
//
// Faithful RTL port of MAME's midyunit blitter:
//   register set + trigger : docs/mame-ref/midyunit_v.cpp:422 (dma_w)
//   clip / flip setup       : docs/mame-ref/midyunit_v.cpp:456-518
//   per-pixel draw modes     : docs/mame-ref/midyunit_v.cpp:262 (dma_draw)
//   completion IRQ (LINT1)   : docs/mame-ref/midyunit_v.cpp:370 (dma_callback)
//
// Boundary: reads ONE unpacked pixel byte per source step from an external
// gfx-read path (2-bit-plane→6-bit unpack lives in yunit_mem/gfx, Phase 3).
// Writes 16-bit words into the 512x512 frame buffer. The palette high-byte is
// folded into the written word here (matching dma_draw): the frame buffer
// stores {palette[7:0], pixel[7:0]}; pen_map6 runs at scanout.
//
// Faithfulness note: MAME overwrites m_dma_state.offset with
// (gfxoffset-0x02000000) at draw time (midyunit_v.cpp:518), discarding the
// clip-time source-offset adjustments at :483/:496/:508. We reproduce MAME's
// observable behaviour: clipping adjusts width/height/xpos/ypos only.
//
// Verified by sim/tb_yunit_dma.sv (Icarus). Constant bit/part-selects are
// hoisted to continuous-assign wires so the module is portable across Icarus,
// Questa, and Quartus (Icarus miscompiles constant selects inside always).

`default_nettype none

module yunit_dma
  import yunit_pkg::*;
(
  input  logic        clk,
  input  logic        rst,          // sync, active-high

  // CPU register interface (from yunit_mem; addr = blitter reg index 0..15).
  input  logic        reg_we,
  input  logic  [3:0] reg_addr,
  input  logic [15:0] reg_wdata,
  output logic [15:0] reg_rdata,     // dma_r: returns register file

  // Unpacked-gfx source read: 1 byte/pixel at linear byte index src_addr.
  output logic        src_req,
  output logic [23:0] src_addr,
  input  logic  [7:0] src_data,
  input  logic        src_ack,

  // Frame-buffer write: 16-bit word at word index (ty*512 + tx).
  output logic        fb_we,
  output logic [FB_ADDR_W-1:0] fb_addr,
  output logic [15:0] fb_wdata,
  input  logic        fb_ack,        // write accepted/complete. Tie 1'b1 for a 1-cycle
                                      // (BRAM) write; the SDRAM path drives it multi-cycle
                                      // so the blitter self-paces (no fire-and-forget drops).

  // Status
  output logic        busy,          // COMMAND bit15 as seen by the CPU
  output logic        blit_irq,      // -> 34010 LINT1; set on completion, cleared on COMMAND write
  output logic [15:0] dma_palette    // DMA_PALETTE reg -> yunit_mem CPU vram_w byte-lane
);

  // ---- Register file ----------------------------------------------------
  logic [15:0] regf [DMA_NREGS];
  logic        busy_r;

  // Constant-select helpers (continuous assigns; safe on Icarus).
  wire [15:0] cmd_reg    = regf[DMA_COMMAND];
  wire        flipx_w    = cmd_reg[DMA_CMD_FLIPX_BIT];
  wire [3:0]  mode_w     = cmd_reg[3:0];
  wire [7:0]  pal_lo     = regf[DMA_PALETTE][7:0];
  wire [7:0]  col_lo     = regf[DMA_COLOR][7:0];
  wire        wdata_trig = reg_wdata[DMA_CMD_TRIG_BIT];

  assign busy        = busy_r;
  assign dma_palette = regf[DMA_PALETTE];
  // CPU poll of COMMAND sees live busy in bit15; other regs read back directly.
  assign reg_rdata = (reg_addr == DMA_COMMAND) ? {busy_r, cmd_reg[14:0]} : regf[reg_addr];

  // ---- FSM --------------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE, S_SETUP, S_ROW, S_FETCH, S_WRITE, S_DONE
  } state_t;
  state_t state, state_n;

  // Latched, clipped blit parameters (set at S_SETUP).
  logic  [3:0]        mode_c;
  logic               flipx_c;
  logic               readmode_c;
  logic signed [11:0] width_c, height_c;
  logic signed [11:0] xpos_c, ypos_c;
  logic signed [31:0] rowbytes_c;
  logic [15:0]        pal16_c, color16_c;

  // Running blit state.
  logic signed [11:0] row_i, col_i, tx;
  logic        [8:0]  ty;
  logic signed [31:0] cur_off, o_ptr;
  logic        [7:0]  px;

  // ---- Combinational clip/flip setup (MAME dma_w:456-518) --------------
  logic signed [31:0] rb_in, xs_in, ys_in;
  logic        [15:0] w_in, h_in;
  logic        [31:0] gfxoff0, gfxoff1, gfxoff2;
  logic signed [31:0] rb_adj, xpos0;
  logic signed [31:0] ypos1, height1a, height1;
  logic signed [31:0] xpos_f, width_f;
  logic signed [31:0] offbytes_c;

  always_comb begin
    rb_in   = $signed(regf[DMA_ROWBYTES]);
    xs_in   = $signed(regf[DMA_XSTART]);
    ys_in   = $signed(regf[DMA_YSTART]);
    w_in    = regf[DMA_WIDTH];
    h_in    = regf[DMA_HEIGHT];
    gfxoff0 = {regf[DMA_OFFSETHI], regf[DMA_OFFSETLO]};

    rb_adj  = flipx_w ? ((rb_in - $signed({16'd0, w_in}) + 32'sd3) & ~32'sd3)
                      : ((rb_in + $signed({16'd0, w_in}) + 32'sd3) & ~32'sd3);
    xpos0   = flipx_w ? (xs_in + $signed({16'd0, w_in}) - 32'sd1) : xs_in;
    gfxoff1 = flipx_w ? (gfxoff0 - (({16'd0, w_in} - 32'd1) << 3)) : gfxoff0;

    ypos1    = (ys_in < 0) ? 32'sd0 : ys_in;
    height1a = (ys_in < 0) ? ($signed({16'd0, h_in}) + ys_in) : $signed({16'd0, h_in});
    height1  = ((ypos1 + height1a) > 32'sd512) ? (32'sd512 - ypos1) : height1a;

    if (!flipx_w) begin
      if (xpos0 < 0) begin width_f = $signed({16'd0, w_in}) + xpos0; xpos_f = 32'sd0; end
      else           begin width_f = $signed({16'd0, w_in});         xpos_f = xpos0;  end
      if ((xpos_f + width_f) > 32'sd512) width_f = 32'sd512 - xpos_f;
    end else begin
      if (xpos0 >= 32'sd512) begin width_f = $signed({16'd0, w_in}) - (xpos0 - 32'sd511); xpos_f = 32'sd511; end
      else                   begin width_f = $signed({16'd0, w_in});                      xpos_f = xpos0;    end
      if ((xpos_f - width_f) < 0) width_f = xpos_f;
    end

    gfxoff2    = (gfxoff1 < 32'h0200_0000) ? (gfxoff1 + 32'h0200_0000) : gfxoff1;
    offbytes_c = ($signed(gfxoff2) - 32'sh0200_0000) >>> 3;   // bit -> byte
  end

  // Narrowed clip results as wires (avoid constant selects inside always).
  wire [11:0] width12  = width_f[11:0];
  wire [11:0] height12 = height1[11:0];
  wire [11:0] xpos12   = xpos_f[11:0];
  wire [11:0] ypos12   = ypos1[11:0];
  wire        readmode_w = (mode_w >= 4'h1) && (mode_w <= 4'hB);

  // ---- Per-pixel draw decision (MAME dma_draw:294-357) -----------------
  logic        pix_we;
  logic [15:0] pix_data;
  always_comb begin
    pix_we   = 1'b0;
    pix_data = 16'h0000;
    unique case (mode_c)
      4'h0: ;
      4'h1: begin pix_we = (px == 8'd0); pix_data = pal16_c;               end
      4'h2: begin pix_we = (px != 8'd0); pix_data = pal16_c | {8'd0, px};  end
      4'h3: begin pix_we = 1'b1;         pix_data = pal16_c | {8'd0, px};  end
      4'h4, 4'h5: begin pix_we = (px == 8'd0); pix_data = color16_c;       end
      4'h6, 4'h7: begin pix_we = 1'b1; pix_data = (px == 8'd0) ? color16_c : (pal16_c | {8'd0, px}); end
      4'h8, 4'ha: begin pix_we = (px != 8'd0); pix_data = color16_c;       end
      4'h9, 4'hb: begin pix_we = 1'b1; pix_data = (px != 8'd0) ? color16_c : (pal16_c | {8'd0, px}); end
      default:    begin pix_we = 1'b1; pix_data = color16_c;               end // 0xC..0xF
    endcase
  end

  // overrun guard (MAME dma_draw:290). MAME checks each row's OWN base once
  // (`o` is latched before `offset += rowbytes`); cur_off equals that base only
  // during the S_ROW decision cycle — by S_FETCH/S_WRITE it has already
  // advanced to the NEXT row's base, so this wire must gate S_ROW ONLY. (Bug
  // P0018: it was also ANDed into the S_WRITE fb write; a row whose SUCCESSOR
  // row-base crossed 0x06000000 had all its writes falsely suppressed —
  // caught by tb_yunit_dma_matrix case E9.)
  wire row_overrun = ($unsigned(cur_off) >= 32'h0600_0000) && (mode_c < 4'hC);

  // dest word index for the current pixel
  wire [8:0]  tx9     = tx[8:0];
  wire [8:0]  ty_next = ypos_c[8:0] + row_i[8:0];

  // ---- next-state ------------------------------------------------------
  always_comb begin
    state_n = state;
    unique case (state)
      S_IDLE:  if (reg_we && reg_addr == DMA_COMMAND && wdata_trig) state_n = S_SETUP;
      S_SETUP: if (height1 <= 0 || width_f <= 0) state_n = S_DONE; else state_n = S_ROW;
      S_ROW:   if (row_i >= height_c) state_n = S_DONE;
               else if (row_overrun)  state_n = S_ROW;
               else                   state_n = S_FETCH;
      S_FETCH: if (!readmode_c)  state_n = S_WRITE;
               else if (src_ack) state_n = S_WRITE;
      // Wait for the framebuffer write to be accepted (fb_ack) before advancing — the
      // SDRAM write is multi-cycle. With fb_ack tied high (BRAM), this never stalls.
      // A masked pixel (!pix_we) writes nothing, so it advances immediately.
      S_WRITE: if (pix_we && !fb_ack) state_n = S_WRITE;
               else if (col_i >= (width_c - 12'sd1)) state_n = S_ROW; else state_n = S_FETCH;
      S_DONE:  state_n = S_IDLE;
      default: state_n = S_IDLE;
    endcase
  end

  assign src_req  = (state == S_FETCH) && readmode_c;
  assign src_addr = o_ptr[23:0];

  // ---- registers -------------------------------------------------------
  integer i;
  always_ff @(posedge clk) begin
    if (rst) begin
      state    <= S_IDLE;
      fb_we    <= 1'b0;
      blit_irq <= 1'b0;
      busy_r   <= 1'b0;
      for (i = 0; i < DMA_NREGS; i = i + 1) regf[i] <= 16'h0000;
    end else begin
      state <= state_n;
      fb_we <= 1'b0;

      if (reg_we) begin
        regf[reg_addr] <= reg_wdata;
        if (reg_addr == DMA_COMMAND) begin
          blit_irq <= 1'b0;             // MAME: CLEAR_LINE on COMMAND write
          if (state == S_IDLE) busy_r <= wdata_trig;
        end
      end

      unique case (state)
        S_SETUP: begin
          mode_c     <= mode_w;
          flipx_c    <= flipx_w;
          readmode_c <= readmode_w;
          width_c    <= $signed(width12);
          height_c   <= $signed(height12);
          xpos_c     <= $signed(xpos12);
          ypos_c     <= $signed(ypos12);
          rowbytes_c <= rb_adj;
          pal16_c    <= {pal_lo, 8'h00};
          color16_c  <= {pal_lo, col_lo};
          row_i      <= 12'sd0;
          cur_off    <= offbytes_c;
        end

        S_ROW: begin
          ty    <= ty_next;              // low 9 bits = MAME &0x1ff
          tx    <= xpos_c;
          col_i <= 12'sd0;
          o_ptr <= cur_off;
          if (row_i < height_c) begin
            cur_off <= cur_off + rowbytes_c;
            row_i   <= row_i + 12'sd1;
          end
        end

        S_FETCH: begin
          if (readmode_c && src_ack) px <= src_data;
        end

        S_WRITE: begin
          // No row_overrun term here: overrun rows never leave S_ROW, and by
          // this state cur_off is the NEXT row's base (see guard note above).
          // fb_we is held (re-asserted each cycle) while waiting for fb_ack so the
          // SDRAM fb writer captures it; the pixel advance is deferred until the
          // write is accepted (fb_ack), or immediately for a masked pixel.
          if (pix_we) begin
            fb_we    <= 1'b1;            // held while in S_WRITE; auto-clears on leaving
            fb_addr  <= {ty, tx9};       // ty*512 + tx
            fb_wdata <= pix_data;
          end
          if (!pix_we || fb_ack) begin   // write accepted (or nothing to write) -> advance
            tx    <= tx + (flipx_c ? -12'sd1 : 12'sd1);
            col_i <= col_i + 12'sd1;
            if (readmode_c) o_ptr <= o_ptr + 32'sd1;
          end
        end

        S_DONE: begin
          busy_r   <= 1'b0;              // COMMAND bit15 -> 0 (done)
          blit_irq <= 1'b1;             // assert LINT1
        end

        default: ;
      endcase
    end
  end

endmodule

`default_nettype wire
