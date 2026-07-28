// -----------------------------------------------------------------------------
// tb_move_abs_wb_race.sv
//
// Discriminating regression test for the MOVE-field-load ack/writeback race
// found this session by an integration-level MAME<->RTL differential
// debugger (sim/tb_wolf_top_replay.sv, wolf_top level): `mv_load_data`
// (tms34010_core.sv, MOVE field-size machinery) was a pure `always_comb`
// function of the LIVE `mem_rdata_eff` bus with NO capture register, yet it
// fed `rf_wr_data`/`flag_input` for the MOVE field-load classes
// (MOVE @SAddr,Rd / MOVE *Rs(off),Rd / MOVE *Rs,Rd) at CORE_WRITEBACK — ONE
// CYCLE AFTER the CORE_MEMORY mem_ack pulse that made the operand valid.
// docs/architecture.md: "mem_ack ... one-cycle pulse: data valid / write
// done" — by WRITEBACK the bus may already reflect a different transaction.
//
// The bare-core testbenches (tb_move_abs, tb_wolf_cpu_replay, ...) never
// caught this because `sim_memory_model`'s registered `mem_rdata` output is
// simply never reassigned outside its own ack cycle, so it happens to HOLD
// the correct value one extra cycle by coincidence — masking the bug. The
// real wolf_mem/wolf_memsys bus genuinely advances (mem_rdata_eff reads the
// LIVE `mem_rdata` port whenever mem_req is low, per tms34010_core.sv's
// `assign mem_rdata_eff = mem_req ? ... : (... : mem_rdata)` mux, and
// CORE_WRITEBACK never asserts mem_req), exposing it.
//
// This TB reproduces that exposure directly at the bare-core level: it runs
// a single MOVE @SAddr,Rd, and on the cycle immediately AFTER the
// CORE_MEMORY ack (i.e. during CORE_WRITEBACK, before the register-file
// write posedge) it forces the top-level mem_rdata wire between the memory
// model and the core to a different value — simulating "the next
// transaction has already landed on the bus" — then releases it. A
// correctly-latching core must still write the ORIGINALLY fetched operand
// to Rd; a core that reads the live bus at WRITEBACK will write the
// mutated value instead.
//
// Mutation-tested: with the mv_load_data_q latch removed (rf_wr_data /
// flag_input reading the live `mv_load_data` again), this TB FAILS —
// Rd ends up holding the forced bus value (or its field-extension), not
// CORRECT_VAL, and the N flag (computed from the same stale/live path)
// flips too since CORRECT_VAL is positive and MUTATED_VAL is negative.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_move_abs_wb_race;
  import tms34010_pkg::*;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;

  logic                          mem_req;
  logic                          mem_we;
  logic [ADDR_WIDTH-1:0]         mem_addr;
  logic [FIELD_SIZE_WIDTH-1:0]   mem_size;
  logic [DATA_WIDTH-1:0]         mem_wdata;
  logic [DATA_WIDTH-1:0]         mem_rdata;   // TB-level wire — force target
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

  function automatic int unsigned place_word(input int unsigned p, input instr_word_t w);
    u_mem.mem[p] = w;  place_word = p + 1;
  endfunction
  // MOVE @SAddr,Rd (load): 0x05A0 | Rd, then addr LSW, addr MSW.
  function automatic int unsigned place_load_abs(input int unsigned p,
                                                 input reg_idx_t rd,
                                                 input logic [DATA_WIDTH-1:0] addr);
    u_mem.mem[p]     = 16'h05A0 | instr_word_t'(rd);
    u_mem.mem[p + 1] = addr[15:0];
    u_mem.mem[p + 2] = addr[31:16];
    place_load_abs = p + 3;
  endfunction
  function automatic instr_word_t getst_enc(input reg_idx_t rd);
    getst_enc = 16'h0180 | instr_word_t'(rd);
  endfunction

  int unsigned failures;
  task automatic check_reg(input string label,
                           input logic [DATA_WIDTH-1:0] actual, expected);
    if (actual !== expected) begin
      $display("TEST_RESULT: FAIL: %s: expected=%08h actual=%08h", label, expected, actual);
      failures++;
    end
  endtask
  task automatic check_bit(input string label, input logic actual, expected);
    if (actual !== expected) begin
      $display("TEST_RESULT: FAIL: %s: expected=%0b actual=%0b", label, expected, actual);
      failures++;
    end
  endtask

  localparam logic [DATA_WIDTH-1:0] SADDR       = 32'h0000_0800;  // word 128
  // CORRECT_VAL: the true operand at SADDR. Positive (N=0), non-zero (Z=0).
  localparam logic [DATA_WIDTH-1:0] CORRECT_VAL = 32'h1234_5678;
  // MUTATED_VAL: "the next transaction already landed" bus content forced
  // onto mem_rdata for the WRITEBACK cycle. Deliberately negative (N=1) and
  // a completely different pattern so any leakage is unmistakable.
  localparam logic [DATA_WIDTH-1:0] MUTATED_VAL = 32'hFEDC_BA98;

  // ---------------------------------------------------------------------------
  // Race injector: the cycle immediately after the CORE_MEMORY read ack
  // (i.e. the CORE_WRITEBACK cycle) is exactly when a correctly-latching
  // core no longer needs the bus, but a buggy combinational-only path would
  // still sample it. Force mem_rdata to MUTATED_VAL for exactly that cycle.
  // ---------------------------------------------------------------------------
  logic mem_load_ack;      // this edge: CORE_MEMORY ack for our load
  logic wb_race_active;    // next edge: CORE_WRITEBACK — inject the mutation

  assign mem_load_ack = (state_w == CORE_MEMORY) && mem_ack;

  always_ff @(posedge clk) begin
    if (rst) wb_race_active <= 1'b0;
    else     wb_race_active <= mem_load_ack;
  end

  always @(*) begin
    if (wb_race_active) force mem_rdata = MUTATED_VAL;
    else                release mem_rdata;
  end

  initial begin : main
    int unsigned p, i;
    failures = 0;
    for (i = 0; i < 512; i++) u_mem.mem[i] = 16'h0300;
    // Reset vector (P0001): the core boots by reading PC from bit-address
    // 0xFFFFFFE0, which sim_memory_model aliases to words DEPTH-2/DEPTH-1.
    u_mem.mem[510] = 16'h0000;   // reset vector low  half - PC = 0x00000000
    u_mem.mem[511] = 16'h0000;   // reset vector high half

    p = 0;
    // 32-bit field (F=0, FS0=0 encodes 32, FE0=0): matches tb_move_abs.
    p = place_word(p, 16'h0540);          // SETF FS=0, FE=0, F=0
    p = place_load_abs(p, 4'd2, SADDR);   // MOVE @SADDR,A2
    p = place_word(p, getst_enc(4'd3));   // A3 <- ST (snapshot N/Z from the load)
    p = place_word(p, 16'hC0FF);          // halt / self-spin

    // The true operand, preloaded directly into the backing store (not via
    // a prior MOVE store — keeps this TB minimal and focused purely on the
    // load-side ack/writeback race).
    u_mem.mem[SADDR >> 4]       = CORRECT_VAL[15:0];
    u_mem.mem[(SADDR >> 4) + 1] = CORRECT_VAL[31:16];

    repeat (3) @(posedge clk);
    rst = 1'b0;
    repeat (500) @(posedge clk);
    #1;

    // Rd must hold the ORIGINALLY fetched operand, not the bus content
    // forced onto mem_rdata one cycle after the ack.
    check_reg("A2 = CORRECT_VAL (not the post-ack bus mutation)",
              u_core.u_regfile.a_regs[2], CORRECT_VAL);
    // Flags (snapshotted into A3 via GETST right after the load) must also
    // reflect CORRECT_VAL (positive, non-zero: N=0, Z=0), not MUTATED_VAL
    // (negative: N=1).
    check_bit("N=0 (CORRECT_VAL is positive)",
              u_core.u_regfile.a_regs[3][ST_N_BIT], 1'b0);
    check_bit("Z=0 (CORRECT_VAL is non-zero)",
              u_core.u_regfile.a_regs[3][ST_Z_BIT], 1'b0);

    if (illegal_w !== 1'b0) begin
      $display("TEST_RESULT: FAIL: illegal_opcode_o was set");
      failures++;
    end

    if (failures == 0) begin
      $display("TEST_RESULT: PASS (MOVE @SAddr,Rd: ack-cycle operand survives a mem_rdata mutation injected on the following WRITEBACK cycle)");
    end else begin
      $display("TEST_RESULT: FAIL: %0d check(s) failed", failures);
    end
    $finish;
  end

  initial begin : watchdog
    #5_000_000;
    $display("TEST_RESULT: FAIL: tb_move_abs_wb_race hard timeout");
    $fatal(1);
  end

endmodule : tb_move_abs_wb_race
