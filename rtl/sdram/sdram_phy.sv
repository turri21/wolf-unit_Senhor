// sdram_phy.sv — Phase 6 W1f item1b: single-word MT48LC16M16 SDRAM controller presenting
// the req/ack word contract yunit_sdram_arb drives (req held until ack; edge-accept on
// rising rd|wr while idle; 1-cycle ack pulse with read data valid). Single access per
// transaction (no burst) + periodic auto-refresh. Timing constants from the proven darfpga
// / srg320 MiSTer controllers (MT48LC16M16, up to ~128 MHz). Command timing is validated
// on real hardware (Phase 7); sim uses the behavioral req/ack model, so this drives the
// pins for synthesis + a behavioral-chip round-trip sanity check.
`timescale 1ns/1ps
`default_nettype none
module sdram_phy #(
  parameter int CLK_MHZ    = 100,           // SDRAM clock (100-128)
  parameter int RASCAS     = 3,             // tRCD in clks
  parameter int CAS        = 2,             // CAS latency (2/3)
  parameter int TRP        = 3,             // precharge in clks
  parameter int TRFC       = 9,             // refresh cycle in clks
  parameter int REFRESH_IV = 780            // auto-refresh interval in clks (~7.8us@100MHz)
)(
  input  logic         clk,
  input  logic         init,               // hold high after config to run power-up init
  // req/ack word port (matches yunit_sdram_arb)
  input  logic [24:0]  addr,               // word address {bank[1:0], row[12:0], col[8:0]} = addr[23:0]
  input  logic [15:0]  din,
  input  logic [1:0]   be,                  // write byte-enables (-> DQM low-active)
  input  logic         rd,
  input  logic         wr,
  output logic [15:0]  dout,
  output logic         ack,
  output logic         ready,             // high once power-up init completes (safe to issue)
  // MT48LC16M16 pins
  inout  wire  [15:0]  SDRAM_DQ,
  output logic [12:0]  SDRAM_A,
  output logic [1:0]   SDRAM_BA,
  output logic         SDRAM_DQML,
  output logic         SDRAM_DQMH,
  output logic         SDRAM_nCS,
  output logic         SDRAM_nRAS,
  output logic         SDRAM_nCAS,
  output logic         SDRAM_nWE,
  output logic         SDRAM_CKE
);
  // command = {nCS,nRAS,nCAS,nWE}
  localparam [3:0] CMD_NOP=4'b0111, CMD_ACTIVE=4'b0011, CMD_READ=4'b0101, CMD_WRITE=4'b0100,
                   CMD_PRECHARGE=4'b0010, CMD_REFRESH=4'b0001, CMD_LOADMODE=4'b0000;
  localparam [12:0] MODE = {3'b000, 1'b1 /*no wr burst*/, 2'b00, CAS[2:0], 1'b0, 3'b000 /*burst1*/};

  wire [1:0]  a_bank = addr[23:22];
  wire [12:0] a_row  = addr[21:9];
  wire [8:0]  a_col  = addr[8:0];

  typedef enum logic [3:0] { S_PWR, S_INIT, S_IDLE, S_ACT, S_RDWAIT, S_PRE, S_REF } st_t;
  st_t st;
  logic [15:0] pwr_cnt;             // power-up delay
  logic [3:0]  istep;              // init micro-step: PRE, REF, REF, LOADMODE
  logic [3:0]  wait_cnt;
  logic [15:0] ref_cnt;
  logic        served;             // serve-once-per-assertion (survives refresh preemption)
  logic        is_wr;
  logic [24:0] a_l; logic [15:0] d_l; logic [1:0] be_l;
  logic [3:0]  cmd;
  logic        dq_oe;              // drive DQ (write)
  logic [15:0] dq_o;
  logic        init_d;

  assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;
  assign SDRAM_CKE = 1'b1;
  assign SDRAM_DQ  = dq_oe ? dq_o : 16'hZZZZ;

  always_ff @(posedge clk) begin
    cmd     <= CMD_NOP;
    dq_oe   <= 1'b0;
    ack     <= 1'b0;
    SDRAM_A <= 13'd0; SDRAM_BA <= 2'd0; SDRAM_DQML <= 1'b0; SDRAM_DQMH <= 1'b0;
    if (!(rd | wr)) served <= 1'b0;   // rearm when the requester drops its line (per contract)
    init_d  <= init;
    if (ref_cnt != 0) ref_cnt <= ref_cnt - 1'b1;

    if (init & ~init_d) begin                     // rising edge of init -> power-up
      st <= S_PWR; pwr_cnt <= 16'd20000; ready <= 1'b0;   // ~100us+ @100MHz
    end else case (st)
      // -------- power-up wait, then the init command sequence --------
      S_PWR: if (pwr_cnt != 0) pwr_cnt <= pwr_cnt - 1'b1;
             else begin istep <= 4'd0; st <= S_INIT; end
      S_INIT: begin
        // istep: 0=PRECHARGE-ALL, 1=REFRESH, 2=REFRESH, 3=LOADMODE, done
        if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
        else case (istep)
          4'd0: begin cmd<=CMD_PRECHARGE; SDRAM_A<=13'h400; wait_cnt<=TRP[3:0];  istep<=4'd1; end // A[10]=1 all
          4'd1: begin cmd<=CMD_REFRESH;                     wait_cnt<=TRFC[3:0]; istep<=4'd2; end
          4'd2: begin cmd<=CMD_REFRESH;                     wait_cnt<=TRFC[3:0]; istep<=4'd3; end
          4'd3: begin cmd<=CMD_LOADMODE; SDRAM_A<=MODE; SDRAM_BA<=2'd0; wait_cnt<=4'd3; istep<=4'd4; end
          default: begin ref_cnt<=REFRESH_IV[15:0]; st<=S_IDLE; ready<=1'b1; end  // init done
        endcase
      end
      // -------- idle: refresh has priority, then a pending access --------
      S_IDLE: begin
        if (ref_cnt == 0) begin
          cmd <= CMD_REFRESH; wait_cnt <= TRFC[3:0]; ref_cnt <= REFRESH_IV[15:0]; st <= S_REF;
        end else if ((rd | wr) & ~served) begin      // accept a not-yet-served access (held or pulsed)
          served <= 1'b1;                             // (survives a refresh preempting the accept)
          a_l <= addr; d_l <= din; be_l <= be; is_wr <= wr;
          cmd <= CMD_ACTIVE; SDRAM_A <= a_row; SDRAM_BA <= a_bank;
          wait_cnt <= RASCAS[3:0] - 4'd1; st <= S_ACT;
        end
      end
      S_ACT: if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
             else begin
               SDRAM_BA <= a_l[23:22]; SDRAM_A <= {2'b00, 1'b1, 1'b0, a_l[8:0]}; // A[10]=1 auto-precharge
               if (is_wr) begin
                 cmd <= CMD_WRITE; dq_oe <= 1'b1; dq_o <= d_l;
                 SDRAM_DQML <= ~be_l[0]; SDRAM_DQMH <= ~be_l[1];   // low-active byte mask
                 st <= S_PRE; wait_cnt <= TRP[3:0];
               end else begin
                 cmd <= CMD_READ;
                 st  <= S_RDWAIT; wait_cnt <= CAS[3:0];            // wait CAS latency
               end
             end
      S_RDWAIT: if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
                else begin dout <= SDRAM_DQ; ack <= 1'b1; st <= S_IDLE; end
      S_PRE:  if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
              else begin ack <= 1'b1; st <= S_IDLE; end            // write done (auto-precharge)
      S_REF:  if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
              else st <= S_IDLE;
      default: st <= S_IDLE;
    endcase
  end
endmodule
`default_nettype wire
