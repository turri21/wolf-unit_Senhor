// -----------------------------------------------------------------------------
// tb_move_abs_m2m_post.sv
//
// MOVE @SAddr,*Rd+ — absolute-to-indirect field move with destination
// postincrement. Texas Instruments 1988 TMS34010 User's Guide page 12-155:
//
//   field at SAddr -> *Rd
//   Rd + field size -> Rd
//   N/C/Z/V Unaffected
//
// This regression executes the exact NBA Hangtime L1.3 instruction stream
// observed on hardware and confirmed by MAME at PC FF806CF0:
//
//   D60E 2060 0100    MOVE @01002060h,*A14+,1
//
// FS1=0 encodes a 32-bit field. The test checks the literal decode, immediate
// word order, read/write bus addresses and sizes, copied value, A14+32
// writeback, unchanged status, and retirement into the following GETST.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_move_abs_m2m_post;
  import tms34010_pkg::*;

  localparam int unsigned DEPTH_WORDS = 4096;
  localparam logic [DATA_WIDTH-1:0] SRC_ADDR = 32'h0100_2060;
  localparam logic [DATA_WIDTH-1:0] DST_ADDR = 32'h0000_3000;
  localparam int unsigned SRC_WORD = 12'h206;
  localparam int unsigned DST_WORD = 12'h300;
  localparam logic [DATA_WIDTH-1:0] SOURCE_VALUE = 32'h89AB_CDEF;
  // FS1[10:6]=0 means 32 bits. Seed alternating architectural flags so an
  // accidental MOVE flag update is visible: N=1, C=0, Z=1, V=0.
  localparam logic [DATA_WIDTH-1:0] ST_SEED = 32'hA000_0000;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;

  logic                        mem_req;
  logic                        mem_we;
  logic [ADDR_WIDTH-1:0]       mem_addr;
  logic [FIELD_SIZE_WIDTH-1:0] mem_size;
  logic [DATA_WIDTH-1:0]       mem_wdata;
  logic [DATA_WIDTH-1:0]       mem_rdata;
  logic                        mem_ack;
  core_state_t                 state_w;
  logic [ADDR_WIDTH-1:0]       pc_w;
  instr_word_t                 instr_w;
  logic                        illegal_w;

  tms34010_core u_core (
    .clk(clk), .ce_cpu(1'b1), .ce_pix(1'b1), .rst(rst),
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_size(mem_size),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack),
    .state_o(state_w), .pc_o(pc_w), .instr_word_o(instr_w), .illegal_opcode_o(illegal_w),
    .dpystrt_o(), .dpyadr_o(), .vblank_start_o(), .lint1_in(1'b0)
  );

  sim_memory_model #(.DEPTH_WORDS(DEPTH_WORDS)) u_mem (
    .clk(clk), .rst(rst),
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_size(mem_size),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack)
  );

  function automatic instr_word_t movi_il_enc(input reg_file_t rf, input reg_idx_t rd);
    movi_il_enc = 16'h09E0 | (instr_word_t'(rf) << 4) | instr_word_t'(rd);
  endfunction

  function automatic instr_word_t putst_enc(input reg_file_t rf, input reg_idx_t rs);
    putst_enc = 16'h01A0 | (instr_word_t'(rf) << 4) | instr_word_t'(rs);
  endfunction

  function automatic instr_word_t getst_enc(input reg_file_t rf, input reg_idx_t rd);
    getst_enc = 16'h0180 | (instr_word_t'(rf) << 4) | instr_word_t'(rd);
  endfunction

  function automatic int unsigned place_movi_il(input int unsigned p,
                                                input reg_file_t rf,
                                                input reg_idx_t rd,
                                                input logic [DATA_WIDTH-1:0] imm);
    u_mem.mem[p]     = movi_il_enc(rf, rd);
    u_mem.mem[p + 1] = imm[15:0];
    u_mem.mem[p + 2] = imm[31:16];
    place_movi_il = p + 3;
  endfunction

  function automatic int unsigned place_word(input int unsigned p, input instr_word_t word);
    u_mem.mem[p] = word;
    place_word = p + 1;
  endfunction

  int unsigned d60e_ack_count;
  logic [ADDR_WIDTH-1:0] read_addr_seen;
  logic [ADDR_WIDTH-1:0] write_addr_seen;
  logic [FIELD_SIZE_WIDTH-1:0] read_size_seen;
  logic [FIELD_SIZE_WIDTH-1:0] write_size_seen;
  logic read_we_seen;
  logic write_we_seen;

  always @(posedge clk) begin
    if (rst) begin
      d60e_ack_count <= 0;
      read_addr_seen <= '0;
      write_addr_seen <= '0;
      read_size_seen <= '0;
      write_size_seen <= '0;
      read_we_seen <= 1'b1;
      write_we_seen <= 1'b0;
    end else if (state_w == CORE_MEMORY && mem_ack && instr_w == 16'hD60E) begin
      if (d60e_ack_count == 0) begin
        read_addr_seen <= mem_addr;
        read_size_seen <= mem_size;
        read_we_seen <= mem_we;
      end else if (d60e_ack_count == 1) begin
        write_addr_seen <= mem_addr;
        write_size_seen <= mem_size;
        write_we_seen <= mem_we;
      end
      d60e_ack_count <= d60e_ack_count + 1;
    end
  end

  int unsigned failures;

  task automatic check_value(input string label,
                             input logic [DATA_WIDTH-1:0] actual,
                             input logic [DATA_WIDTH-1:0] expected);
    if (actual !== expected) begin
      $display("TEST_RESULT: FAIL: %s: expected=%08h actual=%08h", label, expected, actual);
      failures++;
    end
  endtask

  task automatic check_size(input string label,
                            input logic [FIELD_SIZE_WIDTH-1:0] actual,
                            input logic [FIELD_SIZE_WIDTH-1:0] expected);
    if (actual !== expected) begin
      $display("TEST_RESULT: FAIL: %s: expected=%0d actual=%0d", label, expected, actual);
      failures++;
    end
  endtask

  task automatic check_bit(input string label, input logic actual, input logic expected);
    if (actual !== expected) begin
      $display("TEST_RESULT: FAIL: %s: expected=%0b actual=%0b", label, expected, actual);
      failures++;
    end
  endtask

  initial begin : main
    int unsigned p;
    int unsigned i;

    failures = 0;
    for (i = 0; i < DEPTH_WORDS; i++) u_mem.mem[i] = 16'h0300;
    // Reset vector aliases to the final two words in sim_memory_model.
    u_mem.mem[DEPTH_WORDS - 2] = 16'h0000;
    u_mem.mem[DEPTH_WORDS - 1] = 16'h0000;

    // Exact Hangtime absolute source address aliases to word 0x206 in this
    // finite model. Keep it far from the program and destination regions.
    u_mem.mem[SRC_WORD]     = SOURCE_VALUE[15:0];
    u_mem.mem[SRC_WORD + 1] = SOURCE_VALUE[31:16];
    u_mem.mem[DST_WORD]     = 16'h1357;
    u_mem.mem[DST_WORD + 1] = 16'h2468;

    p = 0;
    p = place_movi_il(p, REG_FILE_A, 4'd14, DST_ADDR);  // A14 = destination pointer
    p = place_movi_il(p, REG_FILE_B, 4'd0, ST_SEED);    // seed loaded before PUTST
    p = place_word(p, putst_enc(REG_FILE_B, 4'd0));     // FS1=32; known N/C/Z/V

    // Literal NBA Hangtime L1.3 words from FF806CF0.
    p = place_word(p, 16'hD60E);
    p = place_word(p, 16'h2060);
    p = place_word(p, 16'h0100);

    // Reaching this proves the three-word instruction retired at the correct
    // boundary. GETST itself leaves status unchanged.
    p = place_word(p, getst_enc(REG_FILE_A, 4'd13));
    p = place_word(p, 16'hC0FF);                        // JRUC self-spin

    repeat (3) @(posedge clk);
    rst = 1'b0;
    repeat (2000) @(posedge clk);
    #1;

    check_value("destination received source field",
                {u_mem.mem[DST_WORD + 1], u_mem.mem[DST_WORD]}, SOURCE_VALUE);
    check_value("absolute source remained unchanged",
                {u_mem.mem[SRC_WORD + 1], u_mem.mem[SRC_WORD]}, SOURCE_VALUE);
    check_value("A14 postincremented by 32 bits",
                u_core.u_regfile.a_regs[14], DST_ADDR + 32'd32);
    check_value("N/C/Z/V and full ST remained unchanged",
                u_core.u_regfile.a_regs[13], ST_SEED);

    if (d60e_ack_count != 2) begin
      $display("TEST_RESULT: FAIL: D60E expected 2 memory acks, observed %0d", d60e_ack_count);
      failures++;
    end
    check_value("D60E read used exact @01002060 source", read_addr_seen, SRC_ADDR);
    check_value("D60E write used preincrement A14", write_addr_seen, DST_ADDR);
    check_size("D60E read field size", read_size_seen, 6'd32);
    check_size("D60E write field size", write_size_seen, 6'd32);
    check_bit("D60E first transaction is read", read_we_seen, 1'b0);
    check_bit("D60E second transaction is write", write_we_seen, 1'b1);
    check_bit("D60E did not raise illegal opcode", illegal_w, 1'b0);

    if (failures == 0) begin
      $display("TEST_RESULT: PASS (Hangtime D60E MOVE @01002060h,*A14+,1 exact sequence)");
    end else begin
      $display("TEST_RESULT: FAIL: %0d check(s) failed", failures);
    end
    $finish;
  end

  initial begin : watchdog
    #5_000_000;
    $display("TEST_RESULT: FAIL: tb_move_abs_m2m_post hard timeout");
    $fatal(1);
  end

endmodule : tb_move_abs_m2m_post
