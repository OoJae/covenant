// Properties of the probe netlist, for every state s and every input x.
//
// `probe_tap` is the taped netlist itself, unpacked by `tapc` (one beat as a combinational module), so these
// are statements about the bytes that go on chain, not about the RTL. Each output is proven to be 1 for all
// (s, x) with `tapc prove prop` (Yosys SAT, and again with z3).
module probe_props(input [8:0] s, input [1:0] x,
                   output p_flag_sticky, output p_saturated_implies_flag, output p_outputs_mirror_state,
                   output p_parity, output p_clr_wins, output p_hold, output p_never_wraps,
                   output p_counts_by_one);
  wire [8:0] ns;
  wire [9:0] y;
  probe_tap u(.s(s), .x(x), .ns(ns), .y(y));

  wire       en = x[0], clr = x[1];
  wire [7:0] c = s[7:0], c1 = ns[7:0];

  // the flag is a ratchet: once set it stays set, whatever the inputs
  assign p_flag_sticky = !s[8] || ns[8];
  // state invariant, in its one-step form: after any beat, a count of 255 has the flag set.
  // (The zero state satisfies it trivially, so it holds in every reachable state.)
  assign p_saturated_implies_flag = (c1 != 8'd255) || ns[8];
  // the outputs are the state after the beat
  assign p_outputs_mirror_state = (y[8:0] == ns);
  assign p_parity = (y[9] == ^y[7:0]);
  // clr wins over en
  assign p_clr_wins = !clr || (c1 == 8'd0);
  // nothing moves without en or clr
  assign p_hold = (en || clr) || (c1 == c);
  // without clr the count never goes down, and 255 stays 255
  assign p_never_wraps = clr || (c1 >= c);
  // en without clr adds exactly one below saturation
  assign p_counts_by_one = !(en && !clr && c != 8'd255) || (c1 == c + 8'd1);
endmodule
