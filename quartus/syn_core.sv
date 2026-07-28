// syn_core.sv — Phase 6 W6 gate: prove the game brain (TMS34010 + yunit_memsys)
// passes Quartus Analysis & Synthesis (catches mixed pkg-order / SV / primitive
// issues Questa hides). Not the final emu — a synthesis harness.
`default_nettype none
module syn_core (
  input  logic        clk,
  input  logic        rst,
  input  logic [63:0] inputs,
  input  logic  [7:0] src_data,
  output logic        src_req,
  output logic [23:0] src_addr,
  input  logic        src_ack,
  output logic  [7:0] snd_select,
  output logic        snd_trig,
  output logic        snd_reset,
  output logic        blit_busy,
  output logic        illegal,
  output logic [31:0] pc_dbg
);
  import yunit_pkg::*;
  import tms34010_pkg::*;
  logic mem_req, mem_we;
  logic [ADDR_WIDTH-1:0]       mem_addr;
  logic [FIELD_SIZE_WIDTH-1:0] mem_size;
  logic [DATA_WIDTH-1:0]       mem_wdata, mem_rdata;
  logic mem_ack, int1;
  core_state_t  state_w;
  instr_word_t  instr_w;

  tms34010_core u_core (
    .clk(clk), .rst(rst),
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_size(mem_size),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack),
    .state_o(state_w), .pc_o(pc_dbg), .instr_word_o(instr_w),
    .illegal_opcode_o(illegal), .lint1_in(int1));

  yunit_memsys u_sys (
    .clk(clk), .rst(rst),
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_size(mem_size),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack),
    .src_req(src_req), .src_addr(src_addr), .src_data(src_data), .src_ack(src_ack),
    .inputs(inputs), .int1(int1),
    .snd_select(snd_select), .snd_trig(snd_trig), .snd_reset(snd_reset),
    .erase_start(1'b0), .erase_row0(9'd0), .erase_lines(10'd0), .erase_busy(),
    .blit_busy(blit_busy));
endmodule
`default_nettype wire
