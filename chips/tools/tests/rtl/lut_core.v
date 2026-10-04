// Smoke-test core with a case table. Yosys's `proc` turns such a table into a ROM cell unless told not to;
// the SAT pass cannot model a ROM and the SMT-LIB backend leaves its contents free. This core checks that
// synthesis maps the table to gates and that both proof paths see it as plain logic.
//   x[3:0] = index, x[4] = add;  s[5:0] = accumulator;  y[5:0] = table[index] (+ accumulator when add)
module lut_core(input [5:0] s, input [4:0] x, output [5:0] ns, output [5:0] y);
  reg [5:0] t;
  always @* case (x[3:0])
    4'd0: t = 6'd0;   4'd1: t = 6'd0;   4'd2: t = 6'd8;   4'd3: t = 6'd13;
    4'd4: t = 6'd16;  4'd5: t = 6'd19;  4'd6: t = 6'd21;  4'd7: t = 6'd22;
    4'd8: t = 6'd24;  4'd9: t = 6'd25;  4'd10: t = 6'd27; 4'd11: t = 6'd28;
    4'd12: t = 6'd29; 4'd13: t = 6'd30; 4'd14: t = 6'd30; default: t = 6'd31;
  endcase
  assign y = x[4] ? t + s : t;
  assign ns = y;
endmodule
