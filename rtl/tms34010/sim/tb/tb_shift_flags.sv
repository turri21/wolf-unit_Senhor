// -----------------------------------------------------------------------------
// tb_shift_flags.sv
//
// TMS34010 shift/rotate STATUS semantics (MAME 34010ops.hxx):
//   SLL / SRL / RL : C, Z only        (N, V Unaffected)
//   SRA            : N, C, Z          (V Unaffected)
//   SLA            : N, C, Z, V       (V = arithmetic-shift overflow)
//
// The pre-fix RTL gave every shift the default full N/C/Z/V mask, so SLL/SRL/RL
// wrongly wrote N (=result[31]) and V(=0), SRA wrongly wrote V, and SLA's V was
// stuck at 0 (shifter A0009 deferral). The differential debugger caught the SLL
// case at ROM FFBAA680 (SLL #8, A0): MAME kept N=1 (ST 0x80200030), the RTL
// cleared it (0x00200030).
//
// Each op is run with ST pre-seeded (PUTST) so "Unaffected" bits must survive;
// the exact post-ST is asserted vs MAME. Fails on the unfixed RTL.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_shift_flags;
  import tms34010_pkg::*;

  logic clk = 1'b0, rst = 1'b1;
  always #5 clk = ~clk;
  logic mem_req, mem_we; logic [ADDR_WIDTH-1:0] mem_addr; logic [FIELD_SIZE_WIDTH-1:0] mem_size;
  logic [DATA_WIDTH-1:0] mem_wdata, mem_rdata; logic mem_ack;
  core_state_t state_w; logic [ADDR_WIDTH-1:0] pc_w; instr_word_t instr_w; logic illegal_w;
  tms34010_core u_core (.clk(clk), .rst(rst), .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
    .mem_size(mem_size), .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack),
    .state_o(state_w), .pc_o(pc_w), .instr_word_o(instr_w), .illegal_opcode_o(illegal_w));
  sim_memory_model #(.DEPTH_WORDS(256)) u_mem (.clk(clk), .rst(rst), .mem_req(mem_req), .mem_we(mem_we),
    .mem_addr(mem_addr), .mem_size(mem_size), .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack));

  function automatic int unsigned pmovi(input int unsigned p, input reg_file_t rf, input reg_idx_t i,
                                        input logic [DATA_WIDTH-1:0] imm);
    u_mem.mem[p]=16'h09E0|(instr_word_t'(rf)<<4)|instr_word_t'(i); u_mem.mem[p+1]=imm[15:0]; u_mem.mem[p+2]=imm[31:16];
    pmovi=p+3;
  endfunction
  function automatic int unsigned pw(input int unsigned p, input instr_word_t w); u_mem.mem[p]=w; pw=p+1; endfunction

  // seed ST (via MOVI B0 + PUTST B0), run one shift op, snapshot ST (GETST B<snap>).
  function automatic int unsigned scase(input int unsigned p, input logic [31:0] seed,
                                        input instr_word_t shift_word, input reg_idx_t snap);
    p = pmovi(p, REG_FILE_B, 4'd0, seed);       // B0 = seed ST
    p = pw  (p, 16'h01B0);                      // PUTST B0 -> ST=seed
    p = pw  (p, shift_word);                     // the shift/rotate op
    p = pw  (p, 16'h0190 | instr_word_t'(snap)); // GETST B<snap>
    scase = p;
  endfunction

  int unsigned failures;
  task automatic ck(input string s, input logic [DATA_WIDTH-1:0] a, input logic [DATA_WIDTH-1:0] e);
    if (a!==e) begin $display("TEST_RESULT: FAIL: %s expected ST=%08h actual=%08h", s, e, a); failures++; end
  endtask

  initial begin : main
    int unsigned p; int unsigned i;
    failures = 0;
    for (i=0;i<256;i++) u_mem.mem[i]=16'h0300;
    u_mem.mem[254]=16'h0000; u_mem.mem[255]=16'h0000;

    // Operands.
    p = 0;
    p = pmovi(p, REG_FILE_A, 4'd0, 32'h0000_007D);
    p = pmovi(p, REG_FILE_A, 4'd1, 32'h0000_007D);
    p = pmovi(p, REG_FILE_A, 4'd2, 32'h0000_0001);
    p = pmovi(p, REG_FILE_A, 4'd3, 32'h0000_007D);
    p = pmovi(p, REG_FILE_A, 4'd4, 32'h0000_0004);
    p = pmovi(p, REG_FILE_A, 4'd5, 32'h4000_0000);

    // Case A — exact anchor: SLL #8, A0. seed N=1,C=1,Z=0,V=0. -> N kept, C=0, Z=0, V kept.
    p = scase(p, 32'hC020_0030, 16'h2500, 4'd1);            // SLL #8,A0 ; snap B1
    // Case B — SLL #8, A1, seed V=1: N and V preserved.
    p = scase(p, 32'hD020_0030, 16'h2400|(8<<5)|4'd1, 4'd2); // SLL #8,A1 ; snap B2
    // Case C — SRL #1, A2 (0x1>>1=0): C=1 (bit0), Z=1; N,V preserved.
    // P0005: SRA/SRL K-forms store (32-amount) in the K field -> shift-by-1 = K 31.
    p = scase(p, 32'hD020_0030, 16'h2C00|(31<<5)|4'd2, 4'd3); // SRL #1,A2 ; snap B3
    // Case D — RL #8, A3 (rotate; K stored directly): C,Z only; N,V preserved.
    p = scase(p, 32'hD020_0030, 16'h3000|(8<<5)|4'd3, 4'd4); // RL #8,A3  ; snap B4
    // Case E — SRA #1, A4 (0x4>>1=0x2): N,C,Z set (N=0), V preserved(=1). K=31.
    p = scase(p, 32'hD020_0030, 16'h2800|(31<<5)|4'd4, 4'd5); // SRA #1,A4 ; snap B5
    // Case F — SLA #1, A5 (0x40000000<<1=0x80000000): overflow -> N=1,C=0,Z=0,V=1.
    p = scase(p, 32'h0020_0030, 16'h2000|(1<<5)|4'd5, 4'd6); // SLA #1,A5 ; snap B6

    p = pw(p, 16'hC0FF);

    repeat (3) @(posedge clk); rst = 1'b0;
    repeat (1200) @(posedge clk); #1;

    // Register results (prove the ops executed).
    ck("(reg) A0 SLL#8 -> 0x7D00", u_core.u_regfile.a_regs[0], 32'h0000_7D00);
    ck("(reg) A2 SRL#1 -> 0",      u_core.u_regfile.a_regs[2], 32'h0000_0000);
    ck("(reg) A4 SRA#1 -> 0x2",    u_core.u_regfile.a_regs[4], 32'h0000_0002);
    ck("(reg) A5 SLA#1 -> 0x80000000", u_core.u_regfile.a_regs[5], 32'h8000_0000);

    // ST outcomes vs MAME.
    ck("A: SLL #8 anchor (N kept)  == 0x80200030", u_core.u_regfile.b_regs[1], 32'h8020_0030);
    ck("B: SLL #8 (N,V kept)       == 0x90200030", u_core.u_regfile.b_regs[2], 32'h9020_0030);
    ck("C: SRL #1 ->0 (C,Z; N,V kept)== 0xF0200030", u_core.u_regfile.b_regs[3], 32'hF020_0030);
    ck("D: RL #8  (C,Z; N,V kept)  == 0x90200030", u_core.u_regfile.b_regs[4], 32'h9020_0030);
    ck("E: SRA #1 (N,C,Z; V kept)  == 0x10200030", u_core.u_regfile.b_regs[5], 32'h1020_0030);
    ck("F: SLA #1 overflow (V=1)   == 0x90200030", u_core.u_regfile.b_regs[6], 32'h9020_0030);

    if (illegal_w !== 1'b0) begin $display("TEST_RESULT: FAIL: illegal set"); failures++; end
    if (failures==0) $display("TEST_RESULT: PASS (SLL/SRL/RL C,Z-only; SRA N,C,Z; SLA N,C,Z,V-overflow)");
    else             $display("TEST_RESULT: FAIL: %0d check(s) failed", failures);
    $finish;
  end
  initial begin : wd #2_000_000; $display("TEST_RESULT: FAIL: tb_shift_flags timeout"); $fatal(1); end
endmodule : tb_shift_flags
