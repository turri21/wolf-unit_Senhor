// -----------------------------------------------------------------------------
// tb_movb_off_m2m.sv
//
// Exact NBA Hangtime L1.3 sequence captured by DIAG_ILLEGAL at FF920CB0:
//
//   BC08 0067 00F7    MOVB *A0(67h),*A8(F7h)
//
// Original source: CODE113L/PLYR3.ASM line 345,
//   movb *a0(ICTRL+7),*a8(OCTRL+7)
// where ICTRL=60h and OCTRL=F0h. This copies the image's Z-compression/BPP
// control byte into the animated ball object's DMA control field.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_movb_off_m2m;
  import tms34010_pkg::*;

  localparam logic [ADDR_WIDTH-1:0] SRC_BASE = 32'h0000_0800;
  localparam logic [ADDR_WIDTH-1:0] DST_BASE = 32'h0000_0900;
  localparam logic [ADDR_WIDTH-1:0] SRC_ADDR = 32'h0000_0867;
  localparam logic [ADDR_WIDTH-1:0] DST_ADDR = 32'h0000_09F7;
  localparam logic [7:0]            BYTE_VALUE = 8'hA5;

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
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
    .mem_size(mem_size), .mem_wdata(mem_wdata), .mem_rdata(mem_rdata),
    .mem_ack(mem_ack), .state_o(state_w), .pc_o(pc_w),
    .instr_word_o(instr_w), .illegal_opcode_o(illegal_w),
    .dpystrt_o(), .dpyadr_o(), .vblank_start_o(), .lint1_in(1'b0)
  );

  sim_memory_model #(.DEPTH_WORDS(256)) u_mem (
    .clk(clk), .rst(rst),
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
    .mem_size(mem_size), .mem_wdata(mem_wdata), .mem_rdata(mem_rdata),
    .mem_ack(mem_ack)
  );

  function automatic instr_word_t movi_il_enc(input reg_idx_t idx);
    movi_il_enc = 16'h09E0 | instr_word_t'(idx);
  endfunction

  function automatic instr_word_t getst_enc(input reg_idx_t idx);
    getst_enc = 16'h0180 | instr_word_t'(idx);
  endfunction

  function automatic int unsigned place_word(input int unsigned p,
                                               input instr_word_t word);
    u_mem.mem[p] = word;
    place_word = p + 1;
  endfunction

  function automatic int unsigned place_movi_il(input int unsigned p,
                                                  input reg_idx_t idx,
                                                  input logic [31:0] value);
    u_mem.mem[p]     = movi_il_enc(idx);
    u_mem.mem[p + 1] = value[15:0];
    u_mem.mem[p + 2] = value[31:16];
    place_movi_il = p + 3;
  endfunction

  int unsigned failures;
  int unsigned bc08_ack_count;
  logic [ADDR_WIDTH-1:0] read_addr_seen;
  logic [ADDR_WIDTH-1:0] write_addr_seen;
  logic [FIELD_SIZE_WIDTH-1:0] read_size_seen;
  logic [FIELD_SIZE_WIDTH-1:0] write_size_seen;
  logic [DATA_WIDTH-1:0] write_data_seen;
  logic read_we_seen;
  logic write_we_seen;

  always_ff @(posedge clk) begin
    if (rst) begin
      bc08_ack_count <= 0;
      read_addr_seen <= '0;
      write_addr_seen <= '0;
      read_size_seen <= '0;
      write_size_seen <= '0;
      write_data_seen <= '0;
      read_we_seen <= 1'b1;
      write_we_seen <= 1'b0;
    end else if (state_w == CORE_MEMORY && mem_ack && instr_w == 16'hBC08) begin
      if (bc08_ack_count == 0) begin
        read_addr_seen <= mem_addr;
        read_size_seen <= mem_size;
        read_we_seen <= mem_we;
      end else if (bc08_ack_count == 1) begin
        write_addr_seen <= mem_addr;
        write_size_seen <= mem_size;
        write_data_seen <= mem_wdata;
        write_we_seen <= mem_we;
      end
      bc08_ack_count <= bc08_ack_count + 1;
    end
  end

  task automatic check_value(input string label,
                             input logic [31:0] actual,
                             input logic [31:0] expected);
    if (actual !== expected) begin
      $display("TEST_RESULT: FAIL: %s expected=%08h actual=%08h",
               label, expected, actual);
      failures++;
    end
  endtask

  task automatic check_size(input string label,
                            input logic [FIELD_SIZE_WIDTH-1:0] actual,
                            input logic [FIELD_SIZE_WIDTH-1:0] expected);
    if (actual !== expected) begin
      $display("TEST_RESULT: FAIL: %s expected=%0d actual=%0d",
               label, expected, actual);
      failures++;
    end
  endtask

  task automatic check_bit(input string label, input logic actual, expected);
    if (actual !== expected) begin
      $display("TEST_RESULT: FAIL: %s expected=%0b actual=%0b",
               label, expected, actual);
      failures++;
    end
  endtask

  initial begin : main
    int unsigned p;
    int unsigned i;
    failures = 0;

    for (i = 0; i < 256; i++) u_mem.mem[i] = 16'h0300;
    u_mem.mem[254] = 16'h0000;
    u_mem.mem[255] = 16'h0000;

    // Source byte A5 at bit address 0x867 (word 0x86, bit offset 7).
    // Destination at 0x9F7 starts clear.
    u_mem.mem[16'h0086] = 16'h5280;
    u_mem.mem[16'h009F] = 16'h0000;

    p = 0;
    p = place_movi_il(p, 4'd0, SRC_BASE);
    p = place_movi_il(p, 4'd8, DST_BASE);
    p = place_word(p, getst_enc(4'd1));
    p = place_word(p, 16'hBC08);
    p = place_word(p, 16'h0067);
    p = place_word(p, 16'h00F7);
    p = place_word(p, getst_enc(4'd2));
    p = place_word(p, 16'hC0FF);

    repeat (3) @(posedge clk);
    rst = 1'b0;
    repeat (800) @(posedge clk);
    #1;

    if (bc08_ack_count != 2) begin
      $display("TEST_RESULT: FAIL: BC08 expected 2 memory acks, observed %0d",
               bc08_ack_count);
      failures++;
    end
    check_value("BC08 exact source address", read_addr_seen, SRC_ADDR);
    check_value("BC08 exact destination address", write_addr_seen, DST_ADDR);
    check_size("BC08 source field size", read_size_seen, 6'd8);
    check_size("BC08 destination field size", write_size_seen, 6'd8);
    check_bit("BC08 first transaction is read", read_we_seen, 1'b0);
    check_bit("BC08 second transaction is write", write_we_seen, 1'b1);
    check_value("BC08 copied right-justified byte", write_data_seen,
                {{24{1'b0}}, BYTE_VALUE});
    check_value("BC08 source pointer unchanged", u_core.u_regfile.a_regs[0], SRC_BASE);
    check_value("BC08 destination pointer unchanged", u_core.u_regfile.a_regs[8], DST_BASE);
    check_value("BC08 flags/status unchanged", u_core.u_regfile.a_regs[2],
                u_core.u_regfile.a_regs[1]);
    check_bit("BC08 did not raise illegal opcode", illegal_w, 1'b0);

    // At bit offset 7, byte A5 occupies word bits [14:7].
    if (u_mem.mem[16'h009F] !== 16'h5280) begin
      $display("TEST_RESULT: FAIL: BC08 destination word expected=5280 actual=%04h",
               u_mem.mem[16'h009F]);
      failures++;
    end

    if (failures == 0) begin
      $display("TEST_RESULT: PASS (Hangtime BC08 0067 00F7 MOVB exact sequence)");
    end else begin
      $display("TEST_RESULT: FAIL: %0d check(s) failed", failures);
    end
    $finish;
  end

  initial begin : watchdog
    #1_000_000;
    $display("TEST_RESULT: FAIL: tb_movb_off_m2m hard timeout");
    $fatal(1);
  end

endmodule : tb_movb_off_m2m
