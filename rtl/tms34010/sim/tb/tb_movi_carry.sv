// -----------------------------------------------------------------------------
// tb_movi_carry.sv
//
// Regression for the STATUS-FLAG mask of MOVI IW / MOVI IL. Found by the
// MAME<->RTL differential debugger on UMK3 char-select code: at ROM 0xFFA6B320
// the RTL executed MOVI IW #1, A0 and WRONGLY CLEARED the carry flag.
//   MAME golden ST = 0x40200030  (N=0 C=1 Z=0 V=0 — carry PRESERVED from the
//                                 prior CMPI)
//   buggy RTL ST   = 0x00200030  (carry clobbered to 0)
//
// Root cause: MOVI IW/IL decoded with the DEFAULT full flag mask (C included);
// ALU_OP_PASS_B drives C=0, so the full mask wrote C=0 on every MOVI. Per
// SPVU001A (MOVI, same move family as MOVE Rs,Rd p.12-126): MOVI affects
// N = data[31] and Z = (data==0), resets V = 0, and leaves C **Unaffected**.
//
// The pre-existing tb_movi never set C=1 before a MOVI, so its "C==0" check
// passed whether or not MOVI clobbered C (non-discriminating). This TB seeds
// C=1 via PUTST and asserts C survives — it FAILS on the unfixed RTL.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_movi_carry;
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

  // MOVI IW Rd = 0x09C0 base; MOVI IL Rd = 0x09E0 base; R=bit[4], Rd=bits[3:0].
  function automatic instr_word_t movi_iw_enc(input reg_file_t rf, input reg_idx_t rd);
    movi_iw_enc = 16'h09C0 | (instr_word_t'(rf) << 4) | instr_word_t'(rd);
  endfunction
  function automatic instr_word_t movi_il_enc(input reg_file_t rf, input reg_idx_t rd);
    movi_il_enc = 16'h09E0 | (instr_word_t'(rf) << 4) | instr_word_t'(rd);
  endfunction
  function automatic instr_word_t getst_enc(input reg_file_t rf, input reg_idx_t rd);
    getst_enc = 16'h0180 | (instr_word_t'(rf) << 4) | instr_word_t'(rd);
  endfunction
  function automatic instr_word_t putst_enc(input reg_file_t rf, input reg_idx_t rs);
    putst_enc = 16'h01A0 | (instr_word_t'(rf) << 4) | instr_word_t'(rs);
  endfunction

  function automatic int unsigned place_movi_iw(input int unsigned p,
                                                input reg_file_t rf, input reg_idx_t rd,
                                                input logic [15:0] imm);
    u_mem.mem[p]     = movi_iw_enc(rf, rd);
    u_mem.mem[p + 1] = imm;
    place_movi_iw = p + 2;
  endfunction
  function automatic int unsigned place_movi_il(input int unsigned p,
                                                input reg_file_t rf, input reg_idx_t rd,
                                                input logic [DATA_WIDTH-1:0] imm);
    u_mem.mem[p]     = movi_il_enc(rf, rd);
    u_mem.mem[p + 1] = imm[15:0];
    u_mem.mem[p + 2] = imm[31:16];
    place_movi_il = p + 3;
  endfunction
  function automatic int unsigned place_word(input int unsigned p, input instr_word_t w);
    u_mem.mem[p] = w;  place_word = p + 1;
  endfunction
  // Seed ST via MOVI IL (into B0) + PUTST B0.
  function automatic int unsigned place_seed_st(input int unsigned p, input logic [DATA_WIDTH-1:0] st);
    p = place_movi_il(p, REG_FILE_B, 4'd0, st);
    p = place_word   (p, putst_enc(REG_FILE_B, 4'd0));
    place_seed_st = p;
  endfunction

  int unsigned failures;
  task automatic check_reg(input string label,
                           input logic [DATA_WIDTH-1:0] actual, input logic [DATA_WIDTH-1:0] expected);
    if (actual !== expected) begin
      $display("TEST_RESULT: FAIL: %s: expected=%08h actual=%08h", label, expected, actual);
      failures++;
    end
  endtask

  initial begin : main
    int unsigned p;
    failures = 0;

    p = 0;
    // ---- Carry PRESERVED across MOVI (the bug) ----
    // Seed ST = 0xC0200030 (N=1, C=1, Z=0, V=0), the exact prior-CMPI state.
    p = place_seed_st(p, 32'hC020_0030);
    // Exact char-select trace: MOVI IW #1, A0 -> result 1: N=0, Z=0, V=0; C kept.
    p = place_movi_iw(p, REG_FILE_A, 4'd0, 16'h0001);
    p = place_word   (p, getst_enc(REG_FILE_B, 4'd1));   // B1 = ST (expect 0x40200030)
    // MOVI IW #0, A1 -> Z=1, N=0, V=0; C kept (=1).
    p = place_movi_iw(p, REG_FILE_A, 4'd1, 16'h0000);
    p = place_word   (p, getst_enc(REG_FILE_B, 4'd2));   // B2 (expect 0x60200030: C+Z)
    // MOVI IW #-1 (0xFFFF sign-ext = 0xFFFFFFFF), A2 -> N=1, Z=0; C kept (=1).
    p = place_movi_iw(p, REG_FILE_A, 4'd2, 16'hFFFF);
    p = place_word   (p, getst_enc(REG_FILE_B, 4'd3));   // B3 (expect 0xC0200030: N+C)

    // ---- Carry UNAFFECTED when clear (guard against spuriously setting C) ----
    p = place_seed_st(p, 32'h0020_0030);                 // all flags 0
    // MOVI IW #1, A5 -> N=0, Z=0, V=0; C stays 0.
    p = place_movi_iw(p, REG_FILE_A, 4'd5, 16'h0001);
    p = place_word   (p, getst_enc(REG_FILE_B, 4'd4));   // B4 (expect 0x00200030)
    // MOVI IL 0x80000000, A6 -> N=1, Z=0; C stays 0.
    p = place_movi_il(p, REG_FILE_A, 4'd6, 32'h8000_0000);
    p = place_word   (p, getst_enc(REG_FILE_B, 4'd5));   // B5 (expect 0x80200030: N)
    // MOVI IL 0, A7 -> Z=1, N=0; C stays 0 (unaffected by prior MOVI IL too).
    p = place_movi_il(p, REG_FILE_A, 4'd7, 32'h0000_0000);
    p = place_word   (p, getst_enc(REG_FILE_B, 4'd6));   // B6 (expect 0x20200030: Z)

    p = place_word   (p, 16'hC0FF);                      // JRUC -1 (halt)

    repeat (3) @(posedge clk);
    rst = 1'b0;
    repeat (1200) @(posedge clk);
    #1;

    // Register writes (proves MOVI still moves data correctly).
    check_reg("A0 = 1",           u_core.u_regfile.a_regs[0], 32'h0000_0001);
    check_reg("A1 = 0",           u_core.u_regfile.a_regs[1], 32'h0000_0000);
    check_reg("A2 = 0xFFFFFFFF",  u_core.u_regfile.a_regs[2], 32'hFFFF_FFFF);
    check_reg("A5 = 1",           u_core.u_regfile.a_regs[5], 32'h0000_0001);
    check_reg("A6 = 0x80000000",  u_core.u_regfile.a_regs[6], 32'h8000_0000);
    check_reg("A7 = 0",           u_core.u_regfile.a_regs[7], 32'h0000_0000);

    // Exact-ST assertions (flags + preserved non-flag bits), vs MAME/spec.
    check_reg("MOVI IW #1  (C=1 kept)  == MAME 0x40200030", u_core.u_regfile.b_regs[1], 32'h4020_0030);
    check_reg("MOVI IW #0  (C=1, Z set)== 0x60200030",       u_core.u_regfile.b_regs[2], 32'h6020_0030);
    check_reg("MOVI IW #-1 (C=1, N set)== 0xC0200030",       u_core.u_regfile.b_regs[3], 32'hC020_0030);
    check_reg("MOVI IW #1  (C=0 stays) == 0x00200030",       u_core.u_regfile.b_regs[4], 32'h0020_0030);
    check_reg("MOVI IL MININT (C=0,N)  == 0x80200030",       u_core.u_regfile.b_regs[5], 32'h8020_0030);
    check_reg("MOVI IL 0  (C=0, Z set) == 0x20200030",       u_core.u_regfile.b_regs[6], 32'h2020_0030);

    if (illegal_w !== 1'b0) begin
      $display("TEST_RESULT: FAIL: illegal_opcode_o was set");
      failures++;
    end

    if (failures == 0) begin
      $display("TEST_RESULT: PASS (MOVI IW/IL: C Unaffected, N/Z updated, V=0 — carry preserved)");
    end else begin
      $display("TEST_RESULT: FAIL: %0d check(s) failed", failures);
    end
    $finish;
  end

  initial begin : watchdog
    #2_000_000;
    $display("TEST_RESULT: FAIL: tb_movi_carry hard timeout");
    $fatal(1);
  end

endmodule : tb_movi_carry
