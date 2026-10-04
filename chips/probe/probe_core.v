// Covenant probe circuit: "epoch meter".
//
// The first circuit taped out on the Covenant processor. Small, real and sequential.
// Core convention (chips/README.md): a pure combinational function core(s, x) -> (ns, y); `tapc` turns the
// pair (s, ns) into LATCH records, so state bit i is LATCH record i.
//
//   x[0]    en      count this beat
//   x[1]    clr     clear the count (wins over en); never clears the flag
//
//   s[7:0]  count   8-bit counter that saturates at 255 (it never wraps)
//   s[8]    flag    "ever saturated": set in the beat the count reaches 255, and never cleared again
//
//   y[7:0]  count   the count AFTER this beat (equal to ns[7:0])
//   y[8]    flag    the flag AFTER this beat (equal to ns[8])
//   y[9]    parity  XOR of the eight bits of y[7:0]
//
// Every bit is defined for every (s, x): there is no x/z and no don't-care in this file.
module probe_core(input [8:0] s, input [1:0] x, output [8:0] ns, output [9:0] y);
  wire       en    = x[0];
  wire       clr   = x[1];
  wire [7:0] count = s[7:0];
  wire       flag  = s[8];

  wire       full       = &count;                                 // count == 255
  wire [7:0] counted    = (en & ~full) ? count + 8'd1 : count;    // saturating increment
  wire [7:0] count_next = clr ? 8'd0 : counted;
  wire       flag_next  = flag | (&count_next);

  assign ns = {flag_next, count_next};
  assign y  = {^count_next, flag_next, count_next};
endmodule
