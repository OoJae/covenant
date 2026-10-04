// NOT a valid core: it has a clock and a register. tapc must refuse it.
module bad_clocked_core(input clk, input [0:0] x, output reg [0:0] y);
  always @(posedge clk) y <= x;
endmodule
