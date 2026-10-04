// Glutton-512: the same hostile chip with a MALFORMED tax share group.
//
// T_BUY = 256 and T_ALLOW = 256: the group sums to 512. The kernel never reverts on chip output:
// K1T treats the group as 100% reserve, sets the clamp bit, stores the state and moves on. The
// allowance is then zero. The revenue group is malformed the same way (K1V, kernel v2).
module glutton512_core(
    input  wire [0:0]   s,
    input  wire [95:0]  x,      // ignored
    output wire [0:0]   ns,
    output wire [111:0] y
);
    assign ns = ~s;
    assign y[8:0]     = 9'd256;      // T_BUY
    assign y[17:9]    = 9'd0;        // T_HOLD
    assign y[26:18]   = 9'd256;      // T_ALLOW   -> the group sums to 512
    assign y[35:27]   = 9'd0;        // T_RES
    assign y[44:36]   = 9'd256;      // V_BUY
    assign y[53:45]   = 9'd0;        // V_HOLD
    assign y[62:54]   = 9'd256;      // V_ALLOW   -> 512 again
    assign y[71:63]   = 9'd0;        // V_RES
    assign y[80:72]   = 9'd256;      // REL: the whole reserve
    assign y[90:81]   = 10'd1023;    // CEIL: none
    assign y[93:91]   = 3'd7;        // MODE (telemetry)
    assign y[95:94]   = 2'd3;        // TIER (telemetry)
    assign y[103:96]  = 8'hFF;       // FLAGS (telemetry)
    assign y[111:104] = {7'd0, s};   // AUX: the heartbeat
endmodule
