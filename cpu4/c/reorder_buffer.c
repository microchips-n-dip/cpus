struct rob_entry {
  int waiting;
  int opcode;
  int tag;
  int value;
  int flags;
};

struct reorder_buffer {
  int head;
  int tail;
  struct rob_entry entries[32];
};

/* Initialize the reorder buffer. */

void
rob_init(struct reorder_buffer *rob) {
  int i;
#define ENTRY (rob->entries[i])
  for (i = 0; i < 32; i++) {
    ENTRY.waiting = 0;
  }
  head = 0;
  tail = 0;
#undef ENTRY
}

/* Push a new instruction to the ROB. */

int
rob_push(struct reorder_buffer *rob, int opcode, int tag) {
  if (rob->head + 1 == rob->tail)
    return 0;
#define HEAD (rob->entries[rob->head])
  HEAD.waiting = 1;
  HEAD.opcode = opcode;
  HEAD.tag = tag;
#undef HEAD
  rob->head = (rob->head + 1) % 32;
  return 1;
}

/* Get the next instruction to retire from the commit queue. */

int
rob_next(struct reorder_buffer *rob, int *opcode) {
  if (rob->tail == rob->head)
    return 0;
#define TAIL (rob->entries[rob->tail])
  if (TAIL.waiting)
    return 0;
  *opcode = TAIL.opcode;
#undef TAIL
  rob->tail = (rob->tail + 1) % 32;
  return 1;
}

/* Lookup an operand by tag. */

int
rob_lookup(struct reorder_buffer *rob, struct operand *operand) {
  
}

