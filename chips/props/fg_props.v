// Flow Governor properties. Each 1-bit output must be 1 for EVERY value of the free inputs.
//
// The module under test is `fg_tap`: the taped-out netlist bytes unpacked to structural Verilog by
// `tapc unpack` (one beat = a pure combinational function). So every property here is a statement
// about the bytes that go on chain, not about the RTL.
//
// Read together with fg_params.vh (constants FG_* and the reference envelope ENV_*):
//   read_verilog -sv fg_params.vh fg_props.v gate.v
//
// Free inputs: s (64 state bits), x (96 input bits), and two helper vectors used by the two-copy
// properties: xa (an alternative input word) and ta (an alternative tier).

module fg_props(
    input  wire [63:0] s,
    input  wire [95:0] x,
    input  wire [95:0] xa,
    input  wire [1:0]  ta,
    // P1 share groups
    output wire p1_t_sum, output wire p1_t_each, output wire p1_v_sum, output wire p1_v_each,
    output wire p1_hold_zero,
    // P2 clamp-freedom against the reference envelope
    output wire p2_allow_cap, output wire p2_vallow_cap, output wire p2_rel_cap, output wire p2_floor,
    output wire p2_floor_always, output wire p2_ceil, output wire p2_ceil_finite,
    // P3 ratchets
    output wire p3_tier_up, output wire p3_tier_out, output wire p3_allow_bound, output wire p3_ceil_exact,
    output wire p3_tier_frozen_grad, output wire p3_mono_allow, output wire p3_mono_ceil,
    output wire p3_no_allow_grad,
    // P4 inductive invariant
    output wire p4_init, output wire p4_step, output wire p4_mode_out,
    // P5 ignored inputs
    output wire p5_ignored,
    // P6 cooldown
    output wire p6_no_release, output wire p6_counts_down, output wire p6_stays, output wire p6_tranche_flag,
    output wire p6_defend_shares,
    // extra: DT = 0 is read as 1; graduation is seen once; the graduation step only re-seeds
    output wire px_dt0, output wire px_gseen, output wire px_grad_step
);
    wire [63:0]  ns;
    wire [111:0] y;
    fg_tap u(.s(s), .x(x), .ns(ns), .y(y));

    // ---------------------------------------------------------------- fields
    wire [9:0] RES    = x[49:40];
    wire [3:0] DT     = x[79:76];
    wire       GRAD   = x[80];
    wire [3:0] dt     = (DT == 4'd0) ? 4'd1 : DT;

    wire [8:0] T_BUY   = y[8:0];
    wire [8:0] T_HOLD  = y[17:9];
    wire [8:0] T_ALLOW = y[26:18];
    wire [8:0] T_RES   = y[35:27];
    wire [8:0] V_BUY   = y[44:36];
    wire [8:0] V_HOLD  = y[53:45];
    wire [8:0] V_ALLOW = y[62:54];
    wire [8:0] V_RES   = y[71:63];
    wire [8:0] REL     = y[80:72];
    wire [9:0] CEIL    = y[90:81];
    wire [2:0] MODE_O  = y[93:91];
    wire [1:0] TIER_O  = y[95:94];
    wire [7:0] FLAGS   = y[103:96];

    wire [1:0] s_TIER  = s[28:27];
    wire       s_GSEEN = s[29];
    wire [2:0] s_MODE  = s[26:24];
    wire [2:0] s_CD    = s[42:40];
    wire [1:0] n_TIER  = ns[28:27];
    wire       n_GSEEN = ns[29];
    wire [2:0] n_MODE  = ns[26:24];
    wire [2:0] n_CD    = ns[42:40];

    localparam [2:0] BANK = 3'd2, DEFEND = 3'd3, REST = 3'd4;

    // ---------------------------------------------------------------- P1
    assign p1_t_sum     = ({2'b0, T_BUY} + {2'b0, T_HOLD} + {2'b0, T_ALLOW} + {2'b0, T_RES}) == 11'd256;
    assign p1_t_each    = (T_BUY <= 9'd256) & (T_HOLD <= 9'd256) & (T_ALLOW <= 9'd256) & (T_RES <= 9'd256);
    assign p1_v_sum     = ({2'b0, V_BUY} + {2'b0, V_HOLD} + {2'b0, V_ALLOW} + {2'b0, V_RES}) == 11'd256;
    assign p1_v_each    = (V_BUY <= 9'd256) & (V_HOLD <= 9'd256) & (V_ALLOW <= 9'd256) & (V_RES <= 9'd256);
    assign p1_hold_zero = (T_HOLD == 9'd0);

    // ---------------------------------------------------------------- P2 (kernel clamps K2, K2V, K3, K5, K2C)
    assign p2_allow_cap    = (T_ALLOW <= ENV_CAPT);
    assign p2_vallow_cap   = (V_ALLOW <= ENV_CAPV);
    assign p2_rel_cap      = (REL <= ENV_RELMAX);
    assign p2_floor        = (RES < ENV_FLOORMIN) | (REL >= ENV_FLOORREL);       // exactly K5
    assign p2_floor_always = (REL >= ENV_FLOORREL);                              // stronger: for every reserve
    assign p2_ceil         = (ENV_CEILMAX == 10'd1023) | (CEIL <= ENV_CEILMAX);  // then exp8(CEIL) <= exp8(ceilMax)
    assign p2_ceil_finite  = (ENV_CEILMAX == 10'd1023) | (CEIL != 10'd1023);     // the chip's own ceiling applies

    // ---------------------------------------------------------------- P3
    wire [5:0] al_of_out = (TIER_O == 2'd0) ? FG_AL0 : (TIER_O == 2'd1) ? FG_AL1 : (TIER_O == 2'd2) ? FG_AL2 : FG_AL3;
    assign p3_tier_up          = (n_TIER >= s_TIER);
    assign p3_tier_out         = (TIER_O == n_TIER);
    assign p3_allow_bound      = (T_ALLOW <= {3'd0, al_of_out});
    assign p3_ceil_exact       = (CEIL == FG_CEIL0 - {5'd0, TIER_O, 3'b000});
    assign p3_tier_frozen_grad = ~GRAD | (n_TIER == s_TIER);
    assign p3_no_allow_grad    = ~GRAD | (T_ALLOW == 9'd0);
    // two copies that differ only in the stored tier: a higher tier never gives a larger allowance or ceiling
    wire [63:0]  s2 = {s[63:29], ta, s[26:0]};
    wire [63:0]  ns2;
    wire [111:0] y2;
    fg_tap u2(.s(s2), .x(x), .ns(ns2), .y(y2));
    assign p3_mono_allow = (ta < s_TIER) | (y2[26:18] <= T_ALLOW);
    assign p3_mono_ceil  = (ta < s_TIER) | (y2[90:81] <= CEIL);

    // ---------------------------------------------------------------- P4 inductive invariant
    function automatic inv(input [63:0] q);
        reg [11:0] A; reg [9:0] PK; reg [2:0] MODE; reg [1:0] WARM; reg [3:0] LIVE; reg [1:0] SUR;
        reg [1:0] TR; reg [2:0] CD;
        begin
            A = q[11:0]; PK = q[21:12]; MODE = q[26:24]; WARM = q[31:30]; LIVE = q[35:32]; SUR = q[37:36];
            TR = q[39:38]; CD = q[42:40];
            inv = (MODE <= 3'd4)                                   // only the five named modes
                & (LIVE <= FG_DRYN)                                // the drought countdown never exceeds its reload
                & (CD <= 3'd5)                                     // a cooldown has at most 5 epochs left
                & ((MODE == DEFEND) | (TR == 2'd0))                // tranche epochs only while defending
                & ((MODE == REST) | (CD == 3'd0))                  // cooldown epochs only while resting
                & ((MODE != BANK) | (SUR != 2'd0))                 // BANK only while the surge meter is up
                & ((WARM == 2'd0) | (LIVE >= {2'b00, WARM} + 4'd5))// warm-up implies recent live flow
                & (PK >= A[11:2])                                  // the peak is never below the average
                & (PK <= 10'd1023 - FG_FLOOR_Q)                    // codes above the floor fit the code range
                & (A <= {10'd1023 - FG_FLOOR_Q, 2'b00});
        end
    endfunction
    assign p4_init     = inv(64'd0);
    assign p4_step     = ~inv(s) | inv(ns);
    assign p4_mode_out = (MODE_O == n_MODE);

    // ---------------------------------------------------------------- P5 ignored inputs
    // xb takes TAX, TAXCUM, RES, DT, GRAD from x and everything else (REV, REVCUM, ESC, PROG, LOCK, 81..95) from xa
    wire [95:0] xb = {xa[95:81], x[80:76], xa[75:50], x[49:40], xa[39:20], x[19:0]};
    wire [63:0]  ns3;
    wire [111:0] y3;
    fg_tap u3(.s(s), .x(xb), .ns(ns3), .y(y3));
    assign p5_ignored = (ns3 == ns) & (y3 == y);

    // ---------------------------------------------------------------- P6 cooldown
    wire        cooling  = (s_MODE == REST) & (s_CD != 3'd0);
    wire        inside   = (s_MODE == REST) & ({1'b0, s_CD} >= dt);          // the whole step lies in the cooldown
    wire        ge       = GRAD & ~s_GSEEN;
    wire [8:0]  leak     = {4'd0, dt, 1'b0};                                 // FG_LEAK (2) per elapsed epoch
    assign p6_no_release   = ~(inside | (cooling & ge)) | (REL == leak);     // only the floor leak
    assign p6_counts_down  = ~cooling | (n_CD < s_CD);                       // strictly decreasing
    assign p6_stays        = ~(inside & ~ge) | ((n_MODE == REST) & (n_CD == s_CD - dt[2:0]));
    assign p6_tranche_flag = (REL == leak) | (FLAGS[3] & (REL >= {1'b0, FG_TR_MIN}));   // above the leak = a tranche
    assign p6_defend_shares = ~FLAGS[3] | ((T_BUY == 9'd256) & (T_ALLOW == 9'd0) & (T_RES == 9'd0));

    // ---------------------------------------------------------------- extras
    wire [95:0] x1 = {x[95:80], 4'd1, x[75:0]};
    wire [63:0]  ns4;
    wire [111:0] y4;
    fg_tap u4(.s(s), .x(x1), .ns(ns4), .y(y4));
    assign px_dt0   = (DT != 4'd0) | ((ns4 == ns) & (y4 == y));
    assign px_gseen = (n_GSEEN == (s_GSEEN | GRAD));
    // on the step that first sees graduation: flagged, no tranche, no DEFEND or BANK or REST, tier kept
    assign px_grad_step = (FLAGS[4] == ge)
                        & (~ge | ((REL == leak) & ~FLAGS[3] & (n_MODE <= 3'd1) & (n_TIER == s_TIER)
                                  & (ns[39:38] == 2'd0) & (n_CD == 3'd0)));
endmodule
