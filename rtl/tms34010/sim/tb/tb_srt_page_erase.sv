// -----------------------------------------------------------------------------
// tb_srt_page_erase.sv
//
// NBA Hangtime DIRQ page-erase transcription — the SRT (VRAM shift-register-
// transfer) bulk-erase sequence, driven through the REAL tms34010_core, twice
// (frame 1 erases page 1, frame 2 erases page 0), against a preseeded 512-row
// VRAM image, with a synthetic DMA sprite overlay poked in after each frame's
// FILL. Dumps the final memory image and per-page scanline projections for an
// EXTERNAL cross-diff against an independently written golden
// (sim/build/srt_golden/ vs this TB's sim/build/srt_tb/).
//
// THIS TB IS ONE SIDE OF A DUAL-TRANSCRIPTION CROSS-DIFF. It deliberately
// performs NO semantic self-checks (no assertions about what the erase should
// have produced) — checking the DUT against itself proves nothing. It asserts
// LIVENESS only: the program retires (PC reaches the per-frame markers and the
// final halt) and no instruction traps illegal. The behavioral verdict is the
// external byte-diff of the dump files.
//
// Assembly transcribed (game source, not MAME):
//   D:/deck/fpga/umk3/nba-hangtime/SRC/MAIN.ASM lines 632-735 (DIRQ autoerase):
//     632  movi  DPYCTL,a8
//     634  move  *a8,a7              ; save DPYCTL (contract stand-in: 0xF010)
//     635  movi  NIL|DXV|SRT|>10,a0  ; = 0x6810 (GSP.EQU:70 SRT=800h, 72 DXV,
//     636  move  a0,*a8              ;   73 NIL) -> SRT latched ON
//     637  movi  510*>1000,a2        ; bit addr 0x1FE000 = erase-source row 510
//     638  pixt  *a2,a2              ; SRT=1 pixel READ = VRAM memory-to-
//                                    ;   shift-register transfer (UG p114)
//     719  MOVk  0ch,a0              ; CONTROL = 0x000C: transparency off,
//     721  move  a0,*a9              ;   replace op, keep CAS-before-RAS refresh
//     722  movk  16,a0               ; PSIZE = 16: UG p252 — "The PSIZE register
//     723  move  a0,@PSIZE           ;   should contain the value 16 so that the
//                                    ;   write cycle is not preceded by a read"
//     724  movi  SCRN_PTCH*2,b3      ; DPTCH = 0x2000 (one SRT row transfer
//                                    ;   covers 0x2000 bits of the array)
//     726  movi  [127,1],b7          ; DYDX: 127 rows x 1 pixel — UG §9.10.2
//     727  fill  l                   ;   (pp217-218) bulk-init recipe: a FILL
//                                    ;   whose every 16-bit pixel write lands on
//                                    ;   a new row address; with SRT=1 each
//                                    ;   write is a register-to-memory cycle
//                                    ;   that rewrites the whole VRAM row
//     730  move  a6,*a9              ; restore CONTROL (contract: 0x002C)
//     731  movk  PXSIZE,a0           ; restore PSIZE = 8
//     735  move  a7,*a8              ; restore DPYCTL (contract: 0xF010)
//   (B2/DADDR comes in from the page-flip code above: 0x00100000 for page 1,
//    0x00000000 for page 0. B9/COLOR1 is uninitialized in the game; the
//    interchange contract pins the deterministic stand-in 0xDEADDEAD.)
//
// TI 1988 TMS34010 User's Guide citations:
//   - SRT semantics (DPYCTL bit 11), UG p114: "When SRT=1 ... accesses of
//     pixel data are converted to shift-register-transfer cycles: a pixel read
//     cycle is converted to a memory-to-register cycle; a pixel write cycle is
//     converted to a register-to-memory cycle."
//   - PSIZE=16 requirement, UG p252 (§11, register-to-memory cycle): value 16
//     so the SRT pixel write is a bare write cycle (no preceding read).
//   - Bulk-initialization recipe, UG pp217-218 (§9.10.2): load the shift
//     register from a preloaded row (PIXT memory-to-register while SRT=1),
//     then one FILL, 16 bits wide per row, one write cycle per row address.
//
// Interchange contract (fixed; the golden implements the identical spec):
//   - Flat 16-bit words, word index W = TMS34010 bit-address >> 4.
//   - VRAM rows 0..511, 256 words/row (512px x 8bpp); page 0 = rows 0..255,
//     page 1 = rows 256..511; rows 510/511 = the erase-source rows.
//   - Preseed, CPU sequence (2 frames), DMA overlay pokes, and the three dump
//     files are exactly as coded below.
//
// NOTE (boot-state preamble, flagged deviation): the contract's per-frame
// sequence starts at the DPYCTL write, so frame 1's PIXT would otherwise run
// with the io_regs RESET value PSIZE=0. In the game DIRQ enters with the
// steady-state PSIZE=PXSIZE=8 (MAIN.ASM:731-732 restores it every frame). The
// TB therefore writes PSIZE=8 once before frame 1. This touches no dumped
// memory word on either side (the PIXT is a read), it only removes a
// PSIZE=0-pixel-read liveness hazard.
//
// Outputs (created under +SRT_OUT_DIR=<dir>, default "sim/build/srt_tb" —
// relative to the SIMULATOR's working directory; the directory must already
// exist, the TB $fatal's loudly if $fopen fails):
//   vram_final.hex : 512 lines; line r = 256 words, "%04h", single-space-sep.
//   scan_p0.hex, scan_p1.hex : 254 lines x 400 pixel bytes "%02h", space-sep.
//     scanline s of page P: row = P*256 + s; pixel x: pixcol = (56+x) & 0x1FF
//     (midtunit scanline_update with DPYTAP = 28<<1 projected into word
//     space); even pixcol -> word bits[7:0], odd -> bits[15:8].
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_srt_page_erase;
  import tms34010_pkg::*;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;

  logic                          mem_req;
  logic                          mem_we;
  logic [ADDR_WIDTH-1:0]         mem_addr;
  logic [FIELD_SIZE_WIDTH-1:0]   mem_size;
  logic [DATA_WIDTH-1:0]         mem_wdata;
  logic [DATA_WIDTH-1:0]         mem_rdata;
  logic                          mem_ack;
  logic                          mem_srt;   // SRT sideband: core -> memory model
  core_state_t                   state_w;
  logic [ADDR_WIDTH-1:0]         pc_w;
  instr_word_t                   instr_w;
  logic                          illegal_w;

  tms34010_core u_core (
    .clk(clk), .rst(rst),
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_size(mem_size),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack),
    .mem_srt(mem_srt),
    .state_o(state_w), .pc_o(pc_w), .instr_word_o(instr_w), .illegal_opcode_o(illegal_w)
  );

  // 512K x 16 backing store: word indices 0x00000..0x1FFFF are the 512-row
  // VRAM (bit addrs 0x000000..0x1FFFFF), the program lives at word 0x40000
  // (bit addr 0x00400000), and the reset vector at bit addr 0xFFFFFFE0
  // aliases (addr[22:4]) onto words DEPTH-2/DEPTH-1 exactly as in the other
  // core TBs. The shared model is parameterized, not edited.
  localparam int unsigned SIM_DEPTH_WORDS = 32'h0008_0000;   // 2^19 words
  sim_memory_model #(.DEPTH_WORDS(SIM_DEPTH_WORDS)) u_mem (
    .clk(clk), .rst(rst),
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_size(mem_size),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack),
    .mem_srt(mem_srt)
  );

  // ---- Instruction encoders (conventions copied from tb_fill_l / tb_pixt) --
  function automatic instr_word_t movi_il_enc(input reg_idx_t i);
    movi_il_enc = 16'h09E0 | instr_word_t'(i);    // MOVI IL, A-file
  endfunction
  function automatic instr_word_t movi_il_b_enc(input reg_idx_t i);
    movi_il_b_enc = 16'h09F0 | instr_word_t'(i);  // MOVI IL, B-file
  endfunction
  function automatic instr_word_t setf_enc(input logic [4:0] fs,
                                           input logic fe, input logic f_sel);
    setf_enc = 16'b0000_0100_0000_0000
             | (instr_word_t'(f_sel) << 9) | 16'b0000_0001_0000_0000
             | 16'b0000_0000_0100_0000 | (instr_word_t'(fe) << 5)
             | instr_word_t'(fs);
  endfunction
  // PIXT *Rs,Rd (memory pixel -> register): 0xFA00 | Rs<<5 | Rd (tb_pixt).
  function automatic instr_word_t pixt_load_enc(input reg_idx_t rs, input reg_idx_t rd);
    pixt_load_enc = 16'hFA00 | (instr_word_t'(rs) << 5) | instr_word_t'(rd);
  endfunction

  function automatic int unsigned place_movi_il(input int unsigned p,
                                                input reg_idx_t i,
                                                input logic [DATA_WIDTH-1:0] imm);
    u_mem.mem[p]     = movi_il_enc(i);
    u_mem.mem[p + 1] = imm[15:0];
    u_mem.mem[p + 2] = imm[31:16];
    place_movi_il = p + 3;
  endfunction
  function automatic int unsigned place_movi_il_b(input int unsigned p,
                                                  input reg_idx_t i,
                                                  input logic [DATA_WIDTH-1:0] imm);
    u_mem.mem[p]     = movi_il_b_enc(i);
    u_mem.mem[p + 1] = imm[15:0];
    u_mem.mem[p + 2] = imm[31:16];
    place_movi_il_b = p + 3;
  endfunction
  function automatic int unsigned place_word(input int unsigned p, input instr_word_t w);
    u_mem.mem[p] = w;  place_word = p + 1;
  endfunction
  // MOVE Rs,@DAddr store (FS0-sized; FS0=16 here): 0x0580 | Rs, addr LSW, MSW.
  function automatic int unsigned place_store_abs(input int unsigned p,
                                                  input reg_idx_t rs,
                                                  input logic [31:0] addr);
    u_mem.mem[p]     = 16'h0580 | instr_word_t'(rs);
    u_mem.mem[p + 1] = addr[15:0];
    u_mem.mem[p + 2] = addr[31:16];
    place_store_abs = p + 3;
  endfunction

  // I/O register bit addresses (GSP.EQU:14/17/27 — DPYCTL 0xC0000080,
  // CONTROL 0xC00000B0, PSIZE 0xC0000150). Writes land in the core's on-chip
  // u_io_regs instance (tms34010_core gates mem_we with !io_is_io; the
  // external cycle is a harmless gated read — Task 0082 wiring, the pattern
  // established by tb_io_access / tb_pixt).
  localparam logic [31:0] A_DPYCTL  = IO_BASE_ADDR + (IO_IDX_DPYCTL  << 4); // C0000080
  localparam logic [31:0] A_CONTROL = IO_BASE_ADDR + (IO_IDX_CONTROL << 4); // C00000B0
  localparam logic [31:0] A_PSIZE   = IO_BASE_ADDR + (IO_IDX_PSIZE   << 4); // C0000150

  // ---- One DIRQ frame, exactly per the interchange contract ---------------
  // write DPYCTL=0x6810; A2=0x001FE000; PIXT *A2,A2; write CONTROL=0x000C;
  // write PSIZE=0x0010; B2=daddr; B3=0x2000; B7=[127,1]; B9=0xDEADDEAD;
  // FILL L; restore DPYCTL=0xF010, PSIZE=0x0008, CONTROL=0x002C.
  function automatic int unsigned place_frame(input int unsigned p,
                                              input logic [31:0] daddr);
    p = place_movi_il  (p, 4'd0, 32'h0000_6810);  // MAIN.ASM:635 NIL|DXV|SRT|>10
    p = place_store_abs(p, 4'd0, A_DPYCTL);       // MAIN.ASM:636 move a0,*a8
    p = place_movi_il  (p, 4'd2, 32'h001F_E000);  // MAIN.ASM:637 movi 510*>1000,a2
    p = place_word     (p, pixt_load_enc(4'd2, 4'd2)); // MAIN.ASM:638 pixt *a2,a2
                                                  //  = 0xFA42 (UG p114: SRT=1
                                                  //  pixel read -> mem-to-SR)
    p = place_movi_il  (p, 4'd3, 32'h0000_000C);  // MAIN.ASM:719 movk 0ch,a0
    p = place_store_abs(p, 4'd3, A_CONTROL);      // MAIN.ASM:721 transparency off
    p = place_movi_il  (p, 4'd4, 32'h0000_0010);  // MAIN.ASM:722 movk 16,a0
    p = place_store_abs(p, 4'd4, A_PSIZE);        // MAIN.ASM:723 (UG p252: 16)
    p = place_movi_il_b(p, 4'd2, daddr);          // B2 DADDR (page-flip code)
    p = place_movi_il_b(p, 4'd3, 32'h0000_2000);  // MAIN.ASM:724 B3 SCRN_PTCH*2
    p = place_movi_il_b(p, 4'd7, 32'h007F_0001);  // MAIN.ASM:726 B7 [127,1]
    p = place_movi_il_b(p, 4'd9, 32'hDEAD_DEAD);  // B9 COLOR1 contract stand-in
    p = place_word     (p, 16'h0FC0);             // MAIN.ASM:727 fill l
    p = place_movi_il  (p, 4'd5, 32'h0000_F010);  // saved-DPYCTL stand-in (a7)
    p = place_store_abs(p, 4'd5, A_DPYCTL);       // MAIN.ASM:735 move a7,*a8
    p = place_movi_il  (p, 4'd6, 32'h0000_0008);  // MAIN.ASM:731 movk PXSIZE,a0
    p = place_store_abs(p, 4'd6, A_PSIZE);        // MAIN.ASM:732 restore PSIZE
    p = place_movi_il  (p, 4'd7, 32'h0000_002C);  // saved-CONTROL stand-in (a6)
    p = place_store_abs(p, 4'd7, A_CONTROL);      // MAIN.ASM:730 move a6,*a9
    place_frame = p;
  endfunction

  // ---- VRAM preseed (contract-exact) --------------------------------------
  // rows 0..509:  word[r*256+c] = 0xA000 | ((r*7 + c*3) & 0x0FFF)  (nonzero)
  // row 510:      0x0500 | (c & 0xFF)   } differ on purpose: catches
  // row 511:      0x0600 | (c & 0xFF)   } off-by-one-row; nonzero: catches
  //                                       zero-fill impls
  task automatic preseed_vram();
    int r, c;
    for (r = 0; r < 510; r++)
      for (c = 0; c < 256; c++)
        u_mem.mem[r*256 + c] = 16'(16'hA000 | ((r*7 + c*3) & 'h0FFF));
    for (c = 0; c < 256; c++) begin
      u_mem.mem[510*256 + c] = 16'(16'h0500 | (c & 'hFF));
      u_mem.mem[511*256 + c] = 16'(16'h0600 | (c & 'hFF));
    end
  endtask

  // ---- Synthetic DMA sprite overlay (contract-exact; TB pokes, NOT a DUT
  // path). Applied after each frame's FILL onto the just-erased page.
  // abs_row_base = P*256 + 47 (frame 1: 303, frame 2: 47).
  task automatic apply_dma_overlay(input int unsigned abs_row_base);
    int i, j, src, x, r, w;
    logic [15:0] word_v;
    for (j = 0; j < 36; j++) begin
      for (i = 0; i < 342; i++) begin
        src = (((i*7 + j*13) % 5) == 0) ? 0 : ('h40 | ((i + j) & 'h3F));
        if (src != 0) begin
          x = 87 + i;                       // pixel column 87..428
          r = int'(abs_row_base) + j;       // absolute VRAM row
          w = r*256 + (x >> 1);             // word holding pixel byte
          word_v = u_mem.mem[w];
          if (x[0]) word_v[15:8] = 8'(src); // odd X  -> high byte
          else      word_v[7:0]  = 8'(src); // even X -> low byte
          u_mem.mem[w] = word_v;            // other byte preserved
        end
      end
    end
  endtask

  // ---- Dump files (contract-exact formats) --------------------------------
  string out_dir = "sim/build/srt_tb";

  // "wb": binary mode so the explicit "\n" stays a single LF byte on Windows
  // simulators too — the dump must be byte-comparable across platforms.
  function automatic int open_or_die(input string path);
    int fd;
    fd = $fopen(path, "wb");
    if (fd == 0) begin
      $display("TEST_RESULT: FAIL: cannot open '%s' for write.", path);
      $display("  The output directory must exist before the run:");
      $display("    mkdir -p %s   (or pass +SRT_OUT_DIR=<existing dir>)", out_dir);
      $fatal(1);
    end
    open_or_die = fd;
  endfunction

  // scanline pixel byte: pixcol = (56+x) & 0x1FF (DPYTAP = 28<<1); even
  // pixcol -> word bits[7:0], odd -> bits[15:8].
  function automatic logic [7:0] scan_pixel_byte(input int unsigned row,
                                                 input int unsigned x);
    int unsigned pixcol;
    logic [15:0] w;
    pixcol = (56 + x) & 'h1FF;
    w = u_mem.mem[row*256 + (pixcol >> 1)];
    scan_pixel_byte = pixcol[0] ? w[15:8] : w[7:0];
  endfunction

  task automatic dump_outputs(input string tag);
    int fd;
    int unsigned r, c, pg, s, x;
    $display("[%0t] dumping %s outputs to '%s/'", $time, tag, out_dir);

    // vram_final.hex: 512 lines x 256 words, %04h, single-space-separated.
    fd = open_or_die({out_dir, "/vram_final.hex"});
    for (r = 0; r < 512; r++) begin
      for (c = 0; c < 256; c++) begin
        if (c != 0) $fwrite(fd, " ");
        $fwrite(fd, "%04h", u_mem.mem[r*256 + c]);
      end
      $fwrite(fd, "\n");
    end
    $fclose(fd);

    // scan_p0.hex / scan_p1.hex: 254 lines x 400 pixel bytes, %02h.
    for (pg = 0; pg < 2; pg++) begin
      fd = open_or_die(pg ? {out_dir, "/scan_p1.hex"} : {out_dir, "/scan_p0.hex"});
      for (s = 0; s < 254; s++) begin
        for (x = 0; x < 400; x++) begin
          if (x != 0) $fwrite(fd, " ");
          $fwrite(fd, "%02h", scan_pixel_byte(pg*256 + s, x));
        end
        $fwrite(fd, "\n");
      end
      $fclose(fd);
    end
  endtask

  // ---- Liveness monitor (the ONLY checking this TB does) ------------------
  // Report loudly if any instruction traps illegal (would mean PIXT *Rs,Rd or
  // FILL L regressed to decoded-as-illegal). illegal_opcode_o is sticky.
  bit illegal_seen = 1'b0;
  always @(posedge clk) begin
    if (!rst && (illegal_w === 1'b1) && !illegal_seen) begin
      illegal_seen = 1'b1;
      $display("TEST_RESULT: FAIL: LIVENESS: illegal-opcode trap at PC=%08h instr=%04h",
               pc_w, instr_w);
      $display("  (is PIXT *Rs,Rd (0xFA42) / FILL L (0x0FC0) still implemented?)");
    end
  end

  // ---- Program layout / phase tracking ------------------------------------
  localparam int unsigned PROG_W = 32'h0004_0000;            // word 0x40000
  localparam logic [31:0] PROG_BIT = 32'(PROG_W) << 4;       // bit addr 0x00400000
  int unsigned f2_w, halt_w;          // word index of frame-2 entry / halt
  logic [31:0] f2_bit, halt_bit;
  int phase = 0;                      // for the watchdog diagnostic

  initial begin : main
    int unsigned p;
    void'($value$plusargs("SRT_OUT_DIR=%s", out_dir));

    // Poke memory AFTER the model's own time-0 zero-init `initial` has run
    // (rst is still high; the core is quiescent), avoiding any time-0
    // initial-block ordering race.
    @(posedge clk);
    preseed_vram();

    // Program (word indices; bit addr = index<<4).
    p = PROG_W;
    p = place_word(p, setf_enc(5'd16, 1'b1, 1'b0));    // MAIN.ASM:625 setf 16,1,0
    // Boot-state preamble (see header NOTE): steady-state PSIZE=PXSIZE=8.
    p = place_movi_il  (p, 4'd0, 32'h0000_0008);
    p = place_store_abs(p, 4'd0, A_PSIZE);
    // FRAME 1: erase page 1 (DADDR = 0x00100000 = row 256).
    p = place_frame(p, 32'h0010_0000);
    f2_w   = p;
    f2_bit = 32'(f2_w) << 4;
    // FRAME 2: the whole thing again (including the PIXT latch, as DIRQ does
    // every frame), DADDR = 0x00000000 = page 0.
    p = place_frame(p, 32'h0000_0000);
    halt_w   = p;
    halt_bit = 32'(halt_w) << 4;
    p = place_word(p, 16'hC0FF);                       // JRUC . (self-loop halt)

    // Reset vector (P0001): bit addr 0xFFFFFFE0 aliases (addr[22:4]) to
    // words DEPTH-2/DEPTH-1. Point PC at the program.
    u_mem.mem[SIM_DEPTH_WORDS - 2] = PROG_BIT[15:0];
    u_mem.mem[SIM_DEPTH_WORDS - 1] = PROG_BIT[31:16];

    phase = 1;                       // running frame 1
    repeat (2) @(posedge clk);
    rst = 1'b0;

    // FRAME 1 retires when the core first fetches frame 2's entry word (the
    // FSM is strictly in-order; the only access possibly still in flight is
    // the final CONTROL I/O restore, which never touches VRAM).
    while (pc_w !== f2_bit) @(posedge clk);
    $display("[%0t] LIVENESS: frame 1 retired (PC reached %08h)", $time, f2_bit);
    phase = 2;                       // overlay 1 + frame 2
    repeat (20) @(posedge clk);
    #1;
    apply_dma_overlay(32'd303);      // frame 1: page 1, absolute rows 303..338

    // FRAME 2 retires at the halt self-loop.
    while (pc_w !== halt_bit) @(posedge clk);
    $display("[%0t] LIVENESS: frame 2 retired (PC reached halt %08h)", $time, halt_bit);
    phase = 3;                       // overlay 2 + dump
    repeat (100) @(posedge clk);
    #1;
    apply_dma_overlay(32'd47);       // frame 2: page 0, absolute rows 47..82

    dump_outputs("final");

    if (!illegal_seen) begin
      $display("TEST_RESULT: PASS (liveness: both DIRQ frames retired, no illegal trap; dumps written -- behavioral verdict is the EXTERNAL cross-diff vs sim/build/srt_golden/)");
    end else begin
      $display("TEST_RESULT: FAIL: liveness violated (illegal trap reported above); dumps still written for diagnosis");
    end
    $finish;
  end

  initial begin : watchdog
    #10_000_000;   // 1M clk cycles — generous (whole run is ~tens of k cycles)
    $display("TEST_RESULT: FAIL: tb_srt_page_erase hard timeout in phase %0d (1=frame1, 2=frame2, 3=dump); PC=%08h state=%0d",
             phase, pc_w, state_w);
    dump_outputs("PARTIAL(timeout)");
    $fatal(1);
  end

endmodule : tb_srt_page_erase
