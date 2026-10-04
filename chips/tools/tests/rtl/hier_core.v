// Smoke-test core with two instances, to check that `tapc synth --hier` keeps instance names in the map.
//   y[4:0] = x[3:0] + x[7:4],  y[5] = (x[3:0] < x[7:4]),  state: 1 bit, toggles when y[5] is 1
module hier_add4(input [3:0] a, input [3:0] b, output [4:0] q);
  assign q = a + b;
endmodule
module hier_lt4(input [3:0] a, input [3:0] b, output lt);
  assign lt = a < b;
endmodule
module hier_core(input [0:0] s, input [7:0] x, output [0:0] ns, output [5:0] y);
  wire [4:0] sum;
  wire lt;
  hier_add4 u_add(.a(x[3:0]), .b(x[7:4]), .q(sum));
  hier_lt4 u_cmp(.a(x[3:0]), .b(x[7:4]), .lt(lt));
  assign ns = s ^ lt;
  assign y = {lt, sum};
endmodule
