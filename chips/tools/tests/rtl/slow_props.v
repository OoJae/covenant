// Test fixture for proof time limits: p_slow is true but hard for a SAT solver (commutativity of a 16 x 16
// multiplier), the two around it are trivial. tapc must report p_slow as a timeout and still decide the others.
module slow_props(input [15:0] a, input [15:0] b, output p_fast1, output p_slow, output p_fast2);
  assign p_fast1 = (a & b) == (b & a);
  assign p_slow  = (a * b) == (b * a);
  assign p_fast2 = (a | b) == (b | a);
endmodule
