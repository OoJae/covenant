// NOT a valid core: the incomplete if infers a level-sensitive latch. tapc must refuse it.
module bad_latch_core(input [1:0] x, output reg [0:0] y);
  always @* begin
    if (x[0]) y = x[1];
  end
endmodule
