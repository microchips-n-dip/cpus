import copy
from packed_instruction import *

# Tags are basically modular arithmetic, so we need a special operation to
# properly compute the offset in the reorder buffer.

def tag_diff(a, b):
  return a - b

# Use this placeholder class for storing reorder buffer entries.

class ROB_Entry:
  def __init__(self):
    self.instr = PackedInstruction()
    self.waiting = False

class ReorderBuffer:
  def __init__(self):
    self.entries = [ROB_Entry() for i in range(4)]
    self.head, self.tail = 0, 0

  def push(self, instr):
    entry = self.entries[self.head]
    entry.instr = copy.deepcopy(instr)
    entry.waiting = True

  # Lookup an entry in the reorder buffer by tag, if it's still pending then
  # return None

  def lookup(self, tag, i):
    base_entry = self.entries[0]
    base_tag = base_entry.instr.op_tags[i]
    diff = tag_diff(tag, base_tag)
    if (diff > self.head):
      return None
    entry = self.entries[diff]
    if (entry.waiting):
      return None
    return entry.instr.result

  # Writeback to an entry in the reorder buffer and set the waiting bit to
  # False

  def writeback(self, tag, result):
    base_entry = self.entries[0]
    base_tag = base_entry.instr.wb_tag
    diff = tag_diff(tag, base_tag)
    if (diff > self.head):
      return None
    entry = self.entries[diff]
    entry.waiting = False
    entry.instr.result = result
