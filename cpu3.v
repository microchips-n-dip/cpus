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
		if (use_next[j] && !using[j] && !found_wb[j])
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
reg [4:0] commit_head = 0;
reg [4:0] commit_tail = 0;

/* When clear is set, it enables both stops so nothing advanced and sets
   head to tail. */

assign stop0 = (commit_head == commit_tail) | clear;
assign stop1 = (commit_head + 1 == commit_tail) | clear;
assign empty = stop0;
assign full = stop1;

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
for (i = 0; i < 32; i = i + 1) begin : save_commits_by_tag
	always @(posedge clk) begin
		if (entries[i][35:32] == tag_wb)
			commit_vals[i] <= wb_val;
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
	input rst,
	input [31:0] in_mem,
	output [31:0] out_addr,
	output [31:0] out_mem
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

/* Operand tags found by the renamer. */

wire [5:0] new_tag_a;
wire [5:0] new_tag_b;

/* New entry to the commit queue. */

wire [35:0] commit_queue_new_entry;

/* value and tag for writeback from execution units. */

wire [4:0] writeback_tag;
wire [31:0] writeback_value;

/* Next entry in the commit queue to retire. */

wire retire_next_commit;
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
	.in_insn (in_mem),
	.out_insn (insn)
);

assign nr_wb = insn[19:16];
assign nr_a = insn[11:8];
assign nr_b = insn[3:0];

/* Determine which execution unit an instruction should use. */

/* Execution unit enumeration. */

parameter EU_NONE	= 4'h00;
parameter EU_MEM	= 4'h01;
parameter EU_ALU	= 4'h02;
parameter EU_MULDIV	= 4'h04;
parameter EU_BRANCH	= 4'h08;

/* Instruction class enumeration. */

parameter C_NONE	= 3'h00;
parameter C_DAB		= 3'h01;
parameter C_DXB		= 3'h02;
parameter C_DXX		= 3'h03;
parameter C_XAB		= 3'h04;
parameter C_XAX		= 3'h05;
parameter C_DIMM16	= 3'h06;
parameter C_IMM24	= 3'h07;

/* Instructions:
   ----- MEMORY INSTRUCTIONS -----
   0x00		- LOAD	- EU_MEM
   0x01		- STORE	- EU_MEM
   0x02		- LDI	- EU_ALU
   0x03		- PUSH	- EU_MEM
   0x04		- POP	- EU_MEM
   0x05		- MOV	- EU_ALU
   ----- ARITHMETIC INSTRUCTIONS -----
   0x06		- ADD	- EU_ALU
   0x07		- SUB	- EU_ALU
   0x08		- MUL	- EU_MULDIV
   0x09		- DIV	- EU_MULDIV
   ----- LOGIC INSTRUCTIONS -----
   0x0a		- AND	- EU_ALU
   0x0b		- OR	- EU_ALU
   0x0c		- NOR	- EU_ALU
   0x0d		- NOT	- EU_ALU
   0x0e		- XOR	- EU_ALU
   */

/* LDI and MOV use special ALU circuitry. LDI already contains the immediate to
   be loaded so it may be extended and written back simply. MOV must simply
   take the value of its source register and write it back to its destination
   register. */

/* Also important, DIMM16 and DXB type instructions must be handled specially
   so that they do not end up waiting for unnecessary registers. */

reg [3:0] execution_unit;
reg [2:0] xclass;

always @* begin
	case (insn[31:24])
		8'h00: begin
			execution_unit <= EU_MEM;
			xclass <= C_DXB;
		end
		8'h01: begin
			execution_unit <= EU_MEM;
			xclass <= C_XAB;
		end
		8'h02: begin
			execution_unit <= EU_ALU;
			xclass <= C_DIMM16;
		end
		8'h03: begin
			execution_unit <= EU_MEM;
			xclass <= C_XAX;
		end
		8'h04: begin
			execution_unit <= EU_MEM;
			xclass <= C_DXX;
		end
		8'h05: begin
			execution_unit <= EU_ALU;
			xclass <= C_DXB;
		end
		8'h06, 8'h07, 8'h0a, 8'h0b,
		8'h0c, 8'h0e: begin
			execution_unit <= EU_ALU;
			xclass <= C_DAB;
		end
		8'h0d: begin
			execution_unit <= EU_ALU;
			xclass <= C_DXB;
		end
		8'h08, 8'h09: begin
			execution_unit <= EU_MULDIV;
			xclass <= C_DAB;
		end
		8'h0f: begin
			execution_unit <= EU_BRANCH;
			xclass <= C_XAB;
		end
		8'h10, 8'h12, 8'h14, 8'h16,
		8'h18, 8'h1a, 8'h1c, 8'h1e,
		8'h20: begin
			execution_unit <= EU_BRANCH;
			xclass <= C_XAX;
		end
		8'h11, 8'h13, 8'h15, 8'h17,
		8'h19, 8'h1b, 8'h1d, 8'h1f,
		8'h21: begin
			execution_unit <= EU_BRANCH;
			xclass <= C_IMM24;
		end
		default: begin
			execution_unit <= EU_NONE;
			xclass <= C_NONE;
		end
	endcase
end

register_renamer
_register_renamer(
	.clk (clk),
	.rst (rst),
	.rename (rename),
	.nr_wb (nr_wb),
	.nr_a (nr_a),
	.nr_b (nr_b),
	.tag_clear (commit_queue_retire[35:32]),
	.tag_wb (new_tag_wb),
	.tag_a (new_tag_a),
	.tag_b (new_tag_b)
);

assign commit_queue_new_entry[35:32] = new_tag_wb;
assign commit_queue_new_entry[31:0] = insn;

commit_queue
_commit_queue(
	.clk (clk),
	.rst (rst),
	.push (get_next_insn),
	.next (retire_next_commit),
	.clear (),
	.empty (),
	.full (),
	.tag_wb (writeback_tag),
	.wb_val (writeback_value),
	.in_entry (commit_queue_new_entry),
	.out_entry (commit_queue_retire),
	.out_value (retire_value)
);

/* Architectural registers. */

reg [31:0] archregs [0:15];

/* Decoded tag and value fields. */

/* Can we all just agree that the way conbinational @* blocks are implemented
   confuses everybody? */

reg [5:0] decoded_tag_wb;
reg [5:0] decoded_tag_a;
reg [5:0] decoded_tag_b;
reg [31:0] decoded_value_a;
reg [31:0] decoded_value_b;

/* Handle weird xclass stuff. */

always @* begin
	case (xclass)
		C_DAB: begin
			decoded_tag_wb <= {1'b1, new_tag_wb};
			decoded_tag_a <= new_tag_a;
			decoded_tag_b <= new_tag_b;
			decoded_value_a <= new_tag_a[5] ? 0 : archregs[nr_a];
			decoded_value_b <= new_tag_b[5] ? 0 : archregs[nr_b];
		end
		C_DXB: begin
			decoded_tag_wb <= {1'b1, new_tag_wb};
			decoded_tag_a <= 0;
			decoded_tag_b <= new_tag_b;
			decoded_value_a <= 0;
			decoded_value_b <= new_tag_b[5] ? 0 : archregs[nr_b];
		end
		C_DXX: begin
			decoded_tag_wb <= {1'b1, new_tag_wb};
			decoded_tag_a <= 0;
			decoded_tag_b <= 0;
			decoded_value_a <= 0;
			decoded_value_b <= 0;
		end
		C_XAB: begin
			decoded_tag_wb <= 0;
			decoded_tag_a <= new_tag_a;
			decoded_tag_b <= new_tag_b;
			decoded_value_a <= new_tag_a[5] ? 0 : archregs[nr_a];
			decoded_value_b <= new_tag_b[5] ? 0 : archregs[nr_b];
		end
		C_XAX: begin
			decoded_tag_wb <= 0;
			decoded_tag_a <= new_tag_a;
			decoded_tag_b <= 0;
			decoded_value_a <= new_tag_a[5] ? 0 : archregs[nr_a];
			decoded_value_b <= 0;
		end
		C_DIMM16: begin
			decoded_tag_wb <= {1'b1, new_tag_wb};
			decoded_tag_a <= 0;
			decoded_tag_b <= 0;
			decoded_value_a <= 0;
			decoded_value_b <= insn[15:0];
		end
		C_IMM24: begin
			decoded_tag_wb <= 0;
			decoded_tag_a <= 0;
			decoded_tag_b <= 0;
			decoded_value_a <= 0;
			decoded_value_b <= insn[23:0];
		end
		default: begin
			decoded_tag_wb <= 0;
			decoded_tag_a <= 0;
			decoded_tag_b <= 0;
			decoded_value_a <= 0;
			decoded_value_b <= 0;
		end
	endcase
end

/* Buffer between predecode and execution stage. */

/*reg [] dispatch_buffer;

always @(posedge clk) begin
	if (rst)
		dispatch_buffer <= 0;
	else begin
		dispatch_buffer[] <= new_tag_wb;
		dispatch_buffer[] <= new_tag_a;
		dispatch_buffer[] <= new_tag_b;
		dispatch_buffer[] <= insn;
	end
end*/



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

reg [31:0] mem [0:1023];

/* If I did all 32 bits, I'd need 4294967296 addresses... */
/* TODO: Use multibyte loading. */

wire [31:0] addr;
wire [31:0] towrite;

main
_main(
	.clk (clk),
	.rst (rst),
	.in_mem (mem[addr]),
	.out_addr (addr),
	.out_mem (towrite)
);

/*always @(posedge clk) begin
	if (rst) begin
	
	end
	else if () begin
		mem[addr] <= towrite;
	end
end*/

endmodule
