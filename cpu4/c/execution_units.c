/* ALU execution unit. */

#define EXU_ALU_MASK 0xff000000

#define COUT_FLAG 0x1
#define BOUT_FLAG 0x2

void
exu_add(struct instr_idex instr, struct instr_exwb *result) {
  long r;
  switch (instr.opcode & EXU_ALU_MASK) {
    case 0x06000000:
      r = (long) instr.operand_a + instr.operand_b;
      result->value = (int) (r & 0xffffffff);
      result->flags |= (r > 0xffffffff) ? COUT_FLAG : 0;
      break;
    case 0x07000000:
      r = (long) instr.operand_a - instr.operand_b;
      result->value = (int) (r & 0xffffffff);
      result->flags |= (r < 0) ? BOUT_FLAG : 0;
      break;
    case 0x0a000000:
      result->value = instr.operand_a & instr.operand_b;
      break;
    case 0x0b000000:
      result->value = instr.operand_a | instr.operand_b;
      break;
    case 0x0c000000:
      result->value = ~(instr.operand_a | instr.operand_b);
      break;
    case 0x0d000000:
      result->value = ~instr.operand_a;
      break;
    case 0x0e000000:
      result->value = instr.operand_a ^ instr.operand_b;
      break;
  }
}

/* Branch prediction and verification. */

/* For now our predictor will be a simple 2-bit saturating counter. */

struct branch_predictor {
  int counter;
};

/* Predict a branch. */

int
bp_predict(struct branch_predictor *bp) {
  switch (bp->counter) {
    case 0:
    case 1:
      return 0;
    case 2:
    case 3:
      return 1;
  }
}

/* Update the branch predictor. */

/*
   t b a | b a
   0 0 0 | 0 0
   0 0 1 | 0 0
   0 1 0 | 0 1
   0 1 1 | 1 0
   1 0 0 | 0 1
   1 0 1 | 1 0
   1 1 0 | 1 1
   1 1 1 | 1 1
  */

void
bp_update(struct branch_predictor *bp, int taken) {
  int a, b, c = 0;
  a = bp->counter & 0x1;
  b = bp->counter & 0x2;
  c |= ((!a && taken) || (b && !taken)) ? 0x1 : 0x0;
  c |= (((a || b) && taken) || (a && b)) ? 0x2 : 0x0;
  bp->counter = c;
}
