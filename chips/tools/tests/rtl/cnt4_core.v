// Smoke-test core: 4-bit counter with enable. It wraps from 15 to 0.
//   x[0]   = en
//   s[3:0] = count
//   y[3:0] = count after the beat, y[4] = wrapped in this beat
module cnt4_core(input [3:0] s, input [0:0] x, output [3:0] ns, output [4:0] y);
  wire en = x[0];
  wire [4:0] sum = {1'b0, s} + {4'b0, en};
  assign ns = sum[3:0];
  assign y = {sum[4], sum[3:0]};
endmodule
