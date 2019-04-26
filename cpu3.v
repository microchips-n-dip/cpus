/* pending_queue takes care of queueing up instructions. */

module
pending_queue(
	input clk,
	input rst,
	input push,
	input next,
	input clear,
	output empty,
	output full,
	input [23:0] in_insn,
	output [23:0] out_insn
);

wire stop0;
wire stop1;

reg [23:0] insn = 16'hff00;
reg [23:0] pending [0:7];
reg [3:0] pending_head = 0;
reg [3:0] pending_tail = 0;

/* When clear is set, it enables both stops so nothing advanced and sets
   head to tail. */

assign stop0 = (pending_head == pending_tail) | clear;
assign stop1 = (pending_head + 1 == pending_tail) | clear;
assign empty = stop0;
assign full = stop1;
assign out_insn = insn;

always @(posedge clk) begin
	if (rst) begin
		insn <= 0;
		pending_tail <= 0;
	end
	else if (next && !stop0) begin
		insn <= pending[pending_tail];
		pending_tail <= pending_tail + 1;
	end
	if (rst) begin
		pending_head <= 0;
	end
	else if (push && !stop1) begin
		pending[pending_head] <= in_insn;
		pending_head <= pending_head + 1;
	end
	if (clear) begin
		pending_head <= pending_tail;
	end
end

endmodule

/* The register renamer provides physical registers with aliases so that they
   can be properly used out of order. */

module
register_renamer(
	input clk,
	input rst,
	input [3:0] nr_wb,
	input [3:0] nr_a,
	input [3:0] nr_b,
	output [4:0] tag_wb,
	output [5:0] tag_a,
	output [5:0] tag_b,
	output [1:0] st2
);

reg [3:0] nrs [0:31];
reg [31:0] using;
wire [31:0] use_next;
wire [31:0] found_a;
reg [4:0] _tag_a;
wire [31:0] found_b;
reg [4:0] _tag_b;

integer j;

generate
genvar i;
/* Check whether nr_a and nr_b are renamed. */
for (i = 0; i < 32; i = i + 1) begin : check_for_nrs
	assign found_a[i] = (nr_a == nrs[i]) && using[i];
	assign found_b[i] = (nr_b == nrs[i]) && using[i];
end
/* I really don't like this loop. */
always @* begin
	_tag_a = 0;
	_tag_b = 0;
	for (j = 0; j < 32; j = j + 1) begin
		if (found_a[j])
			_tag_a = j;
		if (found_b[j])
			_tag_b = j;
	end
end
/* Assign a new name to the writeback register. */
for (i = 0; i < 32; i = i + 1) begin : select_new_name
	always @(posedge clk) begin
		if (rst)
			using[i] <= 0;
		else
			using[i] <= use_next[i];
		if (use_next[i] && !using[i])
			nrs[i] <= nr_wb;
	end
end
for (i = 0; i < 31; i = i + 1) begin : propagate
	assign use_next[i + 1] = using[i] & use_next[i];
end
endgenerate

assign use_next[0] = 1'b1;

assign tag_a[4:0] = _tag_a;
assign tag_a[5] = |(found_a);
assign tag_b[4:0] = _tag_b;
assign tag_b[5] = |(found_b);

assign st2 = using[1:0];

endmodule

/* All fetched instructions are placed on the pending queue. When an
   instruction is removed from the pending queue, it is assigned a renamed
   writeback register and an entry is made in the writeback ledger. It is also
   decoded and passes through the dispatch buffer which is responsible for
   buffering each execution unit. */
/*
module
main(
	input clk,
	input rst
);

pending_queue
_pending_queue(
	.clk (clk),
	.rst (rst),
	.push (),
	.next (),
	.clear (),
	.empty (),
	.full (),
	.in_insn (),
	.out_insn ()
);

endmodule
*/
module
cpu3(
	input notclk,
	input notrst,
	input [7:0] in,
	output [7:0] out
);

wire clk = ~notclk;
wire rst = ~notrst;

register_renamer
_register_renamer(
	.clk (clk),
	.rst (rst),
	.nr_wb (in[7:4]),
	.nr_a (in[3:0]),
	.tag_a (out[5:0]),
	.st2 (out[7:6])
);

endmodule
