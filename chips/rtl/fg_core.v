// Flow Governor: the flagship Covenant vault chip (interface v1, chips/INTERFACE.md).
//
//   fg_core(s, x) -> (ns, y)      pure combinational; the packer adds 64 LATCH records; reset state = 0.
//
// Bit-exact twin of chips/model/flow_governor.py (same names, same order). Constants are the file-scope
// localparams of fg_params.vh, generated from fg_params.json; read both files in one command:
//   read_verilog -sv fg_params.vh fg_core.v
//
// Inputs used: TAX x[9:0], TAXCUM x[19:10], RES x[49:40], DT x[79:76], GRAD x[80].
// Everything else in x (REV, REVCUM, ESC, PROG, LOCK, bits 81..95) is ignored (property P5).

module fg_core(
    input  wire [63:0]  s,
    input  wire [95:0]  x,
    output wire [63:0]  ns,
    output wire [111:0] y
);
    localparam [2:0] IDLE = 3'd0, CRUISE = 3'd1, BANK = 3'd2, DEFEND = 3'd3, REST = 3'd4;

    // ------------------------------------------------------------------ state
    wire [11:0] A_r     = s[11:0];
    wire [9:0]  PK_r    = s[21:12];
    wire [1:0]  PKDIV_r = s[23:22];
    wire [2:0]  MODE_r  = s[26:24];
    wire [1:0]  TIER    = s[28:27];
    wire        GSEEN   = s[29];
    wire [1:0]  WARM_r  = s[31:30];
    wire [3:0]  LIVE_r  = s[35:32];
    wire [1:0]  SUR_r   = s[37:36];
    wire [1:0]  TR_r    = s[39:38];
    wire [2:0]  CD_r    = s[42:40];
    wire [4:0]  NBANK   = s[47:43];
    wire [5:0]  NDEF    = s[53:48];
    wire [9:0]  CLOCK   = s[63:54];

    // ------------------------------------------------------------------ inputs
    wire [9:0] TAX    = x[9:0];
    wire [9:0] TAXCUM = x[19:10];
    wire [9:0] RES    = x[49:40];
    wire [3:0] DT     = x[79:76];
    wire       GRAD   = x[80];

    wire [3:0] dt = (DT == 4'd0) ? 4'd1 : DT;          // the kernel never sends 0; treat it as 1

    // ------------------------------------------------------------------ graduation re-seed
    // The tax unit changes from the quote asset to the project token: drop everything measured in the
    // old unit. TIER, GSEEN and the telemetry counters survive.
    wire        ge    = GRAD & ~GSEEN;
    wire [11:0] A     = ge ? 12'd0 : A_r;
    wire [9:0]  PK    = ge ? 10'd0 : PK_r;
    wire [1:0]  PKDIV = ge ? 2'd0  : PKDIV_r;
    wire [2:0]  MODE  = ge ? 3'd0  : MODE_r;
    wire [1:0]  WARM  = ge ? 2'd0  : WARM_r;
    wire [3:0]  LIVE  = ge ? 4'd0  : LIVE_r;
    wire [1:0]  SUR   = ge ? 2'd0  : SUR_r;
    wire [1:0]  TR    = ge ? 2'd0  : TR_r;
    wire [2:0]  CD    = ge ? 3'd0  : CD_r;

    wire [9:0] floor  = GRAD ? FG_FLOOR_T  : FG_FLOOR_Q;
    wire [9:0] resmin = GRAD ? FG_RESMIN_T : FG_RESMIN_Q;

    // ------------------------------------------------------------------ reading
    wire [9:0] K    = floor + {5'd0, fg_log8dt(dt)};
    wire [9:0] l    = (TAX > K) ? (TAX - K) : 10'd0;   // tax rate per epoch, codes above the floor
    wire       live = (l != 10'd0);
    wire       cold = (LIVE == 4'd0);
    wire       seed = cold & live;
    wire       warm = seed | (WARM != 2'd0);

    wire signed [12:0] d = $signed({1'b0, l, 2'b00}) - $signed({1'b0, A});     // quarter-codes
    wire signed [10:0] g = $signed({1'b0, l}) - $signed({1'b0, PK});           // codes above the peak
    wire surge  = ~cold & (WARM == 2'd0) & (g >= $signed({5'd0, FG_SURGE_TH}));
    wire xsurge = surge & (g >= $signed({5'd0, FG_XSURGE_TH}));
    wire dip    = ~cold & (d <= -$signed({5'd0, FG_DIP_TH, 2'b00}));

    // ------------------------------------------------------------------ average
    wire        dt1    = (dt == 4'd1);
    wire        dt23   = (dt == 4'd2) | (dt == 4'd3);
    wire        up     = ~d[12];
    wire        full   = (warm & up) | ~(dt1 | dt23);                          // shift 0
    wire signed [12:0] st  = full ? d : (dt1 ? (d >>> 2) : (d >>> 1));
    wire [7:0]  lim    = {1'b0, dt, 3'b000} + {2'b00, dt, 2'b00};              // FG_SLEW_Q (12) * dt
    wire signed [12:0] nlim = -$signed({5'd0, lim});
    wire signed [12:0] stp = (st >= nlim) ? st : nlim;
    wire [12:0] a_sum  = {1'b0, A} + stp;
    wire [11:0] A1     = seed ? {l, 2'b00} : a_sum[11:0];

    // ------------------------------------------------------------------ decaying peak, drawdown depth
    wire [4:0]  pdsum  = {3'd0, PKDIV} + {1'b0, dt};
    wire [2:0]  dec    = pdsum[4:2];
    wire [1:0]  PKDIV1 = pdsum[1:0];
    wire [9:0]  pkd    = (PK > {7'd0, dec}) ? (PK - {7'd0, dec}) : 10'd0;
    wire [9:0]  a1c    = A1[11:2];
    wire [9:0]  PK1    = seed ? l : ((a1c > pkd) ? a1c : pkd);
    wire [9:0]  dd     = PK1 - a1c;

    // ------------------------------------------------------------------ timers and meters
    wire [3:0] LIVE1 = live ? FG_DRYN : ((LIVE > dt) ? (LIVE - dt) : 4'd0);
    wire       drought = (LIVE1 == 4'd0);
    wire [1:0] WARM1 = seed ? FG_WARMN : (({2'b00, WARM} > dt) ? (WARM - dt[1:0]) : 2'd0);
    wire [5:0] ssum  = {4'd0, SUR} + {2'd0, dt} + {5'd0, xsurge};
    wire [1:0] SUR1  = surge ? ((ssum > 6'd3) ? 2'd3 : ssum[1:0])
                             : (({2'b00, SUR} > dt) ? (SUR - dt[1:0]) : 2'd0);

    // ------------------------------------------------------------------ allowance ratchet
    wire [1:0] tm    = (TAXCUM >= FG_M3) ? 2'd3 : (TAXCUM >= FG_M2) ? 2'd2 : (TAXCUM >= FG_M1) ? 2'd1 : 2'd0;
    wire [1:0] TIER1 = GRAD ? TIER : ((tm > TIER) ? tm : TIER);

    wire can = (RES >= resmin);

    // ------------------------------------------------------------------ mode
    wire in_def  = (MODE == DEFEND);
    wire in_rest = (MODE == REST);
    wire in_bank = (MODE == BANK);
    wire [1:0] trn  = (dt >= {2'b00, TR}) ? TR : dt[1:0];
    wire [3:0] over = dt - {2'b00, trn};
    wire def_go     = in_def & (TR != 2'd0) & can & ~surge;
    wire rest_start = in_def & ~def_go;
    wire rest_cont  = in_rest & ({1'b0, CD} >= dt);
    wire bank_stay  = in_bank & (SUR1 != 2'd0);
    wire base       = ~(in_def | rest_cont | bank_stay);
    wire [3:0] slack = in_rest ? (dt - {1'b0, CD}) : 4'd1;
    wire bank_enter = base & surge & SUR1[1];
    wire fade       = in_bank & dip;
    wire trig       = (dd >= FG_DD_TH) | drought | fade;
    wire def_enter  = base & ~bank_enter & trig & can & ~ge;                    // never on the re-seed step
    wire [1:0] nen  = (slack >= 4'd3) ? 2'd3 : slack[1:0];
    wire is_def     = def_go | def_enter;
    wire [1:0] ntr  = def_enter ? nen : (def_go ? trn : 2'd0);
    wire def_more   = def_go & (over == 4'd0);
    wire def_done   = def_go & (over != 4'd0);
    wire is_bank    = bank_stay | bank_enter;
    wire to_rest    = def_done | rest_start | rest_cont;

    wire [2:0] MODE1 = (def_enter | def_more) ? DEFEND
                     : to_rest ? REST
                     : is_bank ? BANK
                     : drought ? IDLE : CRUISE;
    wire [1:0] TR1 = def_enter ? (2'd0 - nen) : (def_more ? (TR - trn) : 2'd0);        // TRN (4) - nen
    wire [3:0] cdsub = def_done ? over : dt;
    wire [2:0] cdfrom = rest_cont ? CD : FG_CDN;
    wire [2:0] CD1 = (to_rest & ({1'b0, cdfrom} > cdsub)) ? (cdfrom - cdsub[2:0]) : 3'd0;

    // ------------------------------------------------------------------ shares of fresh tax
    wire [5:0] al_t = (TIER1 == 2'd0) ? FG_AL0 : (TIER1 == 2'd1) ? FG_AL1 : (TIER1 == 2'd2) ? FG_AL2 : FG_AL3;
    wire [5:0] al   = GRAD ? 6'd0 : al_t;
    wire signed [11:0] gsub = $signed({g[10], g}) - $signed({6'd0, FG_SURGE_TH});
    wire [4:0] gg   = gsub[11] ? 5'd0 : ((gsub > $signed({7'd0, FG_RB_SPAN})) ? FG_RB_SPAN : gsub[4:0]);
    wire [7:0] rb   = FG_RB_MIN + {1'b0, gg, 2'b00};                                   // + FG_RB_GAIN (4) * gg
    wire [5:0] allow = is_def ? 6'd0 : (is_bank ? {1'b0, al[5:1]} : al);
    wire [7:0] res   = is_def ? 8'd0 : (is_bank ? rb : FG_RC);
    wire [8:0] buy   = 9'd256 - {3'd0, allow} - {1'b0, res};

    // ------------------------------------------------------------------ reserve release
    wire [7:0] r   = (dd >= {3'd0, FG_TR_MAX[7:1]}) ? FG_TR_MAX
                   : (dd <= {3'd0, FG_TR_MIN[7:1]}) ? FG_TR_MIN : {dd[6:0], 1'b0};
    wire [8:0] leak = {4'd0, dt, 1'b0};                                               // FG_LEAK (2) * dt
    wire [8:0] rel = is_def ? (ntr[1] ? {r, 1'b0} : {1'b0, r}) : leak;

    wire [9:0] ceil = FG_CEIL0 - {5'd0, TIER1, 3'b000};                                // - FG_CEIL_STEP (8) * tier

    // ------------------------------------------------------------------ telemetry
    wire [4:0] NBANK1 = (bank_enter & (NBANK != 5'd31)) ? (NBANK + 5'd1) : NBANK;
    wire [5:0] NDEF1  = (def_enter & (NDEF != 6'd63)) ? (NDEF + 6'd1) : NDEF;
    wire [9:0] CLOCK1 = CLOCK + {6'd0, dt};
    wire       GSEEN1 = GSEEN | GRAD;
    wire [7:0] flags  = {warm, to_rest, (TIER1 != TIER), ge, is_def, ~live, dip, surge};
    wire [7:0] aux    = (dd > 10'd255) ? 8'd255 : dd[7:0];

    assign ns = {CLOCK1, NDEF1, NBANK1, CD1, TR1, SUR1, LIVE1, WARM1, GSEEN1, TIER1, MODE1, PKDIV1, PK1, A1};

    // ------------------------------------------------------------------ output word
    assign y[8:0]     = buy;                 // T_BUY
    assign y[17:9]    = 9'd0;                // T_HOLD  (kernel v1 has no holder route)
    assign y[26:18]   = {3'd0, allow};       // T_ALLOW
    assign y[35:27]   = {1'b0, res};         // T_RES
    assign y[44:36]   = 9'd0;                // V_BUY   (no revenue in kernel v1: a well-formed all-reserve group)
    assign y[53:45]   = 9'd0;                // V_HOLD
    assign y[62:54]   = 9'd0;                // V_ALLOW
    assign y[71:63]   = 9'd256;              // V_RES
    assign y[80:72]   = rel;                 // REL
    assign y[90:81]   = ceil;                // CEIL
    assign y[93:91]   = MODE1;               // MODE
    assign y[95:94]   = TIER1;               // TIER
    assign y[103:96]  = flags;               // FLAGS
    assign y[111:104] = aux;                 // AUX
endmodule
