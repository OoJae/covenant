// Glutton: the hostile demo chip (interface v1: 96 inputs, 112 outputs, 1 latch).
//
// Every beat, whatever the inputs, it demands everything:
//   T_ALLOW = 256/256 of fresh tax, V_ALLOW = 256/256 of fresh revenue,
//   REL = 256/256 of the reserve, CEIL = 1023 (no ceiling).
// Both share groups are well formed (they sum to 256), so K1 does not fire. What stops it is the
// envelope: K2 clips the allowance to capT, K3 clips the release to relMax (see README.md, demo.py).
//
// The single latch is a heartbeat (it toggles every beat) so that the chip is sequential, as the
// interface requires (nState >= 1). It is shown in AUX bit 0 and changes nothing else.
module glutton_core(
    input  wire [0:0]   s,
    input  wire [95:0]  x,      // ignored
    output wire [0:0]   ns,
    output wire [111:0] y
);
    assign ns = ~s;
    assign y[8:0]     = 9'd0;        // T_BUY
    assign y[17:9]    = 9'd0;        // T_HOLD
    assign y[26:18]   = 9'd256;      // T_ALLOW: all of it
    assign y[35:27]   = 9'd0;        // T_RES
    assign y[44:36]   = 9'd0;        // V_BUY
    assign y[53:45]   = 9'd0;        // V_HOLD
    assign y[62:54]   = 9'd256;      // V_ALLOW: all of it
    assign y[71:63]   = 9'd0;        // V_RES
    assign y[80:72]   = 9'd256;      // REL: the whole reserve
    assign y[90:81]   = 10'd1023;    // CEIL: none
    assign y[93:91]   = 3'd7;        // MODE (telemetry)
    assign y[95:94]   = 2'd3;        // TIER (telemetry)
    assign y[103:96]  = 8'hFF;       // FLAGS (telemetry)
    assign y[111:104] = {7'd0, s};   // AUX: the heartbeat
endmodule
