// Smoke-test core: 12-bit adder with carry out. Combinational, so there is no s / ns port.
//   x[11:0] = a, x[23:12] = b, y[12:0] = a + b
module add12_core(input [23:0] x, output [12:0] y);
  assign y = x[11:0] + x[23:12];
endmodule
