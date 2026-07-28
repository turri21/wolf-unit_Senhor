// -----------------------------------------------------------------------------
// tb_logical_flags.sv
//
// TMS34010 boolean instructions affect ONLY the Z status bit; N, C and V are
// UNAFFECTED. MAME implements every one as CLR_Z() + SET_Z_VAL(*rd)
// (src/devices/cpu/tms34010/34010ops.hxx) — no N/C/V touch. The pre-fix RTL
// used the default full N/C/Z/V mask, so each logical op clobbered N (to
// result[31]), C (to 0) and V (to 0).
//
// Covered: register AND / ANDN / OR / XOR / NOT and immediate ANDI / ORI / XORI.
// Each op is run with ST pre-seeded to N=1,C=1,Z=0,V=1 (0xD0000030). Correct
// result: N/C/V preserved, Z = (result==0):
//   nonzero result -> ST = 0xD0000030   (Z stays 0)
//   zero    result -> ST = 0xF0000030   (Z set to 1)
// The full-ST compare catches the pre-fix clobber of N, C, or V on every case.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_logical_flags;
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

  localparam instr_word_t AND_BASE  = 16'h5000;
  localparam instr_word_t ANDN_BASE = 16'h5200;
  localparam instr_word_t OR_BASE   = 16'h5400;
  localparam instr_word_t XOR_BASE  = 16'h5600;
  localparam instr_word_t ANDI_BASE = 16'h0B80;
  localparam instr_word_t ORI_BASE  = 16'h0BA0;
  localparam instr_word_t XORI_BASE = 16'h0BC0;

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

  // Seed ST (PUTST B0), run one register-logical op, snapshot ST (GETST B<snap>).
  function automatic int unsigned rr_case(input int unsigned p, input instr_word_t base,
                                          input reg_idx_t rs, input reg_idx_t rd, input reg_idx_t snap);
    p = place_word(p, 16'h01B0);                                    // PUTST B0 -> ST=seed
    p = place_word(p, base | (instr_word_t'(rs) << 5) | instr_word_t'(rd));
    p = place_word(p, 16'h0190 | instr_word_t'(snap));              // GETST B<snap>
    rr_case = p;
  endfunction
  // NOT A<rd> then snapshot.
  function automatic int unsigned not_case(input int unsigned p, input reg_idx_t rd, input reg_idx_t snap);
    p = place_word(p, 16'h01B0);                                    // PUTST B0
    p = place_word(p, 16'h03E0 | instr_word_t'(rd));               // NOT A<rd>
    p = place_word(p, 16'h0190 | instr_word_t'(snap));
    not_case = p;
  endfunction
  // Immediate-logical (ANDI/ORI/XORI IL): base | rd, + 32-bit immediate word (LO,HI).
  function automatic int unsigned imm_case(input int unsigned p, input instr_word_t base,
                                           input reg_idx_t rd, input logic [31:0] immfield, input reg_idx_t snap);
    p = place_word(p, 16'h01B0);                                    // PUTST B0
    u_mem.mem[p]   = base | instr_word_t'(rd);
    u_mem.mem[p+1] = immfield[15:0];
    u_mem.mem[p+2] = immfield[31:16];
    p = p + 3;
    p = place_word(p, 16'h0190 | instr_word_t'(snap));
    imm_case = p;
  endfunction

  int unsigned failures;
  task automatic check_st(input string label,
                          input logic [DATA_WIDTH-1:0] actual, input logic [DATA_WIDTH-1:0] expected);
    if (actual !== expected) begin
      $display("TEST_RESULT: FAIL: %s: expected ST=%08h actual=%08h (N/C/V must be preserved, only Z changes)",
               label, expected, actual);
      failures++;
    end
  endtask

  localparam logic [31:0] SEED   = 32'hD000_0030;   // N=1,C=1,Z=0,V=1
  localparam logic [31:0] NONZERO = 32'hD000_0030;  // Z stays 0
  localparam logic [31:0] ZERO    = 32'hF000_0030;  // Z set to 1

  initial begin : main
    int unsigned p;
    failures = 0;

    // Operand setup (MOVI clobbers flags; PUTST re-seeds before each op).
    p = 0;
    p = place_movi_il(p, REG_FILE_B, 4'd0, SEED);            // B0 = seed ST
    p = place_movi_il(p, REG_FILE_A, 4'd1, 32'hFFFF_0000);
    p = place_movi_il(p, REG_FILE_A, 4'd2, 32'h0000_FFFF);
    p = place_movi_il(p, REG_FILE_A, 4'd4, 32'hFFFF_FFFF);
    p = place_movi_il(p, REG_FILE_A, 4'd5, 32'hAAAA_AAAA);
    p = place_movi_il(p, REG_FILE_A, 4'd6, 32'hAAAA_AAAA);
    p = place_movi_il(p, REG_FILE_A, 4'd7, 32'h0000_0000);
    p = place_movi_il(p, REG_FILE_A, 4'd9, 32'h0000_FFFF);
    p = place_movi_il(p, REG_FILE_A, 4'd10, 32'h1234_0000);
    p = place_movi_il(p, REG_FILE_A, 4'd11, 32'hFFFF_FFFF);
    p = place_movi_il(p, REG_FILE_A, 4'd12, 32'hAAAA_AAAA);

    // Register-logical cases (snap -> B1..B5).
    p = rr_case (p, AND_BASE,  4'd1, 4'd2, 4'd1);   // 0xFFFF0000 & 0x0000FFFF = 0        -> Z=1
    p = rr_case (p, OR_BASE,   4'd1, 4'd9, 4'd2);   // 0xFFFF0000 | 0x0000FFFF = FFFFFFFF -> Z=0
    p = rr_case (p, XOR_BASE,  4'd5, 4'd6, 4'd3);   // AAAAAAAA ^ AAAAAAAA = 0            -> Z=1
    p = rr_case (p, ANDN_BASE, 4'd1, 4'd4, 4'd4);   // FFFFFFFF & ~FFFF0000 = 0000FFFF    -> Z=0 (pos)
    p = not_case(p,            4'd11,      4'd5);    // ~FFFFFFFF = 0                      -> Z=1

    // Immediate-logical cases (snap -> B6..B8).
    // ANDI stores ~K (P0003): to compute A10 & 0x0000FFFF, immfield = ~0x0000FFFF.
    p = imm_case(p, ANDI_BASE, 4'd10, ~32'h0000_FFFF, 4'd6); // 0x12340000 & 0x0000FFFF = 0 -> Z=1
    p = imm_case(p, ORI_BASE,  4'd7,  32'h0000_0001, 4'd7);  // 0 | 1 = 1                   -> Z=0 (pos)
    p = imm_case(p, XORI_BASE, 4'd12, 32'hAAAA_AAAA, 4'd8);  // AAAAAAAA ^ AAAAAAAA = 0     -> Z=1

    p = place_word(p, 16'hC0FF);   // halt

    repeat (3) @(posedge clk);
    rst = 1'b0;
    repeat (1500) @(posedge clk);
    #1;

    check_st("AND  -> 0",         u_core.u_regfile.b_regs[1], ZERO);
    check_st("OR   -> FFFFFFFF",  u_core.u_regfile.b_regs[2], NONZERO);
    check_st("XOR  -> 0",         u_core.u_regfile.b_regs[3], ZERO);
    check_st("ANDN -> 0000FFFF",  u_core.u_regfile.b_regs[4], NONZERO);
    check_st("NOT  -> 0",         u_core.u_regfile.b_regs[5], ZERO);
    check_st("ANDI -> 0",         u_core.u_regfile.b_regs[6], ZERO);
    check_st("ORI  -> 1",         u_core.u_regfile.b_regs[7], NONZERO);
    check_st("XORI -> 0",         u_core.u_regfile.b_regs[8], ZERO);

    // Sanity: results actually landed (proves the ops executed, not no-ops).
    if (u_core.u_regfile.a_regs[2]  !== 32'h0000_0000) begin $display("TEST_RESULT: FAIL: AND result"); failures++; end
    if (u_core.u_regfile.a_regs[9]  !== 32'hFFFF_FFFF) begin $display("TEST_RESULT: FAIL: OR result");  failures++; end
    if (u_core.u_regfile.a_regs[4]  !== 32'h0000_FFFF) begin $display("TEST_RESULT: FAIL: ANDN result"); failures++; end
    if (u_core.u_regfile.a_regs[11] !== 32'h0000_0000) begin $display("TEST_RESULT: FAIL: NOT result"); failures++; end

    if (illegal_w !== 1'b0) begin
      $display("TEST_RESULT: FAIL: illegal_opcode_o was set");
      failures++;
    end

    if (failures == 0) begin
      $display("TEST_RESULT: PASS (AND/ANDN/OR/XOR/NOT + ANDI/ORI/XORI: Z-only, N/C/V preserved)");
    end else begin
      $display("TEST_RESULT: FAIL: %0d check(s) failed", failures);
    end
    $finish;
  end

  initial begin : watchdog
    #3_000_000;
    $display("TEST_RESULT: FAIL: tb_logical_flags hard timeout");
    $fatal(1);
  end

endmodule : tb_logical_flags
