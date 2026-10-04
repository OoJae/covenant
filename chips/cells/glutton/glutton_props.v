// Glutton properties, on the netlist bytes (module `glutton_tap` = `tapc unpack` of glutton.tap or
// glutton512.tap). Each output must be 1 for every state and every input word.
//
// The same wrapper serves both variants: p_group_256 is proven for glutton.tap and p_group_512 for
// glutton512.tap (the Makefile names the signals to prove for each).
module glutton_props(
    input  wire [0:0]  s,
    input  wire [95:0] x,
    input  wire [95:0] xa,
    output wire p_demands_everything,   // T_ALLOW = V_ALLOW = REL = 256, CEIL = 1023, on every beat
    output wire p_group_256,            // glutton: both share groups are well formed (K1 does not fire)
    output wire p_group_512,            // glutton512: both share groups sum to 512 (K1T and K1V fire)
    output wire p_heartbeat,            // the one latch toggles and is shown in AUX bit 0
    output wire p_ignores_inputs        // nothing in the input word changes anything
);
    wire [0:0]   ns, ns2;
    wire [111:0] y, y2;
    glutton_tap u(.s(s), .x(x), .ns(ns), .y(y));
    glutton_tap u2(.s(s), .x(xa), .ns(ns2), .y(y2));

    wire [10:0] t_sum = {2'b0, y[8:0]} + {2'b0, y[17:9]} + {2'b0, y[26:18]} + {2'b0, y[35:27]};
    wire [10:0] v_sum = {2'b0, y[44:36]} + {2'b0, y[53:45]} + {2'b0, y[62:54]} + {2'b0, y[71:63]};

    assign p_demands_everything = (y[26:18] == 9'd256) & (y[62:54] == 9'd256) & (y[80:72] == 9'd256)
                                & (y[90:81] == 10'd1023);
    assign p_group_256      = (t_sum == 11'd256) & (v_sum == 11'd256);
    assign p_group_512      = (t_sum == 11'd512) & (v_sum == 11'd512);
    assign p_heartbeat      = (ns == ~s) & (y[111:104] == {7'd0, s});
    assign p_ignores_inputs = (ns2 == ns) & (y2 == y);
endmodule
