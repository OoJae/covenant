// Starter properties, on the netlist bytes (module `starter_tap` = `tapc unpack` of the synthesised netlist).
// Each output must be 1 for every state and every input word; `chips/kit/kit.sh build` proves them with Yosys SAT
// and z3. Two beats are chained where a property is about what can happen next: u steps (s, x), u2 steps the
// resulting state with any other input word xa.
module starter_props(
    input  wire [1:0]  s,
    input  wire [95:0] x,
    input  wire [95:0] xa,
    output wire p_tshares_256,        // the four T_ shares sum to exactly 256 (K1T never fires)
    output wire p_vshares_256,        // the four V_ shares sum to exactly 256 (K1V never fires on kernel v2)
    output wire p_ratchet,            // the tier never decreases
    output wire p_never_loosens,      // whatever the next input, the next beat's allowance share is at most this one's
    output wire p_allow_by_tier,      // T_ALLOW is 32, 16, 8, 0 for tiers 0..3, and T_BUY is always 192
    output wire p_grad_no_allow,      // once GRAD is seen the tier is 3 and the allowance share is 0
    output wire p_reference_envelope, // inside the reference envelope: T_ALLOW <= 48, 2 <= REL <= 128, CEIL <= 440
    output wire p_telemetry           // TIER shows the new tier; FLAGS bit 0 says it stepped up; the rest is 0
);
    wire [1:0]   ns, ns2;
    wire [111:0] y, y2;
    starter_tap u(.s(s), .x(x), .ns(ns), .y(y));
    starter_tap u2(.s(ns), .x(xa), .ns(ns2), .y(y2));

    wire [8:0] t_buy = y[8:0], t_hold = y[17:9], t_allow = y[26:18], t_res = y[35:27];
    wire [10:0] t_sum = {2'b0, t_buy} + {2'b0, t_hold} + {2'b0, t_allow} + {2'b0, t_res};
    wire [10:0] v_sum = {2'b0, y[44:36]} + {2'b0, y[53:45]} + {2'b0, y[62:54]} + {2'b0, y[71:63]};
    wire [8:0] rel = y[80:72];
    wire [9:0] ceil = y[90:81];

    assign p_tshares_256   = (t_sum == 11'd256);
    assign p_vshares_256   = (v_sum == 11'd256);
    assign p_ratchet       = (ns >= s) & (ns2 >= ns);
    assign p_never_loosens = (y2[26:18] <= t_allow);
    assign p_allow_by_tier = (t_buy == 9'd192) &
                             (t_allow == ((ns == 2'd0) ? 9'd32 : (ns == 2'd1) ? 9'd16 : (ns == 2'd2) ? 9'd8 : 9'd0));
    assign p_grad_no_allow = ~x[80] | ((ns == 2'd3) & (t_allow == 9'd0) & (y2[26:18] == 9'd0));
    assign p_reference_envelope = (t_allow <= 9'd48) & (rel >= 9'd2) & (rel <= 9'd128) & (ceil <= 10'd440);
    assign p_telemetry     = (y[95:94] == ns) & (y[103:96] == {7'd0, ns != s}) & (y[93:91] == 3'd0)
                           & (y[111:104] == 8'd0);
endmodule
