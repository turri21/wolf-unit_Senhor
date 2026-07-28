// yunit_palram.sv — Phase 6 W3: palette mirror for video scanout.
//
// The palette RAM in yunit_mem is a true-dual-port BRAM whose BOTH ports are
// consumed by the CPU field engine (a >=17-bit palette field writes word0 on
// port A AND word1 on port B in the SAME cycle; a 33-bit-spanning field writes
// word2 on port A a cycle later). The video scanout needs its own always-
// available palette read, so it cannot share those ports.
//
// This module keeps a MIRROR of the palette (updated on every CPU palette write)
// with a DEDICATED video read port. The two possible CPU writes per cycle (A,B)
// are serialized into the mirror's single write port through a tiny FIFO. The
// FIFO peaks at depth 1 for the worst-case field (w0+w1 same cycle, then w2 next
// cycle; drain 1/clk keeps up), so the mirror tracks the CPU palette within a
// couple of clocks — far faster than the pixel rate, so the video always reads
// fresh palette. Writes are sparse (MOVE-driven, not per-pixel).
//
// Inference: two always blocks, one write (port A, from the serializer) + one
// read (port B, video) => simple-dual-port M10K.
`default_nettype none
module yunit_palram #(
  parameter int AW = 13,           // palette address width (8192 words, matches pal[])
  parameter int DEPTH = 1 << AW
)(
  input  logic          clk,
  input  logic          rst,
  // CPU palette write taps from yunit_mem (port A = word0, port B = word1; both
  // may fire the same cycle for a >=17-bit field).
  input  logic          we_a,
  input  logic [AW-1:0] aa,
  input  logic [15:0]   awd,
  input  logic          we_b,
  input  logic [AW-1:0] ba,
  input  logic [15:0]   bwd,
  // video read (registered, 1-clk; dedicated port — never preempted)
  input  logic [AW-1:0] raddr,
  output logic [15:0]   rdata
);
  (* ramstyle = "no_rw_check" *) logic [15:0] mem [0:DEPTH-1];

  // ---- write serializer: up to 2 in/cycle, 1 out/cycle, depth-4 FIFO ---------
  localparam int QAW = 2;                 // depth 4 (>= worst-case peak of 1)
  logic [AW+16-1:0] q [0:(1<<QAW)-1];     // {addr, data}
  logic [QAW:0] wptr, rptr;               // extra bit for full/empty distinction
  wire  qempty = (wptr == rptr);

  logic          w_we;                    // this-cycle mirror write
  logic [AW-1:0] w_aa;
  logic [15:0]   w_awd;

  always_comb begin
    // dequeue one if available
    w_we  = !qempty;
    w_aa  = q[rptr[QAW-1:0]][AW+16-1:16];
    w_awd = q[rptr[QAW-1:0]][15:0];
  end

  // port A: FIFO -> mirror write (read side of FIFO uses q, not mem)
  always_ff @(posedge clk) begin
    if (rst) begin
      wptr <= '0; rptr <= '0;
    end else begin
      if (!qempty) rptr <= rptr + 1'b1;                 // dequeue -> applied below
      // enqueue A then B (distinct slots; wptr advances by count)
      if (we_a && we_b) begin
        q[wptr[QAW-1:0]]         <= {aa, awd};
        q[wptr[QAW-1:0] + 1'b1]  <= {ba, bwd};          // next slot (wraps in QAW bits)
        wptr <= wptr + 2'd2;
      end else if (we_a) begin
        q[wptr[QAW-1:0]] <= {aa, awd};  wptr <= wptr + 1'b1;
      end else if (we_b) begin
        q[wptr[QAW-1:0]] <= {ba, bwd};  wptr <= wptr + 1'b1;
      end
    end
  end
  // the actual mirror write (port A)
  always_ff @(posedge clk) if (w_we) mem[w_aa] <= w_awd;

  // port B: dedicated video read (1-clk registered)
  always_ff @(posedge clk) rdata <= mem[raddr];
endmodule
`default_nettype wire
