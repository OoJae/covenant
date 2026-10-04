// Properties of the cnt4 netlist (`cnt4_tap` is the unpacked TAP-20 netlist). The first three hold for every
// (s, x); p_never_zero is deliberately false and must be refuted with a counterexample.
module cnt4_props(input [3:0] s, input [0:0] x, output p_hold, output p_inc, output p_wrap, output p_never_zero);
  wire [3:0] ns;
  wire [4:0] y;
  cnt4_tap u(.s(s), .x(x), .ns(ns), .y(y));
  wire en = x[0];
  assign p_hold = en || (ns == s);
  assign p_inc = !en || (ns == s + 4'd1);
  assign p_wrap = (y[4] == (en && s == 4'd15)) && (y[3:0] == ns);
  assign p_never_zero = (ns != 4'd0);
endmodule
