// GENERATED from fg_params.json by gen_params.py. Do not edit by hand.
// Flow Governor constants (FG_*) and the reference-token envelope (ENV_*).
// Every value is frozen into an immutable chip or kernel clone: change the JSON, regenerate,
// re-run every proof.

localparam [9:0] FG_FLOOR_Q = 10'd346;
localparam [9:0] FG_FLOOR_T = 10'd530;
localparam [9:0] FG_RESMIN_Q = 10'd389;
localparam [9:0] FG_RESMIN_T = 10'd573;
localparam [9:0] FG_M1 = 10'd425;
localparam [9:0] FG_M2 = 10'd452;
localparam [9:0] FG_M3 = 10'd479;
localparam [5:0] FG_AL0 = 6'd48;
localparam [5:0] FG_AL1 = 6'd32;
localparam [5:0] FG_AL2 = 6'd16;
localparam [5:0] FG_AL3 = 6'd8;
localparam [9:0] FG_CEIL0 = 10'd440;
localparam [9:0] FG_CEIL_STEP = 10'd8;
localparam [7:0] FG_RC = 8'd64;
localparam [7:0] FG_RB_MIN = 8'd128;
localparam [2:0] FG_RB_GAIN = 3'd4;
localparam [4:0] FG_RB_SPAN = 5'd16;
localparam [5:0] FG_SURGE_TH = 6'd8;
localparam [5:0] FG_XSURGE_TH = 6'd32;
localparam [5:0] FG_DIP_TH = 6'd8;
localparam [9:0] FG_DD_TH = 10'd16;
localparam [1:0] FG_SUR_ON = 2'd2;
localparam [3:0] FG_SLEW_Q = 4'd12;
localparam [2:0] FG_PK_DIV = 3'd4;
localparam [3:0] FG_DRYN = 4'd8;
localparam [1:0] FG_WARMN = 2'd3;
localparam [2:0] FG_TRN = 3'd4;
localparam [2:0] FG_CDN = 3'd6;
localparam [7:0] FG_TR_MIN = 8'd32;
localparam [7:0] FG_TR_MAX = 8'd64;
localparam [8:0] FG_REL_CAP = 9'd128;
localparam [1:0] FG_LEAK = 2'd2;

localparam [8:0] ENV_CAPT = 9'd48;
localparam [8:0] ENV_CAPV = 9'd0;
localparam [13:0] ENV_ALLOWCUMBPS = 14'd1875;
localparam [9:0] ENV_CEILMAX = 10'd440;
localparam [8:0] ENV_RELMAX = 9'd128;
localparam [8:0] ENV_FLOORREL = 9'd2;
localparam [9:0] ENV_FLOORMIN = 10'd1;
localparam [15:0] ENV_FALLBACKEPOCHS = 16'd16;
localparam [8:0] ENV_FBALLOW = 9'd8;
localparam [31:0] ENV_EPOCHLEN = 32'd900;

// round(8 * log2(dt)): the code offset that turns a settle covering dt epochs into a per-epoch rate.
// Written as a chain of conditionals, not a case statement: Yosys would turn a case into a ROM cell,
// which its SAT pass and its SMT-LIB writer do not model as a constant table.
function automatic [4:0] fg_log8dt(input [3:0] dt);
  fg_log8dt =
    (dt == 4'd2) ? 5'd8 :
    (dt == 4'd3) ? 5'd13 :
    (dt == 4'd4) ? 5'd16 :
    (dt == 4'd5) ? 5'd19 :
    (dt == 4'd6) ? 5'd21 :
    (dt == 4'd7) ? 5'd22 :
    (dt == 4'd8) ? 5'd24 :
    (dt == 4'd9) ? 5'd25 :
    (dt == 4'd10) ? 5'd27 :
    (dt == 4'd11) ? 5'd28 :
    (dt == 4'd12) ? 5'd29 :
    (dt == 4'd13) ? 5'd30 :
    (dt == 4'd14) ? 5'd30 :
    (dt == 4'd15) ? 5'd31 :
    5'd0;
endfunction
