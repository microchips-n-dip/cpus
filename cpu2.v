/* pending_queue takes care of queueing up instructions. */

module pending_queue(
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

/* The main CPU module.
   The CPU has the following stages:
       fetch - fetches the instruction pointed to by the program counter
   and pushes it onto the back of the pending queue. If the pending queue
   is full, instruction fetching is automatically disabled and the program
   counter does not get incremented.
       decode - decodes the fetched instruction. Also contains the register
   file, so any register values necessary are retrieved at this stage. In
   order to avoid potential hazards, if a register being read from is also
   being written to in the execute stage, the value is replaced with the
   writeback result from the execute stage.
	   execute - executes the decoded instruction. In the case of memory
   operations, instruction fetching is disabled for one cycle.
   */

module cpu(
	input clk,
	input rst,
	input mmr_served,
	input [15:0] in_data,
	output memwr_req,
	output [7:0] out_addr,
	output [15:0] out_data,
	output [7:0] st8,
	output [3:0] st3
);

reg stall = 0;	/* Stall the processor. */
wire do_jmp;	/* Doing a jump, disable normal PC increment. */
wire [7:0] jmp_target;

/* We know the current jump is complete and the pipeline has been flushed
   when the PC value given to the decode stage is equal to the new PC value
   used in the jump. */

wire complete_jmp;

/* Fetch stage. */

/* p_new signals pushing a new value onto the pending queue and updating the
   program counter. Disabled if p_full is on, or memory request has not been
   served. */

wire p_new;

/* p_next signals retrieval of the next value on the pending queue. Must be
   disabled during any multi-cycle instructions (ie memory operations), or
   when the p_empty is on. When off, disable all interstage buffers otherwise
   we end up duplicating instructions. */

wire p_next;

/* p_clear used at jumps to reset the pending queue head to the tail, thus
   making it empty again. */

wire p_clear;
reg p_cleared = 0;

wire p_empty;	/* Indicates that the pending queue is empty. */
wire p_full;	/* Indicates that the pending queue is full. */

/* New instruction to add to pending queue. Split into two fields:
       p_new_insn[15:0] is the instruction.
	   p_new_insn[23:16] is the program counter value for that instruction. */

wire [23:0] p_new_insn;

/* Fetch/Decode interstage buffer. */

wire [23:0] fd_inter;

/* Active when the current instruction memory request has been served.
   Disabled whenever there is a competing memory request. */

wire imr_served;

reg [7:0] program_counter = 0;

//wire clk = _clk && (pc3 != 16'hff00);

pending_queue pending(
	.clk (clk),
	.rst (rst),
	.push (p_new),
	.next (p_next),
	.clear (p_clear),
	.empty (p_empty),
	.full (p_full),
	.in_insn (p_new_insn),
	.out_insn (fd_inter)
);

//assign pc3 = program_counter[3:0]; //= fd_inter[15:12];
assign st3[0] = de_inter[45];

assign imr_served = mmr_served && !stall;

assign p_new = !(p_full | !imr_served);
assign p_next = !(p_empty | stall);
assign p_clear = do_jmp && !p_cleared;

assign p_new_insn[15:0] = in_data;
assign p_new_insn[23:16] = program_counter;

always @(posedge clk) begin
	if (rst) begin
		program_counter <= 0;
	end
	/* Update the program counter whenever a new instruction has been added to
	   the pending queue. */
	else if (p_new) begin
		program_counter <= program_counter + 8'b1;
		if (!do_jmp)
			p_cleared <= 1'b0;
	end
	else if (do_jmp) begin
		program_counter <= jmp_target;
		p_cleared <= 1'b1;
	end
end

/* Decode stage. */

reg [52:0] de_inter = 0;	/* Decode/Execute interstage buffer. */
wire [20:0] ed_inter;		/* Execute/Decode interstage buffer. */

/* Instruction wires. */

wire i_load;	/* LOAD. */
wire i_store;	/* STORE. */
wire i_ldi;		/* LDI/LOAD IMMEDIATE. */
wire i_add;		/* ADD. */
wire i_sub;		/* SUB. */
wire i_and;		/* AND. */
wire i_xor;		/* XOR. */
wire i_or;		/* OR. */
wire i_not;		/* NOT. */
wire i_jmp0;	/* JUMP/JUMP TO IMMEDIATE. */
wire i_jmp;		/* JUMP/JUMP TO REGISTER. */
wire i_jnz0;	/* JNZ/JNZ TO IMMEDIATE. */
wire i_jnz;		/* JNZ/JNZ TO REGISTER. */
wire i_push;	/* PUSH. */
wire i_pop;		/* POP. */
wire i_mov;		/* MOV. */

/* Registers. */

/* Special registers:
   rf[15] == pc.
   rf[14] == esi.
   rf[13] == link - recommend using this when returning after a "call".
   */

reg [7:0] stack_pointer = 0;	/* Stack pointer. */

reg [15:0] rf [0:13];	/* General purpose registers. */

wire [3:0] nr_wb;	/* Register number for writeback */
wire [3:0] nr_a;	/* Register number for output A. */
wire [15:0] rf_a;	/* Register file output A. */
wire [3:0] nr_b;	/* Register number for output B. */
wire [15:0] rf_b;	/* Register file output B. */

assign nr_wb = ed_inter[19:16];
assign nr_a = fd_inter[7:4];
assign rf_a = (nr_a == 4'hf) ? fd_inter[23:16] :
			  (nr_a == nr_wb && ed_inter[20]) ? ed_inter[15:0] :
			  (nr_a == 4'he) ? stack_pointer :
			  rf[nr_a];
assign nr_b = fd_inter[3:0];
assign rf_b = (nr_b == 4'hf) ? fd_inter[23:16] :
			  (nr_b == nr_wb && ed_inter[20]) ? ed_inter[15:0] :
			  (nr_b == 4'he) ? stack_pointer :
			  rf[nr_b];

/* Since register writeback takes the place of a separate writeback stage,
   it must be considered its own interstage and disabled when p_next is off. */

reg unused; /* To appease the verilog gods. */

always @(posedge clk) begin
	if (rst) begin
		de_inter <= 0;
	end
	else if (p_next) begin
		if (nr_wb == 4'hf && ed_inter[20]) begin
			/* Do nothing; writing to the program counter must be done by jump
			   instructions because it requires special handling.
			   As a consequence of this, ff00 (MOV r15, r0) can be used as
			   a nop instruction. */
			unused <= 0;
		end
		else if (nr_wb == 4'he && ed_inter[20]) begin
			/* Handled elsewhere. */
			unused <= 0;
		end
		else if (ed_inter[20]) begin
			rf[nr_wb] <= ed_inter[15:0];
		end
		if (ed_inter[15:0] == 16'h0000) begin
			de_inter[52] <= 1'b1;
		end
		else begin
			de_inter[52] <= 1'b0;
		end
		/* Do not do anything here if jumping because the next instruction can
		   get lost, it's annoying and nobody likes it. */
		if (!do_jmp || complete_jmp) begin
			if (i_ldi || i_jmp0 || i_jnz0) begin
				de_inter[7:0] <= fd_inter[7:0];
			end
			else begin
				de_inter[15:0] <= rf_b;
				de_inter[31:16] <= rf_a;
			end
			de_inter[35:32] <= fd_inter[11:8];
			de_inter[36] <= i_load;
			de_inter[37] <= i_store;
			de_inter[38] <= i_ldi;
			de_inter[39] <= i_add;
			de_inter[40] <= i_sub;
			de_inter[41] <= i_and;
			de_inter[42] <= i_xor;
			de_inter[43] <= i_or;
			de_inter[44] <= i_not;
			de_inter[45] <= i_jmp0;
			de_inter[46] <= i_jmp;
			de_inter[47] <= i_jnz0;
			de_inter[48] <= i_jnz;
			de_inter[49] <= i_push;
			de_inter[50] <= i_pop;
			de_inter[51] <= i_mov;
		end
	end
end

assign i_load  = ~fd_inter[15] & ~fd_inter[14] & ~fd_inter[13] & ~fd_inter[12];
assign i_store = ~fd_inter[15] & ~fd_inter[14] & ~fd_inter[13] &  fd_inter[12];
assign i_ldi   = ~fd_inter[15] & ~fd_inter[14] &  fd_inter[13] & ~fd_inter[12];
assign i_add   = ~fd_inter[15] & ~fd_inter[14] &  fd_inter[13] &  fd_inter[12];
assign i_sub   = ~fd_inter[15] &  fd_inter[14] & ~fd_inter[13] & ~fd_inter[12];
assign i_and   = ~fd_inter[15] &  fd_inter[14] & ~fd_inter[13] &  fd_inter[12];
assign i_xor   = ~fd_inter[15] &  fd_inter[14] &  fd_inter[13] & ~fd_inter[12];
assign i_or    = ~fd_inter[15] &  fd_inter[14] &  fd_inter[13] &  fd_inter[12];
assign i_not   =  fd_inter[15] & ~fd_inter[14] & ~fd_inter[13] & ~fd_inter[12];
assign i_jmp0  =  fd_inter[15] & ~fd_inter[14] & ~fd_inter[13] &  fd_inter[12];
assign i_jmp   =  fd_inter[15] & ~fd_inter[14] &  fd_inter[13] & ~fd_inter[12];
assign i_jnz0  =  fd_inter[15] & ~fd_inter[14] &  fd_inter[13] &  fd_inter[12];
assign i_jnz   =  fd_inter[15] &  fd_inter[14] & ~fd_inter[13] & ~fd_inter[12];
assign i_push  =  fd_inter[15] &  fd_inter[14] & ~fd_inter[13] &  fd_inter[12];
assign i_pop   =  fd_inter[15] &  fd_inter[14] &  fd_inter[13] & ~fd_inter[12];
assign i_mov   =  fd_inter[15] &  fd_inter[14] &  fd_inter[13] &  fd_inter[12];

/* Execute stage. */

wire memop;

/* Detect any jump instructions that get taken. */

assign jmp_target = de_inter[7:0];

wire take_jmp = de_inter[45] || de_inter[46];
wire take_jnz = (de_inter[47] || de_inter[48]) && !de_inter[52];
assign do_jmp = (take_jmp || take_jnz) && !complete_jmp;

/* As mentioned before, the jump is complete when the PC value at fd_inter[23:16]
   is equal to the jump target because the new instruction has been loaded. */

assign complete_jmp = jmp_target == fd_inter[23:16];

/* Detect memory operations. */

assign memop = i_load || i_store || i_push || i_pop;
assign memwr_req = de_inter[37] || de_inter[49];

/* Main execution muxer. */

assign ed_inter[15:0] = de_inter[36] ? in_data :
						de_inter[38] ? de_inter[7:0] :
						de_inter[39] ? de_inter[31:16] + de_inter[15:0] :
						de_inter[40] ? de_inter[31:16] - de_inter[15:0] :
						de_inter[41] ? de_inter[31:16] & de_inter[15:0] :
						de_inter[42] ? de_inter[31:16] ^ de_inter[15:0] :
						de_inter[43] ? de_inter[31:16] | de_inter[15:0] :
						de_inter[44] ? ~de_inter[31:16] :
						de_inter[50] ? in_data :
						de_inter[51] ? de_inter[15:0] :
						16'h0000;

assign ed_inter[19:16] = de_inter[35:32];
assign ed_inter[20] =
	de_inter[36] || de_inter[38] || de_inter[39] || de_inter[40] ||
	de_inter[41] || de_inter[42] || de_inter[43] || de_inter[44] ||
	de_inter[50] || de_inter[51];

/* Do memory interfacing. */

assign out_addr = stall ? (de_inter[36] ? de_inter[15:0] :
						   de_inter[37] ? de_inter[31:16] :
						   stack_pointer) :
						  program_counter;

assign out_data = de_inter[15:0];

/* Update the stack pointer for stack operations. */

always @(posedge clk) begin
	if (de_inter[49]) begin
		stack_pointer <= stack_pointer + 1;
	end
	else if (de_inter[50]) begin
		stack_pointer <= stack_pointer - 1;
	end
	else if (nr_wb == 4'he && ed_inter[20]) begin
		stack_pointer <= ed_inter[7:0];
	end
end

always @(posedge clk) begin
	if (rst) begin
		stall <= 0;
	end
	else if (memop && !stall) begin
		stall <= 1;
	end
	else if (mmr_served) begin
		stall <= 0;
	end
end

endmodule

/* A simple button debouncer. */

module clock_slowdown(
	input clk50m,
	output reg slow_clk
);

reg [26:0] counter = 0;

always @(posedge clk50m) begin
	counter <= (counter >= 249999) ? 0 : counter + 1;
	slow_clk <= (counter < 125000) ? 1'b0 : 1'b1;
end

endmodule

module pbdebounce(
	input pb,
	input clk,
	output pb_out
);

wire slow_clk;
reg q1, q2;

always @(posedge slow_clk) begin
	q1 <= pb;
	q2 <= q1;
end

assign pb_out = q1 & ~q2;

endmodule

module cpu2(
	input notclk,
	input notrst,
	//input in_data,
	output [7:0] out_data,
	output [3:0] pc3
);

wire [7:0] addr;
wire memwr_req;
wire [15:0] write;
reg [15:0] mem [0:255];

wire clk = notclk;
wire rst = ~notrst;

cpu _cpu(
	.clk (clk),
	.rst (rst),
	.mmr_served (1'b1),
	.in_data (mem[addr]),
	.memwr_req (memwr_req),
	.out_addr (addr),
	.out_data (write),
	.st8 (),
	.st3 (pc3)
);

assign out_data = mem[8'hff];

always @(posedge clk) begin
	if (rst) begin
		/* Compute the 32nd Fibonacci number and then loop forever. */
		/* Initialize the a, b registers with the first two numbers. */
		mem[8'h00] <= 16'h2000; /* LDI r0, $00 */
		mem[8'h01] <= 16'h2101; /* LDI r1, $01 */
		/* Set the counter and target. */
		mem[8'h02] <= 16'h2802; /* LDI r8, $02 ; Counter */
		mem[8'h03] <= 16'h2901; /* LDI r9, $01 ; Increment */
		mem[8'h04] <= 16'h2a0c; /* LDI r10, $12 ; Target */
		/* Set a register to the memmapped output address. */
		mem[8'h05] <= 16'h2cff; /* LDI r12, $255 */
		/* The actual Fibonacci loop. */
		mem[8'h06] <= 16'h3301; /* ADD r3, r0, r1 */
		mem[8'h07] <= 16'hf001; /* MOV r0, r1 */
		mem[8'h08] <= 16'hf103; /* MOV r1, r3 */
		/* Increment the counter. */
		mem[8'h09] <= 16'h3889; /* ADD r8, r8, r9 */
		/* Loop back to 6 if r8 != r10. */
		mem[8'h0a] <= 16'h4b8a; /* SUB r11, r8, r10 */
		mem[8'h0b] <= 16'hb006; /* JNZ $05 */
		/* When complete, output and loop forever. */
		mem[8'h0c] <= 16'h10c3; /* STORE r12, r3 */
		mem[8'h0d] <= 16'h900d; /* JUMP $13 */
	end
	else if (memwr_req) begin
		mem[addr] <= write;
	end
end

endmodule
