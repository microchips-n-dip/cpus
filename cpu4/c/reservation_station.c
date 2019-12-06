#include "tag.h"
#include "operand.h"
#include "reservation_station.h"

/* Check if the entry is ready. */

static inline int
rs_entry_ready(struct rs_entry entry) {
  if (entry.occupied && !entry.operand_a.waiting &&
      !entry.operand_b.waiting && !entry.operand_f.waiting)
    return 1;
  else
    return 0;
}

/* Initialize the reservation station. */

void
rs_init(struct reservation_station *rs) {
  int i;
#define ENTRY (rs->entries[i])
  for (i = 0; i < 4; i++) {
    ENTRY.occupied = 0;
  }
#undef ENTRY
}

/* Add a new instruction to a reservation station. */

int
rs_push(struct reservation_station *rs, struct instr_ifid instr) {
  int i = 0;
#define ENTRY (rs->entries[i])
  while ((i < 4) && (ENTRY.occupied))
    i++;
  if (i == 4)
    return 0;
  ENTRY.tag_wb = instr.tag_wb;
  ENTRY.operand_a = instr.operand_a;
  ENTRY.operand_b = instr.operand_b;
  ENTRY.operand_f = instr.operand_f;
  ENTRY.opcode = instr.opcode;
  ENTRY.occupied = 1;
#undef ENTRY
  return 1;
}

/* Get the next instruction from the reservation station. */

int
rs_next(struct reservation_station *rs, struct instr_idex *instr) {
  int i = 0, oldest = 0, age;
#define ENTRY  (rs->entries[i])
#define OLDEST (rs->entries[oldest])
  /* We need to initialize the oldest and ready entry. */
  while (i < 4) {
    if (rs_entry_ready(ENTRY)) {
      oldest = i;
      age = ENTRY.tag_wb;
      break;
    }
    i++;
  }
  if (oldest == 4)
    return 0;
  /* Now find the actual oldest ready entry. */
  while (i < 4) {
    if (rs_entry_ready(ENTRY) && tag_lt(ENTRY.tag_wb, age)) {
      oldest = i;
      age = ENTRY.tag_wb;
    }
    i++;
  }
  /* Finally return the instruction. */
  instr->tag_wb = OLDEST.tag_wb;
  instr->opcode = OLDEST.opcode;
  instr->operand_a = OLDEST.operand_a.value;
  instr->operand_b = OLDEST.operand_b.value;
  instr->operand_f = OLDEST.operand_f.value;
  OLDEST.occupied = 0;
#undef ENTRY
#undef OLDEST
  return 1;
}

/* Find any waiting values in the reservation station corresponding to the
   current writeback tag and write to them, setting the waiting state
   accordingly. */

void
rs_writeback(struct reservation_station *rs, struct instr_exwb instr) {
  int i = 0;
#define ENTRY (rs->entries[i])
  while (i < 4) {
    if (ENTRY.operand_a.waiting && (ENTRY.operand_a.tag == instr.tag_wb)) {
      ENTRY.operand_a.value = instr.result;
      ENTRY.operand_a.waiting = 0;
    }
    if (ENTRY.operand_b.waiting && (ENTRY.operand_b.tag == instr.tag_wb)) {
      ENTRY.operand_b.value = instr.result;
      ENTRY.operand_b.waiting = 0;
    }
    if (ENTRY.operand_f.waiting && (ENTRY.operand_f.tag == instr.tag_wb)) {
      ENTRY.operand_f.value = instr.flags;
      ENTRY.operand_f.waiting = 0;
    }
    i++;
  }
#undef ENTRY
}
