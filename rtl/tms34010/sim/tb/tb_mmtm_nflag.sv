// -----------------------------------------------------------------------------
// tb_mmtm_nflag.sv
//
// MMTM status semantics on the TMS34010: ALL of N/C/Z/V are UNAFFECTED.
//
// The N = ~Rp[31] behavior once modeled here (Task 0057, from a mis-read of the
// User's Guide) is a TMS34020-ONLY feature. MAME gates it on the 34020:
//     if (m_is_34020) { CLR_N(); SET_N_VAL(Rp ^ 0x80000000); }
// (src/devices/cpu/tms34010/34010ops.hxx). Wolf-unit / UMK3 is a plain
// TMS34010, so MMTM writes no status bit. The MAME<->RTL differential debugger
// caught the old RTL setting N at ROM FF805A70 (MMTM SP, SP=0x010FFFB0):
// MAME ST=0x00200030 (N unaffected) vs RTL 0x80200030 (N=~SP[31]=1).
//
// This TB seeds a known ST (with a deliberately WRONG-for-34020 N), runs MMTM,
// and asserts the FULL ST is unchanged. It FAILS on the pre-fix RTL, whose
// MMTM overwrites N with ~Rp[31].
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_mmtm_nflag;
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

  sim_memory_model #(.DEPTH_WORDS(512)) u_mem (
    .clk(clk), .rst(rst),
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_size(mem_size),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack)
  );

  function automatic int unsigned place_movi_il(input int unsigned p,
                                                input reg_file_t rf, input reg_idx_t i,
                                                input logic [DATA_WIDTH-1:0] imm);
    u_mem.mem[p]     = 16'h09E0 | (instr_word_t'(rf) << 4) | instr_word_t'(i);
    u_mem.mem[p + 1] = imm[15:0];
    u_mem.mem[p + 2] = imm[31:16];
    place_movi_il = p + 3;
  endfunction
  function automatic int unsigned place_word(input int unsigned p, input instr_word_t w);
    u_mem.mem[p] = w;  place_word = p + 1;
  endfunction

  // MMTM A1, {A0}: opcode 0x0981, mask 0x8000 (reversed map P0011: bit15 = R0).
  // GETST A<snap> = 0x0180 | snap. PUTST B<x> = 0x01B0 | x (ST <- Bx).
  // Sequence: MOVI A1=Rp; MOVI Bx=seedST; PUTST Bx; MMTM A1,{A0}; GETST A<snap>.
  function automatic int unsigned place_case(input int unsigned p,
                                             input logic [DATA_WIDTH-1:0] rp_val,
                                             input logic [DATA_WIDTH-1:0] seed_st,
                                             input reg_idx_t snap);
    p = place_movi_il(p, REG_FILE_A, 4'd1, rp_val);      // A1 = Rp
    p = place_movi_il(p, REG_FILE_B, 4'd0, seed_st);     // B0 = seed ST
    p = place_word   (p, 16'h01B0);                      // PUTST B0  -> ST = seed
    p = place_word   (p, 16'h0981);                      // MMTM A1, mask
    p = place_word   (p, 16'h8000);                      //   mask = {A0}
    p = place_word   (p, 16'h0180 | instr_word_t'(snap));// GETST A<snap>
    place_case = p;
  endfunction

  int unsigned failures;
  task automatic check_st(input string label,
                          input logic [DATA_WIDTH-1:0] actual, input logic [DATA_WIDTH-1:0] expected);
    if (actual !== expected) begin
      $display("TEST_RESULT: FAIL: %s: MMTM changed ST expected=%08h actual=%08h", label, expected, actual);
      failures++;
    end
  endtask

  initial begin : main
    int unsigned p, i;
    failures = 0;

    for (i = 0; i < 512; i++) u_mem.mem[i] = 16'h0300;   // NOP-fill
    u_mem.mem[510] = 16'h0000;                           // reset vector -> word 0
    u_mem.mem[511] = 16'h0000;

    p = 0;
    p = place_movi_il(p, REG_FILE_A, 4'd0, 32'hA0A0_A0A0);  // A0 = pushed value

    // Case 1: Rp positive (0x00001000). Seed N=0,C=1,Z=1,V=1 (ST=0x70000030).
    // Fixed: N stays 0. Pre-fix bug: N <- ~Rp[31] = ~0 = 1 (ST=0xF0000030) -> FAIL.
    p = place_case(p, 32'h0000_1000, 32'h7000_0030, 4'd2);
    // Case 2: Rp negative (0xFFFFF000). Seed N=1,C=0,Z=0,V=0 (ST=0x80000030).
    // Fixed: N stays 1. Pre-fix bug: N <- ~Rp[31] = ~1 = 0 (ST=0x00000030) -> FAIL.
    p = place_case(p, 32'hFFFF_F000, 32'h8000_0030, 4'd3);

    p = place_word(p, 16'hC0FF);                          // halt

    repeat (3) @(posedge clk);
    rst = 1'b0;
    repeat (3000) @(posedge clk);
    #1;

    check_st("Case1 Rp=+ seed 0x70000030", u_core.u_regfile.a_regs[2], 32'h7000_0030);
    check_st("Case2 Rp=- seed 0x80000030", u_core.u_regfile.a_regs[3], 32'h8000_0030);

    if (illegal_w !== 1'b0) begin
      $display("TEST_RESULT: FAIL: illegal_opcode_o was set");
      failures++;
    end

    if (failures == 0) begin
      $display("TEST_RESULT: PASS (TMS34010 MMTM leaves N/C/Z/V Unaffected)");
    end else begin
      $display("TEST_RESULT: FAIL: %0d check(s) failed", failures);
    end
    $finish;
  end

  initial begin : watchdog
    #5_000_000;
    $display("TEST_RESULT: FAIL: tb_mmtm_nflag hard timeout");
    $fatal(1);
  end

endmodule : tb_mmtm_nflag
