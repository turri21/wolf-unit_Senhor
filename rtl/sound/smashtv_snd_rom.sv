// smashtv_snd_rom.sv — one 64KB CVSD sound ROM chip (sl2 u4/u19/u20).
// SIM: loaded from a hex file, combinational read (the validated tb_yunit_sound path).
// SYNTH: a dual-clock inferable BRAM — the 6809 reads on `clk` (clk_snd) and the
// MRA sound-ROM download writes on `wrclk` (the ioctl clk_sys domain). The download
// completes with the whole board held in reset, so the read side sees settled
// contents (no CDC handshake needed on the write port). Until a byte is written the
// cell is 0, so the 6809 is idle = silent — harmless to the CPU/video path.
// Instantiated from the VHDL board (mixed-language, bound by name).
`default_nettype none
module smashtv_snd_rom #(
  parameter HEX = "build/snd_u4.hex"
)(
  input  wire        clk,
  input  wire [15:0] addr,
  output reg   [7:0] data,
  // ioctl write port (clk_sys / ioctl domain) — MRA sound-ROM load
  input  wire        wrclk,
  input  wire        we,
  input  wire [15:0] waddr,
  input  wire [7:0]  wdata
);
  (* ramstyle = "no_rw_check" *) reg [7:0] mem [0:65535];
`ifdef SYNTHESIS
  always @(posedge wrclk) if (we) mem[waddr] <= wdata;  // ioctl load (clk_sys)
  always @(posedge clk)   data <= mem[addr];            // 6809 read -> infers M10K
`else
  // sim keeps the validated hex-init + combinational read; the write port is
  // present for port-compatibility with the board but unused (ROMs come from hex).
  initial begin
    for (int i = 0; i < 65536; i++) mem[i] = 8'h00;
    $readmemh(HEX, mem);
  end
  always @(*) data = mem[addr];                  // sim: combinational (validated)
`endif
endmodule
`default_nettype wire
