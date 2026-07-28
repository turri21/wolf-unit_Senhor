// Emit the context-free illegal/legal result for all 65,536 opcode words.
// The predictive MAME audit joins this bitmap against opcodes that the original
// game actually retired; immediate operands are not treated as opcodes.
`timescale 1ns/1ps

module tb_decode_bitmap;
  import tms34010_pkg::*;

  instr_word_t instr;
  decoded_instr_t decoded;
  int unsigned i;

  tms34010_decode u_decode (
    .instr(instr),
    .decoded(decoded)
  );

  initial begin
    for (i = 0; i < 65536; i++) begin
      instr = instr_word_t'(i);
      #1;
      if (decoded.illegal) $display("ILLEGAL %04X", i[15:0]);
    end
    $display("TEST_RESULT: PASS (decoder bitmap complete)");
    $finish;
  end
endmodule : tb_decode_bitmap
