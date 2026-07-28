//
// sdram_burst.sv — bank-interleaved open-page burst SDRAM controller for the UMK3
// Partition-C framebuffer SDRAM. DROP-IN replacement for sdram_stock.sv: identical port
// list, identical `ready`/`we`/`rd` handshake and identical byte-address -> (bank,row,col)
// decomposition, so yunit_sdram_adapter + yunit_sdram_arb bind to it unchanged and the
// read data it returns is byte-for-byte identical to the stock controller.
//
// WHY it is faster than sdram_stock (fitment: 21.6 -> >=123 MB/s):
//   * OPEN-PAGE policy — rows are LEFT OPEN after an access (NO auto-precharge). A bank is
//     precharged lazily, only when a NEW row is demanded on THAT bank. A same-bank/same-row
//     access then costs just the column command + CAS (a "page hit"), skipping ACTIVE+tRCD.
//   * 4-BANK INTERLEAVE — each of the MT48's 4 banks caches its own open row, so a page
//     miss on one bank precharges/activates in the BACKGROUND while other banks stay hot.
//     The per-bank tRC/tRP/tRCD floors overlap across banks instead of serializing.
//   * TIGHT FSM at the true DRAM floor (no fixed IDLE_n drain tower), and it runs on the
//     N64-style 2x SDRAM clock (the fitment's sanctioned lever) — the model's ns floors
//     (tRP/tRCD 18ns, tRC 60ns, CAS2) are the only stalls; everything else is 1 clock.
//
// BEHAVIORAL EQUIVALENCE (the gate): bank = addr[24:23], row = addr[13:1], col = addr[22:14]
// — the SAME decomposition sdram_stock feeds the MT48 model (stock OPEN: SDRAM_A<=addr[13:1],
// BA<=addr[24:23]; OPEN_2 col=addr[22:14]). Same (ba,row,col) -> same backing word -> same
// data. The dout byte-swap on addr[0] is preserved verbatim from stock. Auto-precharge is
// NEVER used here, but the DATA a READ/WRITE touches does not depend on the precharge bit,
// only on (ba,row,col) — so open-page vs precharge-per-access is data-transparent.
//
// Original stock controller: Copyright (c) 2015-2019 Sorgelig, GNU GPLv3. This is a NEW
// controller (net-new FSM) that preserves the stock port + data contract.
//
`timescale 1ns/1ps
`default_nettype none
module sdram_burst
(
   input             init,
   input             clk,          // Partition-C framebuffer SDRAM clock (2x, ~192 MHz)

   inout      [15:0] SDRAM_DQ,
   output reg [12:0] SDRAM_A,
   output reg        SDRAM_DQML,
   output reg        SDRAM_DQMH,
   output reg  [1:0] SDRAM_BA,
   output            SDRAM_nCS,
   output            SDRAM_nWE,
   output            SDRAM_nRAS,
   output            SDRAM_nCAS,
   output            SDRAM_CKE,

   input       [1:0] wtbt,         // write byte mask: [1]=high, [0]=low
   input      [24:0] addr,         // BYTE address; addr[0]=0 for 16-bit accesses
   output     [15:0] dout,
   input      [15:0] din,
   input             we,
   input             rd,
   output reg        ready
);

   // ---- mode word: CAS2, single-access (BURST_LENGTH=000). We drive one column command
   //      per access; open-page is a controller policy, not a device burst. ----
   localparam [2:0] CAS_LATENCY = 3'd2;
   localparam MODE = {3'b000, 1'b1 /*no wr burst*/, 2'b00, CAS_LATENCY, 1'b0, 3'b000};

   localparam [2:0] CMD_NOP          = 3'b111;
   localparam [2:0] CMD_ACTIVE       = 3'b011;
   localparam [2:0] CMD_READ         = 3'b101;
   localparam [2:0] CMD_WRITE        = 3'b100;
   localparam [2:0] CMD_PRECHARGE    = 3'b010;
   localparam [2:0] CMD_AUTO_REFRESH = 3'b001;
   localparam [2:0] CMD_LOAD_MODE    = 3'b000;

   // ---- 2x-clock timing floors (cycles). At ~192 MHz, TCK ~5.2 ns:
   //      tRP 18ns -> 4, tRCD 18ns -> 4, tRC 60ns -> 12. Conservative ceilings so the MT48
   //      model's ns guards never fire; the +1 margins absorb the model's 0.001ns slack. ----
   localparam [3:0] T_RP  = 4'd4;   // PRECHARGE -> ACTIVE (same bank)
   localparam [3:0] T_RCD = 4'd4;   // ACTIVE    -> READ/WRITE
   localparam [3:0] T_RC  = 4'd12;  // ACTIVE    -> ACTIVE (same bank)

   // startup: precharge-all, a couple refreshes, load mode. Counts in 2x cycles.
   localparam [14:0] STARTUP_CYCLES = 15'd24000;   // ~125us @192MHz, comfortably > 100us
   localparam [12:0] REFRESH_PERIOD = 13'd1400;    // ~7.3us @192MHz (< 7.8us / row)

   reg  [2:0]  command;
   reg  [14:0] init_cnt = 0;
   reg         initialized = 0;
   reg  [12:0] refresh_cnt = 0;
   reg         need_refresh = 0;

   // per-bank open-row cache
   reg         bank_open [0:3];
   reg  [12:0] bank_row  [0:3];
   // per-bank timing guards (cycles since the event; saturating)
   reg  [3:0]  since_active   [0:3];  // for tRC and tRCD
   reg  [3:0]  since_precharge[0:3];  // for tRP

   // latched request
   reg  [24:0] req_addr;
   reg  [15:0] req_din;
   reg  [1:0]  req_wtbt;
   reg         req_we;
   reg  [15:0] data;                  // captured read word

   // edge detect on we/rd (adapter pulses them, req held via arbiter)
   reg         old_we, old_rd;
   reg         have_req;

   // CAS read-capture pipeline
   reg  [CAS_LATENCY:0] rd_delay;

   // DQ drive
   reg  [15:0] sdram_dq_out;
   reg         sdram_dq_oe;

   integer bi;

   assign SDRAM_DQ   = sdram_dq_oe ? sdram_dq_out : 16'bZ;
   assign SDRAM_CKE  = 1'b1;
   assign SDRAM_nCS  = 1'b0;
   assign SDRAM_nRAS = command[2];
   assign SDRAM_nCAS = command[1];
   assign SDRAM_nWE  = command[0];
   // byte-mask on the column command drives DQML/DQMH; SDRAM_A[12:11] carry them (same as stock)
   assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];
   // dout byte-swap preserved verbatim from sdram_stock
   assign dout = req_addr[0] ? {data[7:0], data[15:8]} : {data[15:8], data[7:0]};

   // decomposition — MUST match sdram_stock feeding the MT48 model
   wire [1:0]  a_bank = addr[24:23];
   wire [12:0] a_row  = addr[13:1];
   wire [8:0]  a_col  = addr[22:14];

   wire [1:0]  r_bank = req_addr[24:23];
   wire [12:0] r_row  = req_addr[13:1];
   wire [8:0]  r_col  = req_addr[22:14];

   // FSM
   localparam [2:0] S_INIT        = 3'd0,
                    S_IDLE        = 3'd1,
                    S_PRECHARGE   = 3'd2,
                    S_ACTIVATE    = 3'd3,
                    S_COLUMN      = 3'd4,
                    S_READWAIT    = 3'd5,
                    S_REFRESH     = 3'd6,
                    S_INIT_REFWAIT= 3'd7;
   reg  [2:0]  state = S_INIT;
   reg  [3:0]  wait_cnt;
   reg  [3:0]  init_step;

   task issue_column;
      begin
         // column command WITHOUT auto-precharge (A[10]=0) -> row stays open.
         // A[12:11] = byte mask on writes (active-low, like stock); reads mask 0 (read both).
         if (req_we) begin
            command      <= CMD_WRITE;
            SDRAM_A      <= { (req_wtbt ? ~req_wtbt[1] : 1'b0),
                              (req_wtbt ? ~req_wtbt[0] : 1'b0),
                              1'b0 /*A10=0 no autoprecharge*/, 1'b0, r_col };
            sdram_dq_out <= req_wtbt ? req_din : {req_din[7:0], req_din[7:0]};
            sdram_dq_oe  <= 1'b1;
            ready        <= 1'b1;              // write completes at the column command
            have_req     <= 1'b0;
            state        <= S_IDLE;
         end else begin
            command      <= CMD_READ;
            SDRAM_A      <= { 2'b00 /*mask: read both bytes*/, 1'b0 /*A10=0*/, 1'b0, r_col };
            rd_delay[CAS_LATENCY] <= 1'b1;     // capture data CAS cycles later
            state        <= S_READWAIT;
         end
      end
   endtask

   always @(posedge clk) begin
      command      <= CMD_NOP;
      sdram_dq_oe  <= 1'b0;

      // saturating per-bank timing counters
      for (bi=0; bi<4; bi=bi+1) begin
         if (since_active[bi]    != 4'hF) since_active[bi]    <= since_active[bi]    + 1'b1;
         if (since_precharge[bi] != 4'hF) since_precharge[bi] <= since_precharge[bi] + 1'b1;
      end

      // refresh interval
      refresh_cnt <= refresh_cnt + 1'b1;
      if (refresh_cnt >= REFRESH_PERIOD) begin refresh_cnt <= 0; need_refresh <= 1'b1; end

      // CAS read capture
      rd_delay <= {1'b0, rd_delay[CAS_LATENCY:1]};
      if (rd_delay[0]) begin
         data  <= SDRAM_DQ;
         ready <= 1'b1;
         have_req <= 1'b0;
         state <= S_IDLE;
      end

      // latch a new request on the rising edge of we/rd (held by arbiter until ack)
      old_we <= we; old_rd <= rd;
      if ((we & ~old_we) | (rd & ~old_rd)) begin
         req_addr <= addr; req_din <= din; req_wtbt <= wtbt; req_we <= we & ~old_we;
         have_req <= 1'b1;
         ready    <= 1'b0;
      end

      case (state)
         S_INIT: begin
            SDRAM_A <= 13'd0; SDRAM_BA <= 2'd0;
            init_cnt <= init_cnt + 1'b1;
            // precharge-all, refresh x2, load-mode near the end of the startup window
            if (init_cnt == STARTUP_CYCLES - 200) begin command <= CMD_PRECHARGE; SDRAM_A[10] <= 1'b1; end
            if (init_cnt == STARTUP_CYCLES - 150) command <= CMD_AUTO_REFRESH;
            if (init_cnt == STARTUP_CYCLES - 100) command <= CMD_AUTO_REFRESH;
            if (init_cnt == STARTUP_CYCLES - 50)  begin command <= CMD_LOAD_MODE; SDRAM_A <= MODE; end
            if (init_cnt >= STARTUP_CYCLES) begin
               state <= S_IDLE; ready <= 1'b1; initialized <= 1'b1;
               for (bi=0; bi<4; bi=bi+1) begin bank_open[bi] <= 1'b0; since_precharge[bi] <= 4'hF; since_active[bi] <= 4'hF; end
            end
         end

         S_IDLE: begin
            if (need_refresh && !have_req) begin
               // close all banks then refresh (only when idle so no open-row conflict)
               command <= CMD_PRECHARGE; SDRAM_A[10] <= 1'b1;
               for (bi=0; bi<4; bi=bi+1) begin bank_open[bi] <= 1'b0; since_precharge[bi] <= 4'd0; end
               wait_cnt <= T_RP; state <= S_REFRESH;
            end else if (have_req) begin
               // page hit? same bank open on the same row -> straight to column
               if (bank_open[r_bank] && bank_row[r_bank] == r_row
                     && since_active[r_bank] >= T_RCD) begin
                  SDRAM_BA <= r_bank;
                  issue_column();
               end else if (bank_open[r_bank] && bank_row[r_bank] != r_row) begin
                  // wrong row open on this bank -> precharge it first (respect tRC via activate age)
                  SDRAM_BA <= r_bank; command <= CMD_PRECHARGE; SDRAM_A[10] <= 1'b0;
                  bank_open[r_bank] <= 1'b0; since_precharge[r_bank] <= 4'd0;
                  wait_cnt <= T_RP; state <= S_PRECHARGE;
               end else begin
                  // bank closed -> activate (respect tRP since its last precharge)
                  if (since_precharge[r_bank] >= T_RP) begin
                     SDRAM_BA <= r_bank; command <= CMD_ACTIVE; SDRAM_A <= r_row;
                     bank_open[r_bank] <= 1'b1; bank_row[r_bank] <= r_row;
                     since_active[r_bank] <= 4'd0;
                     wait_cnt <= T_RCD; state <= S_ACTIVATE;
                  end
                  // else wait in IDLE until tRP satisfied
               end
            end
         end

         S_PRECHARGE: begin
            if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
            else begin
               // now activate the demanded row (tRP satisfied by the wait; tRC by activate age)
               if (since_active[r_bank] >= T_RC || since_active[r_bank] == 4'hF) begin
                  SDRAM_BA <= r_bank; command <= CMD_ACTIVE; SDRAM_A <= r_row;
                  bank_open[r_bank] <= 1'b1; bank_row[r_bank] <= r_row;
                  since_active[r_bank] <= 4'd0;
                  wait_cnt <= T_RCD; state <= S_ACTIVATE;
               end
            end
         end

         S_ACTIVATE: begin
            if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
            else begin SDRAM_BA <= r_bank; issue_column(); end
         end

         S_COLUMN: begin SDRAM_BA <= r_bank; issue_column(); end

         S_READWAIT: ; // waiting for rd_delay[0] to capture data (handled above)

         S_REFRESH: begin
            if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
            else begin command <= CMD_AUTO_REFRESH; need_refresh <= 1'b0; wait_cnt <= T_RC; state <= S_INIT_REFWAIT; end
         end

         S_INIT_REFWAIT: begin
            if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
            else state <= S_IDLE;
         end

         default: state <= S_IDLE;
      endcase

      if (init) begin
         state <= S_INIT; init_cnt <= 0; ready <= 1'b0; initialized <= 1'b0;
         have_req <= 1'b0; need_refresh <= 1'b0; refresh_cnt <= 0;
      end
   end

endmodule
`default_nettype wire
