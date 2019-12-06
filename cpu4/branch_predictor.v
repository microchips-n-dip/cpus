module SaturationCounter
(
  input  i_clk,
  input  i_taken,
  output o_prediction
);

/* counter[1] indicates whether a branch is taken.
   counter[0] indicates the strength of the branch.
   */
   
/*
   SC : B * B * B -/> B * B
   (0, 0, 0) -> (0, 0)
   (0, 0, 1) -> (0, 1)
   (0, 1, 0) -> (0, 0)
   (0, 1, 1) -> (1, 0)
   (1, 0, 0) -> (0, 1)
   (1, 0, 1) -> (1, 1)
   (1, 1, 0) -> (1, 0)
   (1, 1, 1) -> (1, 1)
   */

reg [1:0] counter = 0;
wire strength;
wire taken;

assign taken        = i_taken && (counter[0] || counter[1]);
assign strength     = (i_taken && (!counter[0] || counter[1])) || (!counter[0] && counter[1]);
assign o_prediction = counter[1];

always @(posedge i_clk) begin
  counter <= {taken, strength};
end

endmodule

module BranchPredictor
(

);

endmodule

module top
(

);

reg clk;
reg taken;
wire prediction;

SaturationCounter
u_saturation_counter
(
  .i_clk        (clk),
  .i_taken      (taken),
  .o_prediction (prediction)
);

initial begin
  $dumpfile("dump.vcd");
  $dumpvars(0, u_saturation_counter);
  clk = 1'b0;
  taken = 1'b0;
  #10 clk = 1'b1;
  #10 clk = 1'b0;
  taken = 1'b1;
  #10 clk = 1'b1;
  #10 clk = 1'b0;
  #10 clk = 1'b1;
  #10 clk = 1'b0;
  taken = 1'b0;
  #10 clk = 1'b1;
  #10 clk = 1'b0;
  #10 clk = 1'b1;
  #10 clk = 1'b0;
  #10 clk = 1'b1;
  #10 clk = 1'b0;
  #10 clk = 1'b1;
  #10 clk = 1'b0;
  taken = 1'b1;
  #10 clk = 1'b1;
  #10 clk = 1'b0;
  #10 clk = 1'b1;
  #10 clk = 1'b0;
  #10 clk = 1'b1;
  #10 clk = 1'b0;
  #10 clk = 1'b1;
  #10 clk = 1'b0;
end

endmodule
