#ifndef OPERAND_H
#define OPERAND_H

/* A simple operand struct. */

struct operand {
  int waiting;
  int tag;
  int value;
};

/* An instruction for IF/ID actions. */

struct instr_ifid {
  int tag_wb;
  int opcode;
  struct operand operand_a;
  struct operand operand_b;
  struct operand operand_f;
};

/* An instruction for ID/EX actions. */

struct instr_idex {
  int tag_wb;
  int opcode;
  int operand_a;
  int operand_b;
  int operand_f;
};

/* An instruction for EX/WB actions. */

struct instr_exwb {
  int tag_wb;
  int result;
  int flags;
};

#endif

