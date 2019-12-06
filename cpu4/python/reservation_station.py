import copy
from packed_instruction import *

class RS_Entry:
  def __init__(self):
    self.occupied = False
    self.waiting  = [0 for i in range(3)]
    self.instr    = PackedInstruction()
  
  def ready(self):
    if (not 1 in self.waiting) and self.occupied:
      return True
    return False
  
  def write(self, result):
    for i, ptag in enumerate(self.instr.op_tags):
      if ptag == tag:
        self.instr.operands[i] = result.result
        self.waiting[i] = 0

class ReservationStation:
  def __init__(self):
    self.entries = [RS_Entry() for i in range(4)]

  def new_instr(self, instr, waiting):
    for entry in self.entries:
      if not entry.occupied:
        entry.instr = copy.deepcopy(instr)
        entry.waiting = waiting
        entry.occupied = True
        return True
    return False
  
  def write(self, result):
    for entry in self.entries:
      entry.write(result)
  
  def retrieve_instr(self):
    oldest = [0, None]
    for i, entry in enumerate(self.entries):
      if entry.ready():
        oldest = [i, entry.instr.wb_tag]
        break
    if not oldest[1]:
      return None
    for i, entry in enumerate(self.entries):
      if entry.ready() and entry.instr.wb_tag < oldest[1]:
        oldest = [i, entry.instr.wb_tag]
    self.entries[oldest[0]].occupied = False
    return self.entries[oldest[0]].instr
  
  
  
