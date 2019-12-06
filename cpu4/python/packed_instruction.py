class PackedInstruction:
  def __init__(self):
    self.code     = None
    self.wb_tag   = None
    self.result   = 0
    self.flags    = 0
    self.op_tags  = [None for i in range(3)]
    self.operands = [0 for i in range(3)]
  
  def args_populate(self, code, wb_tag, op_tags, operands):
    self.code     = code
    self.wb_tag   = wb_tag
    self.op_tags  = op_tags,
    self.operands = operands
    
