/* pending_queue takes care of queueing up instructions. */

module
pending_queue(
	input			clk,
	input 			rst,
	input 			push,
	input 			next,
	input 			clear,
	output 			empty,
	output			full,
	input	[31:0]	in_insn,
	output	[31:0]	out_insn
);

wire 			stop0;
wire 			stop1;

reg		[31:0]	pending [0:7];
reg		[3:0]	pending_head = 0;
reg		[3:0]	pending_tail = 0;

/* When clear is set, it enables both stops so nothing advanced and sets
   head to tail. */

assign stop0 = (pending_head == pending_tail) | clear;
assign stop1 = (pending_head + 1 == pending_tail) | clear;
assign empty = stop0;
assign full = stop1;

always @(posedge clk) begin
	if (rst)
		pending_tail <= 0;
	else if (next && !stop0)
		pending_tail <= pending_tail + 1;
	if (rst) begin
		pending_head <= 0;
		pending[0] <= 31'h02000000;
	end
	else if (push && !stop1) begin
		pending[pending_head] <= in_insn;
		pending_head <= pending_head + 1;
	end
	if (clear)
		pending_head <= pending_tail;
end

assign out_insn = pending[pending_tail];

endmodule

/* The register renamer provides physical registers with aliases so that they
   can be properly used out of order. Note that occasionally it is undesirable
   to always generate new names, so rename explicitly indicates whether an
   instruction writes back. */

/* New tag and rename system. */

module
register_renamer(
	input			clk,
	input			rst,
	input			rename, /* Should rename all instructions. */
	input	[3:0]	nr_wb,
	input	[3:0]	nr_a,
	input	[3:0]	nr_b,
	output	[15:0]	tag_wb,
	output	[15:0]	tag_a,
	output			tag_a_active,
	output	[15:0]	tag_b,
	output			tag_b_active,
	input			clear_en,
	input	[3:0]	nr_clear
);

reg		[15:0]	counter;
reg		[15:0]	tag_map	[0:15];
reg		[15:0]	active; /* A register has an active tag. */

/* Allocate tags. */

always @(posedge clk) begin
	if (rst) begin
		active <= 0;
		counter <= 0;
	end
	else if (rename) begin
		active[nr_wb] <= 1;
		tag_map[nr_wb] <= counter;
		counter <= counter + 1;
	end
	else if (clear_en)
		active[nr_clear] <= 0;
end

assign tag_wb = counter;
assign tag_a = tag_map[nr_a];
assign tag_a_active = active[nr_a];
assign tag_b = tag_map[nr_b];
assign tag_b_active = active[nr_b];

endmodule

/* Detect proper ordering of tags. Because the ROB only has 32 entries and tags
   are 15-bit numbers with a 16th rename phase parity bit, all that is necessary
   to verify that tag_a <= tag_b is that tag_a's value is greater than that of
   tag_b, and the parity bits aren't the same. The significantly smaller number
   of ROB entries ensures no value collisions. */

module
tag_ordering(
	input	[15:0]	tag_a,
	input	[15:0]	tag_b,
	output			ordered
);

wire parity_a;
wire parity_b;

assign parity_a = tag_a[15];
assign parity_b = tag_b[15];
assign ordered =
	(!(parity_a ^ parity_b) && (tag_a[14:0] <= tag_b[14:0])) ||
	((parity_a ^ parity_b) && (tag_b[14:0] <= tag_a[14:0]));

endmodule

/* Logic for determining the existence and location of a tag in the commit
   queue. */

module
commit_queue_location(
	input		[4:0]	head,
	input		[4:0]	tail,
	input		[15:0]	base_tag,
	input		[15:0]	operand_tag,
	output reg	[4:0]	location,
	output reg			exists
);

wire			pt = base_tag[15];
wire	[14:0]	vt = base_tag[14:0];
wire			po = operand_tag[15];
wire	[14:0]	vo = operand_tag[14:0];

reg		[14:0]	offsetof;

always @* begin
	/* Normal case, no rollover. */
	if (!(pt ^ po))
		offsetof <= vo - vt;
	/* Rollover occured, diff = 0xffff - vt + vo. */
	else
		offsetof <= vo + (15'h7fff - vt);
	location <= tail + offsetof[4:0];
	exists <= location < head;
end

endmodule

/* The commit queue makes sure instructions are committed in order. We
   provisionally assume that all instructions fetched must also be preordered
   because even if they have no writeback value, it is possible that the
   instruction itself has an effect during retirement. */

module
commit_queue(
	input			clk,
	input			rst,
	input			push,
	input			next,
	input			clear,
	output			empty,
	output			full,
	input			committing,
	input	[15:0]	new_tag_wb,
	input	[31:0]	new_insn,
	input	[15:0]	operand_tag_a,
	output	[31:0]	operand_a,
	output			operand_a_ready,
	input	[15:0]	operand_tag_b,
	output	[31:0]	operand_b,
	output			operand_b_ready,
	input	[15:0]	common_writeback_tag,
	input	[31:0]	common_writeback_value,
	output	[15:0]	retire_tag,
	output	[31:0]	retire_insn,
	output	[31:0]	retire_value,
	output			tag_clear_en
);

wire			stop0;
wire			stop1;

reg		[31:0]	waiting;
reg		[15:0]	tags		[0:31];
reg		[31:0]	entries		[0:31];
reg		[31:0]	commit_vals [0:31];
reg		[4:0]	commit_head = 0;
reg		[4:0]	commit_tail = 0;

wire	[15:0]	oldest_tag;
/* Absolute locations of tags in the queue. This is a cyclic queue after all. */
wire	[4:0]	absolute_wb;
wire			exists_a;
wire	[4:0]	absolute_a;
wire			exists_b;
wire	[4:0]	absolute_b;

/* When clear is set, it enables both stops so nothing advanced and sets
   head to tail. */

assign stop0 = (commit_head == commit_tail) | clear;
assign stop1 = (commit_head + 1 == commit_tail) | clear;
assign empty = stop0;
assign full = stop1;

always @(posedge clk) begin
	if (rst)
		commit_tail <= 0;
	else if (!waiting[commit_tail] && next && !stop0)
		commit_tail <= commit_tail + 1;
	if (rst)
		commit_head <= 0;
	else if (push && !stop1) begin
		tags[commit_head] <= new_tag_wb;
		entries[commit_head] <= new_insn;
		commit_head <= commit_head + 1;
	end
	if (clear)
		commit_head <= commit_tail;
end

/* Compute the offsets of tags withing the queue. */
assign oldest_tag = tags[commit_tail];

commit_queue_location
_find_wb(
	.head (commit_head),
	.tail (commit_tail),
	.base_tag (oldest_tag),
	.operand_tag (common_writeback_tag),
	.location (absolute_wb),
	/* Should always exist, otherwise something is seriously wrong. */
	.exists ()
);

commit_queue_location
_find_a(
	.head (commit_head),
	.tail (commit_tail),
	.base_tag (oldest_tag),
	.operand_tag (operand_tag_a),
	.location (absolute_a),
	.exists (exists_a)
);

commit_queue_location
_find_b(
	.head (commit_head),
	.tail (commit_tail),
	.base_tag (oldest_tag),
	.operand_tag (operand_tag_b),
	.location (absolute_b),
	.exists (exists_b)
);

generate
genvar i;
for (i = 0; i < 32; i = i + 1) begin : update_waiting_status
	always @(posedge clk) begin
		/* Prepare waiting signal based on writeback tag use status. If a tag
		   is not in use, then there's no need to wait for it. */
		/* Actually I think I still need to wait for it. */
		if ((i == commit_head) && push && !stop1)
			waiting[i] <= 1;
		/* Store values by tag. */
		else if (committing && (absolute_wb == i)) begin
			commit_vals[i] <= common_writeback_value;
			waiting[i] <= 0;
		end
	end
end
endgenerate

/* Output any operands. We'll have to manage proper detection of any operands
   though, so that the RSes know whether they need to wait. */
assign operand_a = commit_vals[absolute_a];
assign operand_a_ready = exists_a && !waiting[absolute_a];
assign operand_b = commit_vals[absolute_b];
assign operand_b_ready = exists_b && !waiting[absolute_b];

assign retire_tag = tags[commit_tail];
assign retire_insn = entries[commit_tail];
assign retire_value = commit_vals[commit_tail];
/* In effect, signal to do the retirement. */
assign tag_clear_en = !waiting[commit_tail] && !stop0;

endmodule

/* Reservation station with three entries. */

module
reservation_station(
	input			clk,
	input			rst,
	input			new_incoming,
	input	[15:0]	new_wb_tag,
	input	[31:0]	new_insn,
	input			waitfor_a,
	input	[15:0]	new_tag_a,
	input 	[31:0]	new_value_a,
	input			waitfor_b,
	input	[15:0]	new_tag_b,
	input	[31:0]	new_value_b,
	output	[15:0]	next_wb_tag,
	output	[31:0]	next_insn,
	output	[31:0]	next_value_a,
	output	[31:0]	next_value_b,
	input	[15:0]	common_writeback_tag,
	input	[31:0]	common_writeback_value,
	output			running,
	output			none_free
);

reg		[2:0]	using;
wire	[3:0]	use_next;
reg 	[15:0]	wb_tags		[0:2];
reg		[31:0]	insns		[0:2];
reg		[2:0]	waiting_0;
reg 	[15:0]	qi_tags		[0:2];
reg 	[31:0]	vi_values	[0:2];
reg		[2:0]	waiting_1;
reg 	[15:0]	qj_tags		[0:2];
reg 	[31:0]	vj_values	[0:2];
wire	[2:0]	ready;
wire	[2:0]	run;

/* Special wires for tag order checking. */

wire tso01, tso02;
wire tso10, tso12;
wire tso20, tso21;

genvar i;

generate
for (i = 0; i < 3; i = i + 1) begin : set_operand_values
	assign use_next[i + 1] = using[i] && use_next[i];
	always @(posedge clk) begin
		if (rst)
			using[i] <= 0;
		else if (use_next[i] && new_incoming)
			using[i] <= use_next[i];
		if (use_next[i] && !using[i]) begin
			wb_tags[i] <= new_wb_tag;
			insns[i] <= new_insn;
			waiting_0[i] <= waitfor_a;
			vi_values[i] <= new_value_a;
			waiting_1[i] <= waitfor_b;
			vj_values[i] <= new_value_b;
			qi_tags[i] <= new_tag_a;
			qj_tags[i] <= new_tag_b;
		end
		else if (run[i])
			using[i] <= 0;
		else if (using[i]) begin
			if ((common_writeback_tag == qi_tags[i]) && waiting_0[i]) begin
				vi_values[i] <= common_writeback_value;
				waiting_0[i] <= 0;
			end
			if ((common_writeback_tag == qj_tags[i]) && waiting_1[i]) begin
				vj_values[i] <= common_writeback_value;
				waiting_1[i] <= 0;
			end
		end
	end
	assign ready[i] = using[i] && !(waiting_0[i] || waiting_1[i]);
end
endgenerate

assign use_next[0] = 1'b1;
assign none_free = use_next[3];

/* Tag order checks. (Annoyingly many order checks too). */

tag_ordering _tso01(wb_tags[0], wb_tags[1], tso01);
tag_ordering _tso02(wb_tags[0], wb_tags[2], tso02);
tag_ordering _tso10(wb_tags[1], wb_tags[0], tso10);
tag_ordering _tso12(wb_tags[1], wb_tags[2], tso12);
tag_ordering _tso20(wb_tags[2], wb_tags[0], tso20);
tag_ordering _tso21(wb_tags[2], wb_tags[1], tso21);

assign run[0] = ready[0] &&	((tso01 || !ready[1]) && (tso02 || !ready[2]));
assign run[1] = ready[1] && ((tso10 || !ready[0]) && (tso12 || !ready[2]));
assign run[2] = ready[2] && ((tso20 || !ready[0]) && (tso21 || !ready[1]));

assign running = |run;

assign next_wb_tag = run[0] ? wb_tags[0] :
					 run[1] ? wb_tags[1] :
					 run[2] ? wb_tags[2] : 0;
assign next_insn = run[0] ? insns[0] :
				   run[1] ? insns[1] :
				   run[2] ? insns[2] : 0;
assign next_value_a = run[0] ? vi_values[0] :
					  run[1] ? vi_values[1] :
					  run[2] ? vi_values[2] : 0;
assign next_value_b = run[0] ? vj_values[0] :
					  run[1] ? vj_values[1] :
					  run[2] ? vj_values[2] : 0;

wire [31:0] bprobe = vj_values[0];

endmodule

/* Queue for memory accesses. */

module
memory_access_controller(
	input				clk,
	input				rst,
	input		[31:0]	program_counter,
	input				eu_request,
	input		[15:0]	eu_tag,
	input		[31:0]	eu_insn,
	input		[31:0]	eu_operand,
	input		[31:0]	eu_addr,
	input				request_served,
	output reg			push_insn,
	output reg			eu_complete,
	output		[15:0]	writeback_tag,
	output reg	[31:0]	mem_addr,
	output reg	[31:0]	mem_data,
	output reg			write_please
);

/* Switch controlling whether to serve fetch stage or execution unit. */

reg				control_switch;

/* Execution unit request queue. */

reg		[1:0]	head;
reg		[1:0]	tail;

reg		[15:0]	tags		[0:3];
reg		[31:0]	insns		[0:3];
reg		[31:0]	operand_0	[0:3];
reg		[31:0]	operand_1	[0:3];

wire	[15:0]	next_tag;
wire	[31:0]	next_insn;
wire	[31:0]	next_operand;
wire	[31:0]	next_addr;

wire			empty;
wire			full;

assign empty = tail == head;
assign full = tail == head + 1;

always @(posedge clk) begin
	if (rst)
		head <= 0;
	else if (!full && eu_request) begin
		tags[head] <= eu_tag;
		insns[head] <= eu_insn;
		operand_0[head] <= eu_operand;
		operand_1[head] <= eu_addr;
		head <= head + 1;
	end
	if (rst)
		tail <= 0;
	else if (!empty && eu_complete)
		tail <= tail + 1;
end

assign writeback_tag = tags[tail];
assign next_insn = insns[tail];
assign next_operand = operand_0[tail];
assign next_addr = operand_1[tail];

always @* begin
	/* Determine whether to push a new instruction. */
	if (!control_switch && request_served)
		push_insn <= 1;
	else
		push_insn <= 0;
	/* Determine completion of an eu request for wb signaling. */
	if (control_switch && request_served)
		eu_complete <= 1;
	else
		eu_complete <= 0;
	if (!control_switch) begin
		mem_addr <= program_counter;
		mem_data <= 0;
		write_please <= 0;
	end
	else if (!empty) begin
		mem_addr <= next_addr;
		mem_data <= next_operand;
		/* Select write status. */
		case (next_insn[31:24])
			8'h00: begin
				write_please <= 0;
			end
			8'h01: begin
				write_please <= 1;
			end
			default: begin
				write_please <= 0;
			end
		endcase
	end
	else begin
		mem_addr <= 0;
		mem_data <= 0;
		write_please <= 0;
	end
end

always @(posedge clk) begin
	if (rst)
		control_switch <= 0;
	/* The fetch stage has control and we want to transfer it to the eu. */
	else if (!empty && !control_switch)
		control_switch <= 1;
	/* The eu has control and the request has been serviced, transfer control
	   back to the fetch stage. */
	else if (control_switch && request_served)
		control_switch <= 0;
end

endmodule

/* A 4-way round-robin arbiter for handling writebacks. */

module
arbiter_4(
	input				clk,
	input				rst,
	input		[3:0]	request,
	output reg	[3:0]	passthrough
);

reg		[3:0]	phase;
reg		[2:0]	stop;

always @(posedge clk) begin
	if (rst)
		phase <= 4'h1;
	else begin
		phase[0] <= phase[3];
		phase[1] <= phase[0];
		phase[2] <= phase[1];
		phase[3] <= phase[2];
	end
end

always @* begin
	case (phase)
		4'h1: begin
			passthrough[0] <= request[0];
			stop[0] <= request[0];
			passthrough[1] <= request[1] && !stop[0];
			stop[1] <= request[1] || stop[0];
			passthrough[2] <= request[2] && !stop[1];
			stop[2] <= request[2] || stop[1];
			passthrough[3] <= request[3] && !stop[2];
		end
		4'h2: begin
			passthrough[1] <= request[1];
			stop[0] <= request[1];
			passthrough[2] <= request[2] && !stop[0];
			stop[1] <= request[2] || stop[0];
			passthrough[3] <= request[3] && !stop[1];
			stop[2] <= request[3] || stop[1];
			passthrough[0] <= request[0] && !stop[2];
		end
		4'h4: begin
			passthrough[2] <= request[2];
			stop[0] <= request[2];
			passthrough[3] <= request[3] && !stop[0];
			stop[1] <= request[3] || stop[0];
			passthrough[0] <= request[0] && !stop[1];
			stop[2] <= request[0] || stop[1];
			passthrough[1] <= request[1] && !stop[2];
		end
		4'h8: begin
			passthrough[3] <= request[3];
			stop[0] <= request[3];
			passthrough[0] <= request[0] && !stop[0];
			stop[1] <= request[0] || stop[0];
			passthrough[1] <= request[1] && !stop[1];
			stop[2] <= request[1] || stop[1];
			passthrough[2] <= request[2] && !stop[2];
		end
		default: begin
			passthrough <= 0;
			stop <= 0;
		end
	endcase
end

endmodule

/* All fetched instructions are placed on the pending queue. When an
   instruction is removed from the pending queue, it is assigned a renamed
   writeback register and an entry is made in the writeback ledger. It is also
   decoded and passes through the dispatch buffer which is responsible for
   buffering each execution unit. */

module
main(
	input			clk,
	input			rst,
	input	[31:0]	in_mem,
	output	[31:0]	out_addr,
	output	[31:0]	out_mem,
	input			request_served,
	output			write_please,
	output	[7:0]	st8
);

/* Program counter logic. */

reg [31:0] program_counter;

/* Push a new instruction onto the pending queue. */

wire push_new_insn;

always @(posedge clk) begin
	if (rst)
		program_counter <= 0;
	else if (push_new_insn)
		program_counter <= program_counter + 1;
end

/* Fetch and decode stages will stall if there are no RSes free to receive a new
   instruction. */

wire [3:0] none_free;

/* Indicate when to retrieve the next instruction from the pending queue. */

wire none_pending;
wire get_next_insn;

/* Next instruction in the pending queue. */

wire [31:0] insn;
wire [3:0] nr_wb;
wire [3:0] nr_a;
wire [3:0] nr_b;

/* Explicitly request renaming. */

wire rename;

/* Newest writeback tag generated by the renamer. */

wire [15:0] new_tag_wb;

/* Operand tags found by the renamer. */

wire [15:0] new_tag_a;
wire [15:0] new_tag_b;

/* value and tag for writeback from execution units. */

reg committing;
reg [15:0] writeback_tag;
reg [31:0] writeback_value;

/* Next entry in the commit queue to retire. */

wire retire_next_commit;
wire [15:0] retire_tag;
wire [31:0] retire_insn;
wire [31:0] retire_value;

pending_queue
_pending_queue(
	.clk (clk),
	.rst (rst),
	.push (push_new_insn),
	.next (get_next_insn),
	.clear (1'b0),
	.empty (none_pending),
	.full (),
	.in_insn (in_mem),
	.out_insn (insn)
);

assign nr_wb = insn[19:16];
assign nr_a = insn[11:8];
assign nr_b = insn[3:0];

/* Determine which execution unit an instruction should use. */

/* Execution unit enumeration. */

parameter EU_NONE	= 4'h0;
parameter EU_MEM	= 4'h1;
parameter EU_ALU	= 4'h2;
parameter EU_MULDIV	= 4'h4;
parameter EU_BRANCH	= 4'h8;

/* Instruction class enumeration. */

parameter C_NONE	= 3'h0;
parameter C_DAB		= 3'h1;
parameter C_DXB		= 3'h2;
parameter C_DXX		= 3'h3;
parameter C_XAB		= 3'h4;
parameter C_XAX		= 3'h5;
parameter C_DIMM16	= 3'h6;
parameter C_IMM24	= 3'h7;

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

assign rename = get_next_insn; /* &&
				((xclass == C_DAB) || (xclass == C_DXB) ||
				 (xclass == C_DXX) || (xclass == C_DIMM16));*/

wire tag_a_active;
wire tag_b_active;

register_renamer
_register_renamer(
	.clk (clk),
	.rst (rst),
	.rename (rename),
	.nr_wb (nr_wb),
	.nr_a (nr_a),
	.nr_b (nr_b),
	.tag_wb (new_tag_wb),
	.tag_a (new_tag_a),
	.tag_a_active (tag_a_active),
	.tag_b (new_tag_b),
	.tag_b_active (tag_b_active),
	.clear_en (retire_next_commit),
	.nr_clear (retire_insn[19:16])
);

/* Architectural registers. */

reg [31:0] archregs [0:15];

wire [31:0] rob_operand_a;
wire rob_a_ready;
wire [31:0] rob_operand_b;
wire rob_b_ready;

commit_queue
_commit_queue(
	.clk (clk),
	.rst (rst),
	.push (get_next_insn),
	.next (1'b1),
	.clear (1'b0),
	.empty (),
	.full (),
	.committing (committing),
	.new_tag_wb (new_tag_wb),
	.new_insn (insn),
	.operand_tag_a (new_tag_a),
	.operand_a (rob_operand_a),
	.operand_a_ready (rob_a_ready),
	.operand_tag_b (new_tag_b),
	.operand_b (rob_operand_b),
	.operand_b_ready (rob_b_ready),
	.common_writeback_tag (writeback_tag),
	.common_writeback_value (writeback_value),
	.retire_tag (retire_tag),
	.retire_insn (retire_insn),
	.retire_value (retire_value),
	.tag_clear_en (retire_next_commit)
);

always @(posedge clk) begin
	if (retire_next_commit)
		archregs[retire_insn[19:16]] <= retire_value;
end

reg [31:0] operand_a;
reg operand_a_waiting;
reg [31:0] operand_b;
reg operand_b_waiting;

always @* begin
	if (!tag_a_active) begin
		operand_a <= archregs[nr_a];
		operand_a_waiting <= 0;
	end
	else if (new_tag_a == writeback_tag) begin
		operand_a <= writeback_value;
		operand_a_waiting <= 0;
	end
	else if (rob_a_ready) begin
		operand_a <= rob_operand_a;
		operand_a_waiting <= 0;
	end
	else begin
		operand_a <= 0;
		operand_a_waiting <= 1;
	end
	if (xclass == C_DIMM16) begin
		operand_b <= insn[15:0];
		operand_b_waiting <= 0;
	end
	else if (xclass == C_IMM24) begin
		operand_b <= insn[23:0];
		operand_b_waiting <= 0;
	end
	else if (!tag_b_active) begin
		operand_b <= archregs[nr_b];
		operand_b_waiting <= 0;
	end
	else if (new_tag_b == writeback_tag) begin
		operand_b <= writeback_value;
		operand_b_waiting <= 0;
	end
	else if (rob_b_ready) begin
		operand_b <= rob_operand_b;
		operand_b_waiting <= 0;
	end
	else begin
		operand_b <= 0;
		operand_b_waiting <= 1;
	end
end

/* Decoded tag and value fields. */

/* Can we all just agree that the way conbinational @* blocks are implemented
   confuses everybody? */

reg waitfor_a;
reg waitfor_b;

/* Handle weird xclass stuff. */

always @* begin
	case (xclass)
		C_DAB: begin
			waitfor_a <= operand_a_waiting;
			waitfor_b <= operand_b_waiting;
		end
		C_DXB: begin
			waitfor_a <= 0;
			waitfor_b <= operand_b_waiting;
		end
		C_DXX: begin
			waitfor_a <= 0;
			waitfor_b <= 0;
		end
		C_XAB: begin
			waitfor_a <= operand_a_waiting;
			waitfor_b <= operand_b_waiting;
		end
		C_XAX: begin
			waitfor_a <= operand_a_waiting;
			waitfor_b <= 0;
		end
		C_DIMM16: begin
			waitfor_a <= 0;
			waitfor_b <= 0;
		end
		C_IMM24: begin
			waitfor_a <= 0;
			waitfor_b <= 0;
		end
		default: begin
			waitfor_a <= 0;
			waitfor_b <= 0;
		end
	endcase
end

/* Managing reservation stations: Fairly simple mechanism, similar to renamer.
   If no stations are free, stall everything above by disabling get_next_insn
   and wait for some retires. */

/* EU_MEM. */

wire eu_mem_incoming = execution_unit == EU_MEM;
wire eu_mem_running;
wire [15:0] eu_mem_wb_tag;
wire [31:0] eu_mem_insn;
wire [31:0] eu_mem_addr;
wire [31:0] eu_mem_tostore;
wire [31:0] eu_mem_wb;

wire eu_mem_complete;
wire [15:0] eu_mem_complete_writeback_tag;

reservation_station
eu_mem_reservation_station(
	.clk (clk),
	.rst (rst),
	.new_incoming (eu_mem_incoming),
	.new_wb_tag (new_tag_wb),
	.new_insn (insn),
	.waitfor_a (waitfor_a),
	.new_tag_a (new_tag_a),
	.new_value_a (operand_a),
	.waitfor_b (waitfor_b),
	.new_tag_b (new_tag_b),
	.new_value_b (operand_b),
	.next_wb_tag (eu_mem_wb_tag),
	.next_insn (eu_mem_insn),
	.next_value_a (eu_mem_tostore),
	.next_value_b (eu_mem_addr),
	.common_writeback_tag (writeback_tag),
	.common_writeback_value (writeback_value),
	.running (eu_mem_running),
	.none_free (none_free[0])
);

memory_access_controller
_memory_access_controller(
	.clk (clk),
	.rst (rst),
	.program_counter (program_counter),
	.eu_request (eu_mem_running),
	.eu_tag (eu_mem_wb_tag),
	.eu_insn (eu_mem_insn),
	.eu_operand (eu_mem_tostore),
	.eu_addr (eu_mem_addr),
	.request_served (request_served),
	.push_insn (push_new_insn),
	.eu_complete (eu_mem_complete),
	.writeback_tag (eu_mem_complete_writeback_tag),
	.mem_addr (out_addr),
	.mem_data (out_mem),
	.write_please (write_please)
);

assign eu_mem_wb = in_mem;

/* EU_ALU. */

wire eu_alu_incoming = execution_unit == EU_ALU;
wire eu_alu_running;
wire [15:0] eu_alu_wb_tag;
wire [31:0] eu_alu_insn;
wire [31:0] eu_alu_a;
wire [31:0] eu_alu_b;
reg [31:0] eu_alu_wb;

reservation_station
eu_alu_reservation_station(
	.clk (clk),
	.rst (rst),
	.new_incoming (eu_alu_incoming),
	.new_wb_tag (new_tag_wb),
	.new_insn (insn),
	.waitfor_a (waitfor_a),
	.new_tag_a (new_tag_a),
	.new_value_a (operand_a),
	.waitfor_b (waitfor_b),
	.new_tag_b (new_tag_b),
	.new_value_b (operand_b),
	.next_wb_tag (eu_alu_wb_tag),
	.next_insn (eu_alu_insn),
	.next_value_a (eu_alu_a),
	.next_value_b (eu_alu_b),
	.common_writeback_tag (writeback_tag),
	.common_writeback_value (writeback_value),
	.running (eu_alu_running),
	.none_free (none_free[1])
);

always @* begin
	case (eu_alu_insn[31:24])
		8'h02, 8'h05: eu_alu_wb <= eu_alu_b;
		8'h06: eu_alu_wb <= eu_alu_a + eu_alu_b;
		8'h07: eu_alu_wb <= eu_alu_a - eu_alu_b;
		8'h0a: eu_alu_wb <= eu_alu_a & eu_alu_b;
		8'h0b: eu_alu_wb <= eu_alu_a | eu_alu_b;
		8'h0c: eu_alu_wb <= ~(eu_alu_a | eu_alu_b);
		8'h0d: eu_alu_wb <= ~eu_alu_b;
		8'h0e: eu_alu_wb <= eu_alu_a ^ eu_alu_b;
		default: eu_alu_wb <= 0;
	endcase
end

/* EU_MULDIV. */

wire [31:0] eu_muldiv_insn;
wire [31:0] eu_muldiv_a;
wire [31:0] eu_muldiv_b;
reg [63:0] eu_muldiv_wb;

always @* begin
	case (eu_muldiv_insn[31:24])
		8'h08: eu_muldiv_wb <= eu_muldiv_a * eu_muldiv_b;
		8'h09: eu_muldiv_wb <= eu_muldiv_a / eu_muldiv_b;
		default: eu_muldiv_wb <= 0;
	endcase
end

/* Temporary direct forwarding for tests. */

assign none_free[2] = 0;
assign none_free[3] = 0;
assign get_next_insn = !(|none_free) && !none_pending;
assign st8 = retire_value;

wire [3:0] wben;

arbiter_4
writeback_arbiter(
	.clk (clk),
	.rst (rst),
	.request ({1'b0, 1'b0, eu_alu_running, eu_mem_complete}),
	.passthrough (wben)
);

always @* begin
	case (wben)
		4'h1: begin
			writeback_tag <= eu_mem_complete_writeback_tag;
			committing <= eu_mem_complete;
			writeback_value <= eu_mem_wb;
		end
		4'h2: begin
			writeback_tag <= eu_alu_wb_tag;
			committing <= eu_alu_running;
			writeback_value <= eu_alu_wb;
		end
		default: begin
			writeback_tag <= 0;
			committing <= 0;
			writeback_value <= 0;
		end
	endcase
end

endmodule

module
cpu3(
	input notclk,
	input notrst,
	input [7:0] in,
	output [7:0] out
);

//wire clk = ~notclk;
//wire rst = ~notrst;
reg clk, rst;

reg [31:0] mem [0:31];

/* If I did all 32 bits, I'd need 4294967296 addresses... */
/* TODO: Use multibyte loading. */

wire [31:0] addr;
wire [31:0] memread;
wire [31:0] towrite;
wire write_please;

main
_main(
	.clk (clk),
	.rst (rst),
	.in_mem (memread),
	.out_addr (addr),
	.out_mem (towrite),
	.request_served (1'b1),
	.write_please (write_please),
	.st8 (out)
);

assign memread = mem[addr[5:0]];

always @(posedge clk) begin
	if (rst) begin
		/* LDI r2, 0x10
		   LOAD r4, r2
		   LDI r2, 0x11
		   LOAD r5, r2
		   ADD r6, r4, r5
		   */
		//mem[0] <= 31'h02020010;
		//mem[1] <= 31'h00040002;
		//mem[2] <= 31'h02020011;
		//mem[3] <= 31'h00050002;
		//mem[4] <= 31'h06060405;
		//mem[16] <= 31'h00000005;
		//mem[17] <= 31'h00000003;
	end
	else if (write_please) begin
		mem[addr[5:0]] <= towrite;
	end
end

initial begin
	$dumpfile ("dump.vcd");
	$dumpvars (0, _main);
	mem[0] <= 31'h02020010;
	mem[1] <= 31'h00040002;
	mem[2] <= 31'h02020011;
	mem[3] <= 31'h00050002;
	mem[4] <= 31'h06060405;
	mem[5] <= 31'h06060605;
	mem[6] <= 31'h06060604;
	mem[16] <= 31'h00000005;
	mem[17] <= 31'h00000003;
	rst = 1'b1;
	clk = 1'b0;
	#10 clk = 1'b1;
	#10 clk = 1'b0;
	rst = 1'b0;
	#10 clk = 1'b1;
	#10 clk = 1'b0;
	#10 clk = 1'b1;
	#10 clk = 1'b0;
	#10 clk = 1'b1;
	#10 clk = 1'b0;
	#10 clk = 1'b1;
	#10 clk = 1'b0;
	#10 clk = 1'b1;
	#10 clk = 1'b0;
	#10 clk = 1'b1;
	#10 clk = 1'b0;
	#10 clk = 1'b1;
	#10 clk = 1'b0;
	#10 clk = 1'b1;
	#10 clk = 1'b0;
	#10 clk = 1'b1;
	#10 clk = 1'b0;
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
