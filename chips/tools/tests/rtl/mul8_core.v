// Test fixture: 8 x 8 multiplier. Its equivalence miter takes MiniSat about 20 s, so it is used to check that
// a proof time limit is enforced.
module mul8_core(input [15:0] x, output [15:0] y);
  assign y = x[7:0] * x[15:8];
endmodule
