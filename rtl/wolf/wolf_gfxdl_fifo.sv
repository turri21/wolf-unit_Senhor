// wolf_gfxdl_fifo.sv — gfx-ROM download FIFO (MRA <rom index="1"> byte stream -> wolf_top's
// gfx_dl_* handshake). Extracted from Arcade-SmashTV.sv into a module so the download
// integration seam is SIMULABLE — the first cut lived inline in the emu top, was never
// integration-simmed, and shipped two P0022-class reset bugs the cab caught first
// (write FSM frozen by core_rst during download; a phase latch that dropped in the
// PLL-lock->download idle gap). Module-sim-proven != integration-sim-proven; test seams.
//
// Same 512-deep/HWM=256 sizing as the proven prog-ROM iol_fifo (ioctl_wait needs
// round-trip-latency headroom, not a 1-cycle stall — headroom is a function of the HPS
// polling round-trip, not transfer size, so the depth that measured 0 drops there holds).
//
// Reset on sdram_por (P0022 2-FF-synced ~locked), NEVER core reset — core reset is high
// during the entire download by construction.
`default_nettype none
module wolf_gfxdl_fifo #(
    parameter int AW  = 9,      // 512-deep
    parameter int HWM = 256
)(
    input  logic        clk,
    input  logic        sdram_por,

    // push side (ioctl stream, dest_addr already interleave-transformed)
    input  logic        push,          // gfx_download & ioctl_wr
    input  logic [24:0] push_addr,
    input  logic [7:0]  push_data,
    output logic        wait_o,        // -> ioctl_wait (HWM backpressure)
    output logic        idle_o,        // FIFO empty and no held downstream byte

    // drain side (wolf_top gfx_dl_* handshake: hold wr until ack)
    output logic        dl_wr,
    output logic [24:0] dl_addr,
    output logic [7:0]  dl_data,
    input  logic        dl_ack,

    // observability: total bytes accepted (full umk3 gfx download = 0x1400000)
    output logic [25:0] dbg_pushes
);
    reg  [32:0] fifo [0:(1<<AW)-1];    // {dest_addr[24:0], data[7:0]}
    reg  [AW:0] wp, rp;
    reg         hold;
    reg [24:0]  addr_r;
    reg [7:0]   data_r;
    wire [AW:0] occ   = wp - rp;
    wire        full  = (occ == (1 << AW));
    wire        empty = (wp == rp);
    assign wait_o = (occ >= HWM[AW:0]);
    assign idle_o = empty && !hold;

    assign dl_wr   = hold;
    assign dl_addr = addr_r;
    assign dl_data = data_r;

    always @(posedge clk) begin
        if (sdram_por) begin
            wp <= '0; rp <= '0; hold <= 1'b0; dbg_pushes <= '0;
        end else begin
            if (push & !full) begin
                fifo[wp[AW-1:0]] <= {push_addr, push_data};
                wp         <= wp + 1'b1;
                dbg_pushes <= dbg_pushes + 1'b1;
            end
            if (hold & dl_ack) hold <= 1'b0;
            if ((!hold || (hold & dl_ack)) && !empty) begin
                {addr_r, data_r} <= fifo[rp[AW-1:0]];
                hold <= 1'b1;
                rp   <= rp + 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
