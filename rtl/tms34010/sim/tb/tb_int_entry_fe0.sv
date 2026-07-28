// -----------------------------------------------------------------------------
// tb_int_entry_fe0.sv
//
// DISCRIMINATING interrupt-entry ST test — proves the GSP resets the WHOLE
// status register (to 0x00000010) on interrupt entry, NOT just clearing ST.IE.
//
// Spec: 1988 UG §8.4 "Interrupt Processing" (page 8-5). When the GSP takes an
// interrupt it (step 2) pushes the full ST, then (step 3) replaces the ST so
// that at the first instruction of the ISR: "All interrupts are disabled;
// Field 0 is 16 bits long and is ZERO extended; Field 1 is 32 bits long and is
// zero extended." i.e. ST <- 0x00000010 (IE=0, FE0=0, FS0=16, FE1=0, FS1=0,
// flags=0). MAME check_interrupt() -> RESET_ST() -> SET_ST(0x00000010).
//
// This is the case tb_int_entry could NOT catch: there the pre-interrupt ST is
// 0x00200010 (FE0 already 0), so "clear IE only" and "reset to 0x10" collapse
// to the same 0x10. Here we FIRST set FE0=1 (via SETF FS0=16,FE0=1 = 0x0570)
// so the pre-interrupt ST is 0x00200030. The two behaviours now diverge:
//   - correct  (ST <- reset 0x10):        post-entry ST = 0x00000010
//   - the bug  (ST <- ST & ~IE, A0030):   post-entry ST = 0x00000030  (FE0 kept)
// The final ST == 0x10 check FAILS if the CORE_INT_DONE st_write_data is
// reverted to `st_value & ~(1<<ST_IE_BIT)` — this is the mutation test.
//
// (DI = display interrupt, bit 10, vector 0xFFFFFEA0. ISR = MOVI A5,0xBEEF; the
//  MOVI leaves FE0/FS0 untouched and its N/Z from 0xBEEF are 0, so a correct
//  entry yields ST == 0x00000010 exactly.)
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_int_entry_fe0;
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

  // 1024 words → word_idx = mem_addr[13:4]. DI vector 0xFFFFFEA0 aliases to
  // (0xFFFFFEA0>>4)&0x3FF = 0x3EA = 1002 (low half), 1003 (high half).
  sim_memory_model #(.DEPTH_WORDS(1024)) u_mem (
    .clk(clk), .rst(rst),
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_size(mem_size),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack)
  );

  function automatic instr_word_t movi_il_enc(input reg_idx_t i);
    movi_il_enc = 16'h09E0 | instr_word_t'(i);
  endfunction
  function automatic int unsigned place_movi_il(input int unsigned p,
                                                input reg_idx_t i,
                                                input logic [DATA_WIDTH-1:0] imm);
    u_mem.mem[p]     = movi_il_enc(i);
    u_mem.mem[p + 1] = imm[15:0];
    u_mem.mem[p + 2] = imm[31:16];
    place_movi_il = p + 3;
  endfunction
  function automatic int unsigned place_word(input int unsigned p, input instr_word_t w);
    u_mem.mem[p] = w; place_word = p + 1;
  endfunction
  // MOVE Rs,@DAddr store: 0x0580 | Rs, then addr LSW, MSW.
  function automatic int unsigned place_store_abs(input int unsigned p,
                                                  input reg_idx_t rs,
                                                  input logic [31:0] addr);
    u_mem.mem[p]     = 16'h0580 | instr_word_t'(rs);
    u_mem.mem[p + 1] = addr[15:0];
    u_mem.mem[p + 2] = addr[31:16];
    place_store_abs = p + 3;
  endfunction

  int unsigned failures;
  task automatic check_reg(input string label,
                           input logic [DATA_WIDTH-1:0] actual, expected);
    if (actual !== expected) begin
      $display("TEST_RESULT: FAIL: %s: expected=%08h actual=%08h", label, expected, actual);
      failures++;
    end
  endtask

  localparam logic [DATA_WIDTH-1:0] SP_INIT    = 32'h0000_0800; // word 128
  localparam logic [DATA_WIDTH-1:0] SERVICE_PC = 32'h0000_0640; // word 100 (ISR)
  localparam logic [31:0] A_INTENB  = IO_BASE_ADDR + (IO_IDX_INTENB  << 4); // C0000110
  localparam logic [31:0] A_INTPEND = IO_BASE_ADDR + (IO_IDX_INTPEND << 4); // C0000120
  localparam logic [15:0] DI_MASK   = 16'(1 << INT_DI_BIT);                 // 0x0400
  // SETF FS0=16, FE0=1, F=0 : encoding 0000 01F1 01FE FFFF -> 0x0570.
  localparam logic [15:0] SETF_FE0  = 16'h0570;
  localparam int unsigned VEC_WORD_LO = 1002;
  localparam int unsigned VEC_WORD_HI = 1003;

  initial begin : main
    int unsigned p, i, marker_word;
    logic [DATA_WIDTH-1:0] pushed_pc, pushed_st;
    failures = 0;

    for (i = 0; i < 1024; i++) u_mem.mem[i] = 16'h0300; // NOP fill
    u_mem.mem[1022] = 16'h0000;   // reset vector low  half - PC = 0x00000000
    u_mem.mem[1023] = 16'h0000;   // reset vector high half

    // ---- ISR at word 100: A5 <- 0xBEEF, then halt ----------------------
    // MOVI leaves FE0/FS0 unchanged; 0xBEEF is positive/nonzero so N=Z=0.
    p = 100;
    p = place_movi_il(p, 4'd5, 32'h0000_BEEF);
    u_mem.mem[p] = 16'hC0FF;

    // ---- Trap vector (DI) = SERVICE_PC ---------------------------------
    u_mem.mem[VEC_WORD_LO] = SERVICE_PC[15:0];
    u_mem.mem[VEC_WORD_HI] = SERVICE_PC[31:16];

    // ---- Main program at word 0 ----------------------------------------
    p = 0;
    // SP <- SP_INIT (MOVI A2, SP_INIT ; MOVE A2,A15 = 0x4C4F).
    p = place_movi_il(p, 4'd2, SP_INIT);
    p = place_word(p, 16'h4C4F);
    // Set FE0=1 (FS0=16). This is the bit the interrupt entry must clear.
    p = place_word(p, SETF_FE0);
    // INTENB.DI <- 1 (enable display interrupt).
    p = place_movi_il(p, 4'd0, {16'h0, DI_MASK});
    p = place_store_abs(p, 4'd0, A_INTENB);
    // DEVICE-SET DI (repaired 2026-07-27). INTPEND.DI is device-set and
    // write-zero-to-clear: SOFTWARE CANNOT SET IT (gospel tms34010.cpp:1348-1356,
    // "WVP and DIP can only have 0's written to them"). This bench used to request
    // the interrupt by STORING DI_MASK to INTPEND, which only worked because the
    // core had the matching defect -- the test encoded the bug, so landing the
    // correct write mask turned it red. Raised via the real device path below
    // instead; every assertion is unchanged.
    // NARC-specific vs the Y-unit donor's `force dpyint_event`: our strobe is
    // dpyint_pulse AND the DI set is gated on VTOTAL != 0 (io_regs :211), so both
    // device-side signals are driven. Neither uses the software write path.
    // EINT — set ST.IE. The interrupt must be taken at the NEXT fetch.
    p = place_word(p, 16'h0D60);
    // Marker that MUST be skipped (interrupt diverts before it).
    marker_word = p;
    p = place_movi_il(p, 4'd6, 32'h0000_DEAD);
    p = place_word(p, 16'hC0FF);     // halt (only reached if interrupt missed)

    repeat (3) @(posedge clk);
    rst = 1'b0;
    // device raises DI (see the note above): VTOTAL non-zero + one dpyint strobe
    repeat (2) @(negedge clk);
    force u_core.u_io_regs.io_reg[IO_IDX_VTOTAL] = 16'd256;
    @(negedge clk); force u_core.u_io_regs.dpyint_pulse = 1'b1;
    @(posedge clk); #1; release u_core.u_io_regs.dpyint_pulse;
    @(negedge clk); release u_core.u_io_regs.io_reg[IO_IDX_VTOTAL];
    repeat (3000) @(posedge clk);
    #1;

    // -------- Checks ----------------------------------------------------
    // PC reached the ISR via the vector → A5 = 0xBEEF.
    check_reg("INT-FE0: ISR executed (A5 = 0xBEEF)",
              u_core.u_regfile.a_regs[5], 32'h0000_BEEF);
    // Marker after EINT was skipped → A6 still 0 (not 0xDEAD).
    check_reg("INT-FE0: marker after EINT skipped (A6 = 0)",
              u_core.u_regfile.a_regs[6], 32'h0000_0000);
    // SP decremented by 64 (two 32-bit pushes).
    check_reg("INT-FE0: SP <- SP_INIT - 64",
              u_core.u_regfile.sp_q, SP_INIT - 32'd64);

    // *** THE DISCRIMINATING CHECK ***
    // Interrupt entry resets the WHOLE ST to 0x00000010, clearing FE0 (bit 5).
    // With the A0030 "clear IE only" bug the ST would be 0x00000030 here.
    check_reg("INT-FE0: entry resets ST to 0x10 (FE0 CLEARED, not preserved)",
              u_core.u_status_reg.st_q, 32'h0000_0010);
    // Redundant, sharper assertion on the exact bit under test.
    if (u_core.u_status_reg.st_q[ST_FE0_BIT] !== 1'b0) begin
      $display("TEST_RESULT: FAIL: INT-FE0: ST.FE0 (bit 5) not cleared on interrupt entry (st=%08h)",
               u_core.u_status_reg.st_q);
      failures++;
    end

    // Pushed PC at SP-32 (words 126/127) = marker address (resume PC).
    pushed_pc = {u_mem.mem[127], u_mem.mem[126]};
    check_reg("INT-FE0: pushed PC = marker (resume) address",
              pushed_pc, 32'(marker_word) << 4);
    // Pushed ST at SP-64 = the FULL old ST (IE=1, FE0=1, FS0=16) = 0x00200030,
    // saved BEFORE the reset — RETI must restore FE0 exactly.
    pushed_st = {u_mem.mem[125], u_mem.mem[124]};
    check_reg("INT-FE0: pushed ST = full old ST incl FE0 (0x00200030)",
              pushed_st, 32'h0020_0030);

    if (illegal_w !== 1'b0) begin
      $display("TEST_RESULT: FAIL: illegal_opcode_o was set");
      failures++;
    end

    if (failures == 0)
      $display("TEST_RESULT: PASS (interrupt entry resets ST->0x10, FE0 cleared; full old ST pushed)");
    else
      $display("TEST_RESULT: FAIL: %0d check(s) failed", failures);
    $finish;
  end

  initial begin : watchdog
    #500_000;
    $display("TEST_RESULT: FAIL: tb_int_entry_fe0 hard timeout");
    $fatal(1);
  end

endmodule : tb_int_entry_fe0
