// -----------------------------------------------------------------------------
// tb_cmpi_flags.sv
//
// Regression for the STATUS-FLAG update path of the IW-form immediate-compare
// instruction CMPI (and, as a cross-check, MOVE *Rs(off),Rd load). Found by the
// MAME<->RTL differential debugger on UMK3 char-select code: the RTL's ST stayed
// frozen while MAME evolved N/C/Z across a CMPI IW that reads a 16-bit immediate.
//
// The existing tb_immi_iw only checks the FINAL ST (which coincidentally equals
// the reset ST = all flags 0), so it never exercised CMPI's Z=1 / N=1,C=1
// outcomes. This TB snapshots ST with GETST *immediately after* each compare and
// asserts the exact N/C/Z/V the User's Guide specifies (SPVU001A Ch.13 CMPI:
// "the status bits are affected as if the subtraction Rd - K were performed").
//
// Encodings (SPVU001A A-14):
//   CMPI IW K, Rd = 0000 1011 010R DDDD + 16-bit imm. P0008: the immediate word
//   stores the ONE'S COMPLEMENT of K, so "CMPI 5" encodes 0xFFFA (~5).
//   GETST Rd      = 0000 0001 100R DDDD  (copy ST -> Rd).
//   MOVE *Rs(off),Rd = 1011 01SS SSSR DDDD + off (0xB400 base).
//
// Exact reproduction of the char-select trace word 0x0B47 + imm 0xFFFD:
//   CMPI IW #2, A3 (0xFFFD = ~2) with A3 = 0  ->  0 - 2 = 0xFFFFFFFE
//   => N=1, C=1 (borrow), Z=0, V=0   (MAME ST = C0200030).
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_cmpi_flags;
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
  core_state_t                   state_w;
  logic [ADDR_WIDTH-1:0]         pc_w;
  instr_word_t                   instr_w;
  logic                          illegal_w;

  tms34010_core u_core (
    .clk(clk), .rst(rst),
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_size(mem_size),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack),
    .state_o(state_w), .pc_o(pc_w), .instr_word_o(instr_w), .illegal_opcode_o(illegal_w)
  );

  sim_memory_model #(.DEPTH_WORDS(256)) u_mem (
    .clk(clk), .rst(rst),
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_size(mem_size),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack)
  );

  localparam logic [10:0] CMPI_IW_TOP11 = 11'b0000_1011_010;
  localparam logic [10:0] CMPI_IL_TOP11 = 11'b0000_1011_011;

  function automatic instr_word_t movi_il_enc(input reg_file_t rf, input reg_idx_t i);
    movi_il_enc = 16'h09E0 | (instr_word_t'(rf) << 4) | instr_word_t'(i);
  endfunction
  // PUTST Rs : 0x01A0 base, R=file bit[4], Rs=bits[3:0]. ST <- Rs (full 32-bit).
  function automatic instr_word_t putst_enc(input reg_file_t rf, input reg_idx_t rs);
    putst_enc = 16'h01A0 | (instr_word_t'(rf) << 4) | instr_word_t'(rs);
  endfunction
  // GETST Rd : 0x0180 base, R=file bit[4], Rd=bits[3:0].
  function automatic instr_word_t getst_enc(input reg_file_t rf, input reg_idx_t rd);
    getst_enc = 16'h0180 | (instr_word_t'(rf) << 4) | instr_word_t'(rd);
  endfunction
  function automatic instr_word_t cmpi_iw_enc(input reg_file_t rf, input reg_idx_t rd);
    cmpi_iw_enc = (instr_word_t'(CMPI_IW_TOP11) << 5) | (instr_word_t'(rf) << 4) | instr_word_t'(rd);
  endfunction

  function automatic int unsigned place_movi_il(input int unsigned p,
                                                input reg_file_t rf, input reg_idx_t i,
                                                input logic [DATA_WIDTH-1:0] imm);
    u_mem.mem[p]     = movi_il_enc(rf, i);
    u_mem.mem[p + 1] = imm[15:0];
    u_mem.mem[p + 2] = imm[31:16];
    place_movi_il = p + 3;
  endfunction
  function automatic int unsigned place_cmpi_iw(input int unsigned p,
                                                input reg_file_t rf, input reg_idx_t rd,
                                                input logic [15:0] imm);
    u_mem.mem[p]     = cmpi_iw_enc(rf, rd);
    u_mem.mem[p + 1] = imm;
    place_cmpi_iw = p + 2;
  endfunction
  function automatic instr_word_t cmpi_il_enc(input reg_file_t rf, input reg_idx_t rd);
    cmpi_il_enc = (instr_word_t'(CMPI_IL_TOP11) << 5) | (instr_word_t'(rf) << 4) | instr_word_t'(rd);
  endfunction
  function automatic int unsigned place_cmpi_il(input int unsigned p,
                                                input reg_file_t rf, input reg_idx_t rd,
                                                input logic [31:0] imm);
    u_mem.mem[p]     = cmpi_il_enc(rf, rd);
    u_mem.mem[p + 1] = imm[15:0];
    u_mem.mem[p + 2] = imm[31:16];
    place_cmpi_il = p + 3;
  endfunction
  function automatic int unsigned place_word(input int unsigned p, input instr_word_t w);
    u_mem.mem[p] = w;  place_word = p + 1;
  endfunction

  int unsigned failures;
  task automatic check_bit(input string label, input logic actual, input logic expected);
    if (actual !== expected) begin
      $display("TEST_RESULT: FAIL: %s: expected=%0b actual=%0b", label, expected, actual);
      failures++;
    end
  endtask
  task automatic check_reg(input string label,
                           input logic [DATA_WIDTH-1:0] actual, input logic [DATA_WIDTH-1:0] expected);
    if (actual !== expected) begin
      $display("TEST_RESULT: FAIL: %s: expected=%08h actual=%08h", label, expected, actual);
      failures++;
    end
  endtask

  // Convenience: check the four condition flags of a GETST snapshot register.
  task automatic check_flags(input string label, input logic [DATA_WIDTH-1:0] st,
                             input logic n, input logic c, input logic z, input logic v);
    check_bit({label, " N"}, st[ST_N_BIT], n);
    check_bit({label, " C"}, st[ST_C_BIT], c);
    check_bit({label, " Z"}, st[ST_Z_BIT], z);
    check_bit({label, " V"}, st[ST_V_BIT], v);
  endtask

  initial begin : main
    int unsigned p;
    failures = 0;

    p = 0;
    // Case A: CMPI IW #5, A1 with A1 = 5  ->  5 - 5 = 0  => Z=1, N=0, C=0, V=0.
    p = place_movi_il(p, REG_FILE_A, 4'd1, 32'd5);
    p = place_cmpi_iw(p, REG_FILE_A, 4'd1, 16'hFFFA);   // ~5
    p = place_word  (p, getst_enc(REG_FILE_B, 4'd0));   // B0 <- ST

    // Case B: exact trace repro. CMPI IW #2, A3 with A3 = 0  ->  0 - 2
    //   => N=1, C=1 (borrow), Z=0, V=0  (MAME C0200030).
    p = place_movi_il(p, REG_FILE_A, 4'd3, 32'd0);
    p = place_cmpi_iw(p, REG_FILE_A, 4'd3, 16'hFFFD);   // ~2, matches ROM word 0xFFFD
    p = place_word  (p, getst_enc(REG_FILE_B, 4'd1));   // B1 <- ST

    // Case C: cross-check MOVE *Rs(off),Rd load (needs_imm16, same fetch path).
    // 32-bit field-size (SETF FS=0) so the full word loads; pointer past code.
    p = place_word  (p, 16'h0540);                      // SETF FS=0, FE=0, F=0
    p = place_movi_il(p, REG_FILE_A, 4'd5, 32'h0000_0400);  // ptr bit-addr 0x400 (word 64, =0)
    p = place_word  (p, 16'hB400 | (instr_word_t'(4'd5) << 5) | instr_word_t'(4'd6)); // MOVE *A5(off),A6
    p = place_word  (p, 16'h0000);                      // offset = 0
    p = place_word  (p, getst_enc(REG_FILE_B, 4'd2));   // B2 <- ST

    // Case D: CMPI IL (32-bit immediate) shares the exact same flag path and had
    // the SAME coverage gap (tb_immi_il checks no flags). CMPI IL #7, A8 with
    // A8 = 7 -> 7 - 7 = 0 => Z=1, N=0, C=0, V=0. P0008: imm stores ~7.
    p = place_movi_il(p, REG_FILE_A, 4'd8, 32'd7);
    p = place_cmpi_il(p, REG_FILE_A, 4'd8, ~32'd7);
    p = place_word  (p, getst_enc(REG_FILE_B, 4'd3));   // B3 <- ST

    // Case E: EXACT char-select trace reproduction, seeded to the debugger's
    // ST = 0x00200030, chaining MOVE *Rs(off),Rd (-> A7 = 0) then CMPI IW A7,#2
    // (ROM imm word 0xFFFD). Asserts MAME's exact golden ST at each retire:
    //   after MOVE : 0x20200030 (Z=1)   after CMPI : 0xC0200030 (N=1,C=1).
    p = place_movi_il(p, REG_FILE_B, 4'd5, 32'h0020_0030);  // seed value
    p = place_word  (p, putst_enc(REG_FILE_B, 4'd5));       // ST <- 0x00200030
    p = place_movi_il(p, REG_FILE_A, 4'd8, 32'h0000_0400);  // ptr bit-addr 0x400 (word 64 = 0)
    p = place_word  (p, 16'hB400 | (instr_word_t'(4'd8) << 5) | instr_word_t'(4'd7)); // MOVE *A8(off),A7
    p = place_word  (p, 16'h0000);                          // offset = 0
    p = place_word  (p, getst_enc(REG_FILE_B, 4'd6));       // B6 <- ST after MOVE (0x20200030)
    p = place_cmpi_iw(p, REG_FILE_A, 4'd7, 16'hFFFD);       // CMPI IW A7,#2 (exact ROM word)
    p = place_word  (p, getst_enc(REG_FILE_B, 4'd7));       // B7 <- ST after CMPI (0xC0200030)

    p = place_word  (p, 16'hC0FF);                      // JRUC -1 (halt)

    repeat (3) @(posedge clk);
    rst = 1'b0;
    repeat (1200) @(posedge clk);
    #1;

    // Register side effects.
    check_reg("A1 unchanged by CMPI", u_core.u_regfile.a_regs[1], 32'd5);
    check_reg("A3 unchanged by CMPI", u_core.u_regfile.a_regs[3], 32'd0);
    check_reg("A6 loaded 0",          u_core.u_regfile.a_regs[6], 32'd0);

    // Flag outcomes (spec-defined, cross-checked vs MAME, NOT vs the RTL).
    check_flags("CaseA CMPI 5-5=0",  u_core.u_regfile.b_regs[0], 1'b0, 1'b0, 1'b1, 1'b0);
    check_flags("CaseB CMPI 0-2",    u_core.u_regfile.b_regs[1], 1'b1, 1'b1, 1'b0, 1'b0);
    // MOVE load: N/Z/V defined, C Unaffected -> check only N,Z,V.
    check_bit ("CaseC MOVE load N", u_core.u_regfile.b_regs[2][ST_N_BIT], 1'b0);
    check_bit ("CaseC MOVE load Z", u_core.u_regfile.b_regs[2][ST_Z_BIT], 1'b1);
    check_bit ("CaseC MOVE load V", u_core.u_regfile.b_regs[2][ST_V_BIT], 1'b0);

    check_flags("CaseD CMPI IL 7-7=0", u_core.u_regfile.b_regs[3], 1'b0, 1'b0, 1'b1, 1'b0);

    // Case E: exact golden ST match (flags + preserved non-flag bits), proving
    // the RTL evolves ST identically to MAME across the char-select trace.
    check_reg("CaseE ST after MOVE == MAME 0x20200030", u_core.u_regfile.b_regs[6], 32'h2020_0030);
    check_reg("CaseE ST after CMPI == MAME 0xC0200030", u_core.u_regfile.b_regs[7], 32'hC020_0030);

    if (illegal_w !== 1'b0) begin
      $display("TEST_RESULT: FAIL: illegal_opcode_o was set");
      failures++;
    end

    if (failures == 0) begin
      $display("TEST_RESULT: PASS (CMPI IW N/C/Z/V + MOVE-off load N/Z/V flag update verified)");
    end else begin
      $display("TEST_RESULT: FAIL: %0d check(s) failed", failures);
    end
    $finish;
  end

  initial begin : watchdog
    #2_000_000;
    $display("TEST_RESULT: FAIL: tb_cmpi_flags hard timeout");
    $fatal(1);
  end

endmodule : tb_cmpi_flags
