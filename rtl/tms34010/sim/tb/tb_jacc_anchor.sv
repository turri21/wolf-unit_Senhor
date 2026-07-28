// tb_jacc_anchor.sv — reproduce the char-select JAEQ divergence (0xCA80).
// Anchor: JAEQ (cc=EQ=0xA, disp=0x80 -> 3-word absolute) with ST=0xC0200030
// (N=1,C=1,Z=0,V=0). EQ is FALSE (Z=0) -> NOT taken -> must fall through the
// 3-word instruction (opcode + 2 address words). A 1-word mis-decode would
// instead execute the address low word as an opcode.
`timescale 1ns/1ps
module tb_jacc_anchor;
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

  int unsigned failures;
  task automatic ck(input string s, input logic [DATA_WIDTH-1:0] a, input logic [DATA_WIDTH-1:0] e);
    if (a!==e) begin $display("TEST_RESULT: FAIL: %s expected=%08h actual=%08h", s, e, a); failures++; end
  endtask

  initial begin : main
    int unsigned p; int unsigned i;
    failures = 0;
    for (i=0;i<256;i++) u_mem.mem[i]=16'h0300;   // NOP fill
    u_mem.mem[254]=16'h0000; u_mem.mem[255]=16'h0000;  // reset vector -> word 0

    // ---- Not-taken anchor (Z=0): JAEQ must fall through 3 words ----
    p = 0;
    p = pmovi(p, REG_FILE_B, 4'd0, 32'hC020_0030);  // B0 = ST seed (Z=0)
    p = pw  (p, 16'h01B0);                          // PUTST B0 -> ST=0xC0200030
    // JAEQ + 32-bit address. Low addr word = 0xC0FF: if the RTL wrongly treats
    // 0xCA80 as 1-word, PC lands here and executes 0xC0FF (JRUC -1 = halt loop),
    // so the fall-through MOVI below never runs (A1 stays 0).
    p = pw  (p, 16'hCA80);                          // JAEQ (disp=0x80)
    p = pw  (p, 16'hC0FF);                          // address LO (data when 3-word)
    p = pw  (p, 16'h0000);                          // address HI
    p = pmovi(p, REG_FILE_A, 4'd1, 32'hFA11_FA11);  // fall-through sentinel (word W+3)
    p = pw  (p, 16'hC0FF);                          // halt

    repeat (3) @(posedge clk); rst = 1'b0;
    repeat (600) @(posedge clk); #1;

    // Correct 3-word not-taken fall-through => A1 written.
    ck("JAEQ not-taken falls through 3 words (A1)", u_core.u_regfile.a_regs[1], 32'hFA11_FA11);
    if (illegal_w !== 1'b0) begin $display("TEST_RESULT: FAIL: illegal set"); failures++; end

    if (failures==0) $display("TEST_RESULT: PASS (JAEQ Z=0 not-taken: 3-word fall-through correct)");
    else             $display("TEST_RESULT: FAIL: %0d check(s) failed", failures);
    $finish;
  end
  initial begin : wd #2_000_000; $display("TEST_RESULT: FAIL: tb_jacc_anchor timeout"); $fatal(1); end
endmodule : tb_jacc_anchor
