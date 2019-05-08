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

reg		[31:0]	insn;
reg		[31:0]	pending [0:7];
reg		[3:0]	pending_head = 0;
reg		[3:0]	pending_tail = 0;

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
	input			clk,
	input			rst,
	input			rename,
	input	[3:0]	nr_wb,
	input	[3:0]	nr_a,
	input	[3:0]	nr_b,
	input			clearing,
	input	[4:0]	tag_clear,
	output	[4:0]	tag_wb,
	output	[5:0]	tag_a,
	output	[5:0]	tag_b,
	output	[1:0]	st2
);

reg		[3:0]	nrs			[0:31];
reg		[31:0]	using;
wire	[31:0]	use_next;
wire	[31:0]	found_a;
reg		[4:0]	_tag_a;
wire	[31:0]	found_b;
reg		[4:0]	_tag_b;
wire	[31:0]	found_wb;
reg		[4:0]	_tag_wb;

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
	_tag_wb <= 0;
	_tag_a <= 0;
	_tag_b <= 0;
	for (j = 0; j < 32; j = j + 1) begin
		if (found_a[j])
			_tag_a <= j;
		if (found_b[j])
			_tag_b <= j;
		if (use_next[j] && !using[j] && !found_wb[j])
			/* Return only the most recent writeback name. */
			_tag_wb <= j;
	end
end
/* Assign a new name to the writeback register. */
for (i = 0; i < 32; i = i + 1) begin : select_new_name
	always @(posedge clk) begin
		if (rst)
			using[i] <= 0;
		else if (clearing && tag_clear == i)
			/* Mark this name as unused when the values are committed. */
			using[i] <= 0;
		else if (rename)
			using[i] <= use_next[i];
		if (use_next[i] && !using[i])
			nrs[i] <= nr_wb;
	end
end
for (i = 0; i < 31; i = i + 1) begin : propagate
	assign use_next[i + 1] = using[i] && use_next[i];
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
	input			clk,
	input			rst,
	input			push,
	input			next,
	input			clear,
	output			empty,
	output			full,
	input	[4:0]	tag_wb,
	input	[31:0]	wb_val,
	input	[36:0]	in_entry,
	output	[36:0]	out_entry,
	output	[31:0]	out_value
);

wire			stop0;
wire			stop1;

reg		[68:0]	out_buf;
reg		[31:0]	ready;
reg		[36:0]	entries		[0:31];
reg		[31:0]	commit_vals [0:31];
reg		[4:0]	commit_head = 0;
reg		[4:0]	commit_tail = 0;

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
	else if (ready[commit_tail] && next && !stop0) begin
		out_buf[68:32] <= entries[commit_tail];
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
		if (rst)
			ready[i] <= 0;
		else if ((i == commit_tail) && ready[i] && next)
			ready[i] <= 0;
		else if (entries[i][36:32] == tag_wb) begin
			commit_vals[i] <= wb_val;
			ready[i] <= 1;
		end
	end
end
endgenerate

assign out_entry = out_buf[67:32];
assign out_value = out_buf[31:0];

endmodule

/* Reservation station with three entries. */

module
reservation_station(
	input			clk,
	input			rst,
	input			new_incoming,
	input	[5:0]	new_wb_tag,
	input	[31:0]	new_insn,
	input	[5:0]	new_tag_a,
	input 	[31:0]	new_value_a,
	input	[5:0]	new_tag_b,
	input	[31:0]	new_value_b,
	input	[63:0]	new_timestamp,
	output	[5:0]	next_wb_tag,
	output	[31:0]	next_insn,
	output	[31:0]	next_value_a,
	output	[31:0]	next_value_b,
	input	[4:0]	common_writeback_tag,
	input	[31:0]	common_writeback_value,
	output			none_free
);

reg		[2:0]	using;
wire	[3:0]	use_next;
reg 	[5:0]	wb_tags		[0:2];
reg		[31:0]	insns		[0:2];
reg 	[5:0]	qi_tags		[0:2];
reg 	[31:0]	vi_values	[0:2];
reg 	[5:0]	qj_tags		[0:2];
reg 	[31:0]	vj_values	[0:2];
reg		[63:0]	timestamps	[0:2];
wire	[2:0]	ready;
wire	[2:0]	run;

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
			qi_tags[i] <= new_tag_a;
			qj_tags[i] <= new_tag_b;
			vi_values[i] <= new_value_a;
			vj_values[i] <= new_value_b;
			timestamps[i] <= new_timestamp;
		end
		else if (run[i])
			using[i] <= 0;
		else if (using[i]) begin
			if (common_writeback_tag == qi_tags[i][4:0] && qi_tags[i][5]) begin
				vi_values[i] <= common_writeback_value;
				qi_tags[i][5] <= 0;
			end
			if (common_writeback_tag == qj_tags[i][4:0] && qj_tags[i][5]) begin
				vj_values[i] <= common_writeback_value;
				qj_tags[i][5] <= 0;
			end
		end
	end
	assign ready[i] = using[i] && !(qi_tags[i][5] || qj_tags[i][5]);
end
endgenerate

assign use_next[0] = 1'b1;
assign none_free = use_next[3];

assign run[0] = ready[0] &&
				((timestamps[0] < timestamps[1] || !ready[1]) &&
				 (timestamps[0] < timestamps[2] || !ready[2]));
assign run[1] = ready[1] &&
				((timestamps[1] < timestamps[0] || !ready[0]) &&
				 (timestamps[1] < timestamps[2] || !ready[2]));
assign run[2] = ready[2] &&
				((timestamps[2] < timestamps[0] || !ready[0]) &&
				 (timestamps[2] < timestamps[1] || !ready[1]));

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
	output	[7:0]	st8
);

/* Program counter logic. */

reg [31:0] program_counter;

always @(posedge clk) begin
	if (rst)
		program_counter <= 0;
	else
		program_counter <= program_counter + 1;
end

/* Push a new instruction onto the pending queue. */

wire push_new_insn;

/* Fetch and decode stages will stall if there are no RSes free to receive a new
   instruction. */

wire [3:0] none_free;

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

wire [36:0] commit_queue_new_entry;

/* value and tag for writeback from execution units. */

wire [4:0] writeback_tag;
wire [31:0] writeback_value;

/* Next entry in the commit queue to retire. */

wire retire_next_commit;
wire [36:0] commit_queue_retire;
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

assign rename = get_next_insn &&
				((xclass == C_DAB) || (xclass == C_DXB) ||
				 (xclass == C_DXX) || (xclass == C_DIMM16));

register_renamer
_register_renamer(
	.clk (clk),
	.rst (rst),
	.rename (rename),
	.nr_wb (nr_wb),
	.nr_a (nr_a),
	.nr_b (nr_b),
	.clearing (1'b0),
	.tag_clear (commit_queue_retire[36:32]),
	.tag_wb (new_tag_wb),
	.tag_a (new_tag_a),
	.tag_b (new_tag_b)
);

assign commit_queue_new_entry[36:32] = new_tag_wb;
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

/* Timestamp counter for counting instruction timestamps. */

reg [63:0] timestamp;

/* Buffer between predecode and execution stage. */

reg [181:0] dispatch_buffer;

always @(posedge clk) begin
	if (rst)
		dispatch_buffer <= 0;
	else begin
		dispatch_buffer[181:178] <= execution_unit;
		dispatch_buffer[177:114] <= timestamp;
		dispatch_buffer[113:108] <= decoded_tag_wb;
		dispatch_buffer[107:102] <= decoded_tag_a;
		dispatch_buffer[101: 70] <= decoded_value_a;
		dispatch_buffer[ 69: 64] <= decoded_tag_b;
		dispatch_buffer[ 63: 32] <= decoded_value_b;
		dispatch_buffer[ 31:  0] <= insn;
	end
	if (rst)
		timestamp <= 0;
	else
		timestamp <= timestamp + 1;
end

/* Managing reservation stations: Fairly simple mechanism, similar to renamer.
   If no stations are free, stall everything above by disabling get_next_insn
   and wait for some retires. */

/* EU_MEM. */

wire eu_mem_incoming = dispatch_buffer[181:178] == EU_MEM;
wire [5:0] eu_mem_wb_tag;
wire [31:0] eu_mem_insn;
wire [31:0] eu_mem_addr;
wire [31:0] eu_mem_tostore;
reg [31:0] eu_mem_wb;

reg [31:0] eu_mem_out_addr;
reg [31:0] eu_mem_out_mem;

reservation_station
eu_mem_reservation_station(
	.clk (clk),
	.rst (rst),
	.new_incoming (eu_mem_incoming),
	.new_wb_tag (dispatch_buffer[113:108]),
	.new_insn (dispatch_buffer[31:0]),
	.new_tag_a (dispatch_buffer[107:102]),
	.new_value_a (dispatch_buffer[101:70]),
	.new_tag_b (dispatch_buffer[69:64]),
	.new_value_b (dispatch_buffer[63:32]),
	.new_timestamp (dispatch_buffer[177:114]),
	.next_wb_tag (eu_mem_wb_tag),
	.next_insn (eu_mem_insn),
	.next_value_a (eu_mem_tostore),
	.next_value_b (eu_mem_addr),
	.common_writeback_tag (writeback_tag),
	.common_writeback_value (writeback_value),
	.none_free (none_free[0])
);

always @* begin
	case (eu_mem_insn[31:24])
		8'h00: begin
			/* Take control of memory interface from fetch logic. */
			eu_mem_out_addr <= eu_mem_addr;
			eu_mem_out_mem <= 0;
			eu_mem_wb <= in_mem;
		end
		8'h01: begin
			/* Take control of memory interface from fetch logic. */
			eu_mem_out_addr <= eu_mem_addr;
			eu_mem_out_mem <= eu_mem_tostore;
			eu_mem_wb <= 0;
		end
		default: begin
			eu_mem_out_addr <= 0;
			eu_mem_out_mem <= 0;
			eu_mem_wb <= 0;
		end
	endcase
end

//assign out_addr = eu_mem_out_addr;
//assign out_mem = eu_mem_out_mem;

/* EU_ALU. */

wire eu_alu_incoming = dispatch_buffer[181:178] == EU_ALU;
wire [5:0] eu_alu_wb_tag;
wire [31:0] eu_alu_insn;
wire [31:0] eu_alu_a;
wire [31:0] eu_alu_b;
reg [31:0] eu_alu_wb;

reservation_station
eu_alu_reservation_station(
	.clk (clk),
	.rst (rst),
	.new_incoming (eu_alu_incoming),
	.new_wb_tag (dispatch_buffer[113:108]),
	.new_insn (dispatch_buffer[31:0]),
	.new_tag_a (dispatch_buffer[107:102]),
	.new_value_a (dispatch_buffer[101:70]),
	.new_tag_b (dispatch_buffer[69:64]),
	.new_value_b (dispatch_buffer[63:32]),
	.new_timestamp (dispatch_buffer[177:114]),
	.next_wb_tag (eu_alu_wb_tag),
	.next_insn (eu_alu_insn),
	.next_value_a (eu_alu_a),
	.next_value_b (eu_alu_b),
	.common_writeback_tag (writeback_tag),
	.common_writeback_value (writeback_value),
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

assign push_new_insn = 1'b1;
assign get_next_insn = 1'b1;
assign out_addr = program_counter;
assign writeback_tag = eu_alu_wb_tag[4:0];
assign writeback_value = eu_alu_wb;
assign st8 = eu_alu_wb;

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
wire [31:0] memread;
wire [31:0] towrite;

main
_main(
	.clk (clk),
	.rst (rst),
	.in_mem (memread),
	.out_addr (addr),
	.out_mem (towrite),
	.st8 (out)
);

assign memread = mem[addr[9:0]];

always @(posedge clk) begin
	if (rst) begin
		mem[0] <= 31'h02000001;
		mem[1] <= 31'h02000002;
		mem[2] <= 31'h02000003;
	end
	//else if () begin
	//	mem[addr] <= towrite;
	//end
end

endmodule
