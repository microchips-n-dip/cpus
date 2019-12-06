#ifndef RESERVATION_STATION_H
#define RESERVATION_STATION_H

struct rs_entry {
  int occupied;
  int opcode;
  int tag_wb;
  struct operand operand_a;
  struct operand operand_b;
  struct operand operand_f;
};

struct reservation_station {
  struct rs_entry entries[4];
};

extern void rs_init(struct reservation_station *);
extern int rs_push(struct reservation_station *, struct instr_ifid);
extern int rs_next(struct reservation_station *, struct instr_idex *);
extern void rs_writeback(struct reservation_station *, struct instr_exwb);

#endif

