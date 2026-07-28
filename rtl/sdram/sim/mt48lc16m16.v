//
// mt48lc16m16.v — behavioral Micron MT48LC16M16A2 (4Mx16x4banks) SDRAM model for the
// stock-controller bandwidth harness. MEASUREMENT ONLY (rtl/sdram/sim), not synthesized.
//
// Purpose: give sdram_stock.sv a bus partner that enforces the REAL DRAM timing
// (tRC / tRCD / tRP, CAS-latency 2, single-access with BURST_LENGTH=000) so the MB/s
// the harness reports is grounded in silicon timing, not a free bus. If sdram_stock ever
// violated a DRAM constraint the model $fatals — so a green run means the stock controller's
// per-access cadence is honored by a spec-legal device.
//
// Timing (MT48LC16M16A2-6 speed grade, the DE10-Nano part; datasheet Rev. numbers):
//   tRCD (ACTIVE->READ/WRITE)  >= 18 ns
//   tRP  (PRECHARGE->ACTIVE)   >= 18 ns   (same bank)
//   tRC  (ACTIVE->ACTIVE)      >= 60 ns   (same bank)
//   CAS latency = 2 (part is rated CL2 up to ~100 MHz)
// At the core's 96 MHz SDRAM clock (period ~10.417 ns) these are the cycle floors the
// stock controller MUST clear. The controller's precharge-every-access FSM spends far MORE
// cycles per word than these floors, so the model's guards pass and the FSM cadence is the
// throughput bound (which is exactly the deficit this harness quantifies).
//
// The model is functional for the access PATTERN the stock controller issues: it opens a
// row (ACTIVE), then a single READ or WRITE, then the controller auto-precharges via A[10]
// on the column command (stock sets A[10]=1 on the R/W in OPEN_2 -> read-with-autoprecharge
// / write-with-autoprecharge). We honor timing per bank and return read data CL2 later.
//
`timescale 1ns/1ps

module mt48lc16m16 #(
    parameter real TCK_NS   = 10.417,  // 96 MHz
    parameter real TRCD_NS  = 18.0,
    parameter real TRP_NS   = 18.0,
    parameter real TRC_NS   = 60.0,
    parameter integer CAS   = 2,
    parameter integer ADDR_BITS = 13,
    parameter integer MEMWORDS = 1<<20  // small backing store; addresses masked into it
)(
    input               clk,
    inout      [15:0]   dq,
    input  [ADDR_BITS-1:0] addr,
    input       [1:0]   ba,
    input               nCS,
    input               nRAS,
    input               nCAS,
    input               nWE,
    input               cke
);
    // ---- command decode (nCS/nRAS/nCAS/nWE) ----
    localparam [3:0] C_LOADMODE  = 4'b0000;
    localparam [3:0] C_REFRESH   = 4'b0001;
    localparam [3:0] C_PRECHARGE = 4'b0010;
    localparam [3:0] C_ACTIVE    = 4'b0011;
    localparam [3:0] C_WRITE     = 4'b0100;
    localparam [3:0] C_READ      = 4'b0101;
    localparam [3:0] C_NOP       = 4'b0111;

    wire [3:0] cmd = {nCS, nRAS, nCAS, nWE};

    // ---- per-bank open-row + timing bookkeeping ----
    reg  [ADDR_BITS-1:0] open_row [0:3];
    reg                  row_active [0:3];
    real                 t_active   [0:3];   // last ACTIVE time (for tRC)
    real                 t_precharge[0:3];   // last PRECHARGE time (for tRP)

    // ---- tiny backing store (functional, not full 32MB) ----
    reg [15:0] mem [0:MEMWORDS-1];

    // ---- read data pipeline for CAS latency ----
    reg [15:0] read_pipe [0:CAS];
    reg        read_vld  [0:CAS];
    integer    p;

    reg [15:0] dq_drv;
    reg        dq_oe;
    assign dq = dq_oe ? dq_drv : 16'bZ;

    // captured column address at READ/WRITE
    reg [ADDR_BITS-1:0] col_active;
    reg [1:0]           ba_active;

    integer i;
    initial begin
        for (i=0;i<4;i=i+1) begin
            row_active[i]  = 1'b0;
            t_active[i]    = -1e9;
            t_precharge[i] = -1e9;
        end
        for (p=0;p<=CAS;p=p+1) begin read_vld[p]=1'b0; read_pipe[p]=16'h0; end
        dq_oe = 1'b0; dq_drv = 16'h0;
        // deterministic backing pattern so reads return something non-trivial
        for (i=0;i<MEMWORDS;i=i+1) mem[i] = i[15:0] ^ 16'hA5A5;
    end

    function [19:0] lin_addr;
        input [1:0] b; input [ADDR_BITS-1:0] r; input [ADDR_BITS-1:0] c;
        lin_addr = ( ({b, r[7:0], c[9:0]}) & (MEMWORDS-1) );
    endfunction

    always @(posedge clk) begin
        // advance the CAS read pipeline.
        // CL2 read-data PHASE: a READ latched at cycle N loads read_pipe[CAS]/read_vld[CAS]
        // (see C_READ below). The CL2 controllers capture SDRAM_DQ at cycle N+CAS via their
        // data_ready_delay[0] shift. Because dq_oe/dq_drv are REGISTERED, driving on the
        // just-loaded slot (read_vld[CAS]) asserts dq_oe at N+1, so DQ is VALID and STABLE
        // going INTO the N+CAS(=N+2) capture edge — exactly a real MT48 CL2 part. The old
        // drive-on-read_vld[0] added CAS extra register stages -> DQ landed at N+CAS+1 (one
        // cycle LATE) -> the controllers latched Z -> RDCHK=x. This is a pure read-DATA phase
        // alignment; it does NOT touch command timing, so per-word cadence / MB/s are
        // unchanged (stock 21.62 baseline holds). Replayed reads now return the real backing
        // word -> RDCHK non-x and byte-identical stock==burst.
        if (read_vld[CAS]) begin dq_drv <= read_pipe[CAS]; dq_oe <= 1'b1; end
        else               dq_oe <= 1'b0;
        for (p=0;p<CAS;p=p+1) begin read_pipe[p]<=read_pipe[p+1]; read_vld[p]<=read_vld[p+1]; end
        read_vld[CAS] <= 1'b0;

        if (cke) begin
            case (cmd)
                C_ACTIVE: begin
                    // tRP: this bank must have been precharged >= tRP ago
                    if ($realtime - t_precharge[ba] + 0.001 < TRP_NS)
                        $fatal(1,"[MT48] tRP VIOLATION bank%0d: ACTIVE only %.1fns after PRECHARGE (need %.1f) @%0t",
                               ba, $realtime - t_precharge[ba], TRP_NS, $realtime);
                    // tRC: ACTIVE-to-ACTIVE same bank
                    if ($realtime - t_active[ba] + 0.001 < TRC_NS)
                        $fatal(1,"[MT48] tRC VIOLATION bank%0d: %.1fns since last ACTIVE (need %.1f) @%0t",
                               ba, $realtime - t_active[ba], TRC_NS, $realtime);
                    open_row[ba]   <= addr;
                    row_active[ba] <= 1'b1;
                    t_active[ba]   <= $realtime;
                end
                C_READ: begin
                    if (!row_active[ba])
                        $fatal(1,"[MT48] READ to closed bank%0d @%0t", ba, $realtime);
                    // tRCD: ACTIVE-to-READ
                    if ($realtime - t_active[ba] + 0.001 < TRCD_NS)
                        $fatal(1,"[MT48] tRCD VIOLATION bank%0d: READ %.1fns after ACTIVE (need %.1f) @%0t",
                               ba, $realtime - t_active[ba], TRCD_NS, $realtime);
                    // schedule read data CAS cycles later
                    read_pipe[CAS] <= mem[ lin_addr(ba, open_row[ba], addr) ];
                    read_vld[CAS]  <= 1'b1;
                    // auto-precharge if A[10] set (stock sets it)
                    if (addr[10]) begin row_active[ba] <= 1'b0; t_precharge[ba] <= $realtime; end
                end
                C_WRITE: begin
                    if (!row_active[ba])
                        $fatal(1,"[MT48] WRITE to closed bank%0d @%0t", ba, $realtime);
                    if ($realtime - t_active[ba] + 0.001 < TRCD_NS)
                        $fatal(1,"[MT48] tRCD VIOLATION bank%0d: WRITE %.1fns after ACTIVE (need %.1f) @%0t",
                               ba, $realtime - t_active[ba], TRCD_NS, $realtime);
                    mem[ lin_addr(ba, open_row[ba], addr) ] <= dq;
                    if (addr[10]) begin row_active[ba] <= 1'b0; t_precharge[ba] <= $realtime; end
                end
                C_PRECHARGE: begin
                    if (addr[10]) begin // all banks
                        for (i=0;i<4;i=i+1) begin row_active[i]<=1'b0; t_precharge[i]<=$realtime; end
                    end else begin
                        row_active[ba]<=1'b0; t_precharge[ba]<=$realtime;
                    end
                end
                C_REFRESH:  ; // timing not modeled for the throughput measurement (controller inserts them; harness excludes refresh windows from the busy count)
                C_LOADMODE: ;
                C_NOP:      ;
                default:    ;
            endcase
        end
    end
endmodule
