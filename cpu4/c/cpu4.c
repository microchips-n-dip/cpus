#include <stdio.h>

#include "operand.h"
#include "reservation_station.h"

void
print_rs(struct reservation_station *rs) {
  int i;
#define ENTRY (rs->entries[i])
  for (i = 0; i < 4; i++) {
    printf("[%d] := %d, [%d] %d, [%d] %d, [%d] %d\n", ENTRY.tag_wb,
           ENTRY.opcode, ENTRY.operand_a.tag, ENTRY.operand_a.value,
           ENTRY.operand_b.tag, ENTRY.operand_b.value,
           ENTRY.operand_f.tag, ENTRY.operand_f.value);
  }
#undef ENTRY
}

struct instr_ifid
create_instr_ifid(int opcode, int tag_wb, int tag_a, int opa, int tag_b,
                  int opb, int tag_f, int opf) {
  struct instr_ifid instr;
  instr.opcode = opcode;
  instr.tag_wb = tag_wb;
  if (tag_a < 0) {
    instr.operand_a.waiting = 1;
    instr.operand_a.tag = -tag_a;
  }
  else {
    instr.operand_a.waiting = 0;
    instr.operand_a.tag = tag_a;
  }
  instr.operand_a.value = opa;
  if (tag_b < 0) {
    instr.operand_b.waiting = 1;
    instr.operand_b.tag = -tag_b;
  }
  else {
    instr.operand_b.waiting = 0;
    instr.operand_b.tag = tag_b;
  }
  instr.operand_b.value = opb;
  if (tag_f < 0) {
    instr.operand_f.waiting = 1;
    instr.operand_f.tag = -tag_f;
  }
  else {
    instr.operand_f.waiting = 0;
    instr.operand_f.tag = tag_f;
  }
  instr.operand_f.value = opf;
  return instr;
}

void
print_instr_idex(struct instr_idex instr) {
  switch (instr.opcode) {
    case 0:
      printf("[%d] <- %d + %d\n", instr.tag_wb, instr.operand_a,
             instr.operand_b);
      break;
    case 1:
      printf("[%d] <- %d - %d\n", instr.tag_wb, instr.operand_a,
             instr.operand_b);
      break;
  }
}

int main(void) {
  struct reservation_station rs;
  rs_init(&rs);
  /* Push first instruction. */
  struct instr_ifid instr0, instr1, instr2;
  instr0 = create_instr_ifid(0, 0, 0, 5, 0, 3, -1, 0);
  rs_push(&rs, instr0);
  /* Push second instruction. */
  instr1 = create_instr_ifid(1, 2, 0, 11, 0, 5, 0, 0);
  rs_push(&rs, instr1);
  instr2 = create_instr_ifid(1, 1, 0, 7, 0, 4, 0, 0);
  rs_push(&rs, instr2);
  print_rs(&rs);
  /* Get the instruction and print it out. */
  struct instr_idex instr_ex;
  struct instr_exwb instr_wb;
  int i;
  for (i = 0; i < 3; i++) {
    rs_next(&rs, &instr_ex);
    print_instr_idex(instr_ex);
    instr_wb.tag_wb = instr_ex.tag_wb;
    rs_writeback(&rs, instr_wb);
  }
}

