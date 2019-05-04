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
   can be properly used out of order. Note that occasionally it is undesirable
   to always generate new names, so rename explicitly indicates whether an
   instruction writes back. */

module
register_renamer(
	input clk,
	input rst,
	input rename,
	input [3:0] nr_wb,
	input [3:0] nr_a,
	input [3:0] nr_b,
	input [4:0] tag_clear,
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
wire [31:0] found_wb;
reg [4:0] _tag_wb;

integer j;

generate
genvar i;
/* Check whether nr_a and nr_b are renamed. */
for (i = 0; i < 32; i = i + 1) begin : check_for_nrs
	assign found_wb[i] = (nr_wb == nrs[i]) && using[i];
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
		if (use_next[j] && !using[j] && !found_wb[i])
			/* Return only the most recent writeback name. */
			_tag_wb = j;
	end
end
/* Assign a new name to the writeback register. */
for (i = 0; i < 32; i = i + 1) begin : select_new_name
	always @(posedge clk) begin
		if (rst)
			using[i] <= 0;
		else if (tag_clear == i)
			/* Mark this name as unused when the values are committed. */
			using[i] <= 0;
		else
			using[i] <= use_next[i];
		if (use_next[i] && !using[i])
			nrs[i] <= nr_wb;
	end
end
for (i = 0; i < 31; i = i + 1) begin : propagate
	assign use_next[i + 1] = using[i] & use_next[i] & rename;
end
endgenerate

assign use_next[0] = 1'b1;

assign tag_a[4:0] = _tag_a;
assign tag_a[5] = |(found_a);
assign tag_b[4:0] = _tag_b;
assign tag_b[5] = |(found_b);
assign tag_wb = _tag_wb;

assign st2 = using[1:0];

endmodule

/* The commit queue makes sure instructions are committed in order. */

module
commit_queue(
	input clk,
	input rst,
	input push,
	input next,
	input clear,
	output empty,
	output full,
	input [4:0] tag_wb,
	input [31:0] wb_val,
	input [35:0] in_entry,
	output [35:0] out_entry,
	output [31:0] out_value
);

wire stop0;
wire stop1;

reg [67:0] out_buf;
reg [35:0] entries [0:31];
reg [31:0] commit_vals [0:31];
reg [3:0] commit_head = 0;
reg [3:0] commit_tail = 0;

/* When clear is set, it enables both stops so nothing advanced and sets
   head to tail. */

assign stop0 = (commit_head == commit_tail) | clear;
assign stop1 = (commit_head + 1 == commit_tail) | clear;
assign empty = stop0;
assign full = stop1;
assign out_entry = entry;

always @(posedge clk) begin
	if (rst) begin
		out_buf <= 0;
		commit_tail <= 0;
	end
	else if (next && !stop0) begin
		out_buf[67:32] <= entries[commit_tail];
		out_buf[31:0] <= commit_vals[commit_tail];
		commit_tail <= commit_tail + 1;
	end
	if (rst) begin
		commit_head <= 0;
	end
	else if (push && !stop1) begin
		entries[commit_head] <= in_entry;
		commit_head <= commit_head + 1;
	end
	if (clear) begin
		commit_head <= commit_tail;
	end
end

generate
genvar i;
for (i = 0; i < 32; i = i + 1) begin
	if (entries[i][35:32] == tag_wb) begin
		commit_vals <= wb_val;
	end
end
endgenerate

assign out_entry = out_buf[67:32];
assign out_value = out_buf[31:0];

endmodule

/* All fetched instructions are placed on the pending queue. When an
   instruction is removed from the pending queue, it is assigned a renamed
   writeback register and an entry is made in the writeback ledger. It is also
   decoded and passes through the dispatch buffer which is responsible for
   buffering each execution unit. */

module
main(
	input clk,
	input rst
);

/* Push a new instruction onto the pending queue. */

wire push_new_insn;

/* Indicate when to retrieve the next instruction from the pending queue. */

wire get_next_insn;

/* Next instruction in the pending queue. */

wire [31:0] insn;
wire [3:0] nr_wb;
wire [3:0] nr_a;
wire [3:0] nr_b;

/* Explicitly request renaming. */

wire rename;

/* Newest writeback tag generated by the renamer. */

wire [4:0] new_tag_wb;

/* New entry to the commit queue. */

wire [35:0] commit_queue_new_entry;

/* value and tag for writeback from execution units. */

wire [4:0] writeback_tag;
wire [31:0] writeback_value;

/* Next entry in the commit queue to retire. */

wire [35:0] commit_queue_retire;
wire [31:0] retire_value;

pending_queue
_pending_queue(
	.clk (clk),
	.rst (rst),
	.push (push_new_insn),
	.next (get_next_insn),
	.clear (),
	.empty (),
	.full (),
	.in_insn (),
	.out_insn (insn)
);

assign nr_wb = insn[19:16];
assign nr_a = insn[11:8];
assign nr_b = insn[3:0];

assign rename = get_next_insn && !(
	insn[31:24] == 8'h01 || insn[31:24] == 8'h03 || insn[31:24] == 8'h0f ||
	insn[31:24] == 8'h10 || insn[31:24] == 8'h12 || insn[31:24] == 8'h14 ||
	insn[31:24] == 8'h16 || insn[31:24] == 8'h18 || insn[31:24] == 8'h1a ||
	insn[31:24] == 8'h1c || insn[31:24] == 8'h1e || insn[31:24] == 8'h20);

register_renamer
_register_renamer(
	.clk (clk),
	.rst (rst),
	.rename (rename)
	.nr_wb (nr_wb),
	.nr_a (nr_a),
	.nr_b (nr_b),
	.tag_clear (commit_queue_retire[35:32]),
	.tag_wb (new_tag_wb),
	.tag_a (),
	.tag_b ()
);

assign commit_queue_new_entry[35:32] = new_tag_wb;
assign commit_queue_new_entry[31:0] = insn;

commit_queue
_commit_queue(
	.clk (clk),
	.rst (rst),
	.push (get_next_insn),
	.next (),
	.clear (),
	.empty (),
	.full (),
	.tag_wb (writeback_tag),
	.wb_val (writeback_value),
	.in_entry (commit_queue_new_entry),
	.out_entry (commit_queue_retire),
	.out_value (retire_value)
);

endmodule

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
