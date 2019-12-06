from packed_instruction import *
from reorder_buffer import *
from reservation_station import *
import exus

class CPU4:
  def __init__(self):
    self.rob = ReorderBuffer()
    self.alu_rs = ReservationStation()
    self.alu_exu = exus.ALU()
    self.mul_rs = ReservationStation()
    self.mul_exu = exus.MUL()
  
  def loop(self):
    # Push the new instruction to the reorder buffer
    self.rob.push(instr)
    # Fetch all the operands, we need to wait if they return None
    for i in range(2):
      instr.operands[i] = self.rob.lookup(instr.op_tags[i], i)
    # Place the instruction in the appropriate reservation station
    if exu == EXU_ALU:
      self.alu_rs.new_instr(instr, waiting)
    elif exu == EXU_MUL:
      self.mul_rs.new_instr(instr, waiting)
    # Fetch the latest instructions from each reservation station and execute
    # them
    alu_instr = self.alu_rs.retrieve_instr()
    mul_instr = self.mul_rs.retrieve_instr()
    results = [None, None, ]
    results[0] = self.alu_exu.execute(alu_instr)
    results[1] = self.mul_exu.execute(mul_instr)
    
    
