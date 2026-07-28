`default_nettype none
module syn_cpu (
  input  logic clk, rst,
  output logic mem_req, mem_we,
  output logic [31:0] mem_addr, mem_wdata,
  output logic [5:0]  mem_size,
  input  logic [31:0] mem_rdata,
  input  logic mem_ack, lint1_in,
  output logic illegal,
  output logic [31:0] pc_dbg
);
  import tms34010_pkg::*;
  core_state_t st; instr_word_t iw;
  tms34010_core u (.clk(clk), .rst(rst), .mem_req(mem_req), .mem_we(mem_we),
    .mem_addr(mem_addr), .mem_size(mem_size), .mem_wdata(mem_wdata),
    .mem_rdata(mem_rdata), .mem_ack(mem_ack), .state_o(st), .pc_o(pc_dbg),
    .instr_word_o(iw), .illegal_opcode_o(illegal), .lint1_in(lint1_in));
endmodule
`default_nettype wire
