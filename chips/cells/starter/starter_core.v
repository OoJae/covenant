// Starter: the smallest useful Covenant vault chip (interface v1, chips/INTERFACE.md revision 2).
//
// A fixed split of every epoch's tax, with one ratchet kept in two latches:
//
//   T_BUY   192/256 (75%)   bought and locked, every beat
//   T_ALLOW 32, 16, 8 or 0  by tier: the allowance share steps down and never comes back up
//   T_RES   64 - T_ALLOW    kept in the reserve, released at REL = 4/256 per settle into buy-and-lock
//   V_RES   256             revenue (kernel v2 only) all to the reserve
//   CEIL    440             the chip's own ceiling on one settle's allowance: exp8(440) = 0.0338 OKB
//
// The tier is the state. Each beat the chip reads TAXCUM (the lg8 code of cumulative tax in the current regime)
// and computes the tier that reading has earned: 1 from about 0.94 OKB, 2 from about 9.2 OKB, 3 from about
// 92 OKB. On GRAD (graduation) the earned tier is 3: TAXCUM restarts in token units then, and kernel v1 pays no
// allowance after graduation anyway. The new tier is the larger of the old tier and the earned one, so it never
// decreases and the allowance share never increases (proved in starter_props.v for every state and input).
//
// Who can move the ratchet: anyone who sends OKB to the token's vault raises TAXCUM, because that OKB is routed
// like tax (chips/INTERFACE.md section 5). It can only push the allowance down, and the OKB is not returned.
//
// Telemetry (the kernel never reads it): TIER = the tier after this beat, FLAGS bit 0 = the tier stepped up in
// this beat. MODE and AUX are 0.
module starter_core(
    input  wire [1:0]   s,      // TIER, the allowance tier 0..3
    input  wire [95:0]  x,      // the kernel's input word
    output wire [1:0]   ns,
    output wire [111:0] y
);
    // Milestones: lg8 codes of cumulative OKB tax (1 OKB = code 478; one code is 1/8 octave).
    localparam [9:0] M1 = 10'd478;     // exp8(478) = 0.94 OKB
    localparam [9:0] M2 = 10'd505;     // exp8(505) = 9.2 OKB
    localparam [9:0] M3 = 10'd531;     // exp8(531) = 92 OKB

    localparam [8:0] BUY   = 9'd192;   // 75% of fresh tax to buy-and-lock
    localparam [8:0] KEEP  = 9'd64;    // T_ALLOW + T_RES
    localparam [8:0] REL   = 9'd4;     // 1/64 of the reserve per settle
    localparam [9:0] CEIL  = 10'd440;  // chip's own per-settle allowance ceiling

    wire [9:0] taxcum = x[19:10];
    wire       grad   = x[80];

    wire [1:0] earned = grad            ? 2'd3 :
                        (taxcum >= M3)  ? 2'd3 :
                        (taxcum >= M2)  ? 2'd2 :
                        (taxcum >= M1)  ? 2'd1 : 2'd0;
    wire [1:0] tier = (earned > s) ? earned : s;           // the ratchet

    wire [8:0] allow = (tier == 2'd0) ? 9'd32 :
                       (tier == 2'd1) ? 9'd16 :
                       (tier == 2'd2) ? 9'd8  : 9'd0;

    assign ns = tier;

    assign y[8:0]     = BUY;               // T_BUY
    assign y[17:9]    = 9'd0;              // T_HOLD
    assign y[26:18]   = allow;             // T_ALLOW
    assign y[35:27]   = KEEP - allow;      // T_RES
    assign y[44:36]   = 9'd0;              // V_BUY
    assign y[53:45]   = 9'd0;              // V_HOLD
    assign y[62:54]   = 9'd0;              // V_ALLOW
    assign y[71:63]   = 9'd256;            // V_RES
    assign y[80:72]   = REL;               // REL
    assign y[90:81]   = CEIL;              // CEIL
    assign y[93:91]   = 3'd0;              // MODE (telemetry, unused)
    assign y[95:94]   = tier;              // TIER (telemetry)
    assign y[103:96]  = {7'd0, tier != s}; // FLAGS (telemetry): bit 0 = stepped up
    assign y[111:104] = 8'd0;              // AUX (telemetry, unused)
endmodule
