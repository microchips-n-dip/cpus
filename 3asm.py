import sys, os

class Location:
	def __init__(self, file, number):
		self.file = file
		self.number = number

def error_at(loc, text):
	locus_cs = "\33[01m\33[K"
	locus_ce = "\33[m\33[K"
	location_text = ''.join([locus_cs, loc.file, ':', str(loc.number),
				 ':', locus_ce])
	kind_cs = "\33[01;31m\33[K"
	kind_ce = "\33[m\33[K"
	kind_text = ''.join([kind_cs, "error:", kind_ce])
	error_text = ' '.join([location_text, kind_text, text])
	print(error_text)
	sys.exit(1)

# File reading system

class File:
	def __init__(self):
		self.fp = 0
		self.buffer = ""
		self.path = ""
		self.size = 0

class Buffer:
	def __init__(self):
		self.buffer = ""
		self.cur = 0
		self.need_line = False
		self.need_eol = False
		self.line = 0
		self.next_line = 0

class Reader:
	def __init__(self):
		self.buffer = Buffer()
		self.file = File()
		self.lineno = 0
	def location(self):
		return Location(self.file.path, self.lineno)

parse_in = Reader()

def read_file(file):
	file.fp = open(file.path, "r")
	with file.fp as fp:
		file.buffer = fp.read()
	file.size = len(file.buffer)

def create_reader(path):
	reader = Reader()
	reader.file.path = path
	read_file(reader.file)
	reader.buffer.buffer = reader.file.buffer
	reader.buffer.need_line = True
	return reader

def clean_line(reader):
	s = reader.buffer.next_line
	reader.buffer.need_line = False
	while (True):
		if (reader.buffer.buffer[s] == "\n"):
			break
		s += 1
	reader.buffer.line = reader.buffer.next_line
	reader.buffer.next_line = s + 1
	reader.lineno += 1

def get_fresh_line(reader):
	while (True):
		if (not reader.buffer.need_line):
			return True
		if (reader.buffer.next_line < reader.file.size):
			clean_line(reader)
			return True
		return False


# Bit width specifications
# 32-bit system
# One byte per instruction field?

# Memory access instructions
# LOAD  r, m	- 00 rr xx mm - Load							- done
# STORE m, r	- 01 xx mm rr - Store							- done
# LDI   r, c	- 02 rr cc cc - Load 16 bit immediate			- done
# PUSH 	r		- 03 xx 0c rr - Push at sp						- done
# POP	r		- 04 rr 0c xx - Pop at sp						- done
# MOV	r, r	- 05 dd ss xx - Move reg to reg					- done
# Arithmetic instructions
# ADD	r, r, r	- 06 dd aa bb - Add								- done
# SUB	r, r, r	- 07 dd aa bb - Subtract						- done
# MUL	r, r, r	- 08 dd aa bb - Multiply
# DIV	r, r, r	- 09 dd aa bb - Divide
# Logic operations
# AND	r, r, r	- 0a dd aa bb - Logical and
# OR 	r, r, r	- 0b dd aa bb - Logical or
# NOR	r, r, r	- 0c dd aa bb - Logical nor
# NOT	r, r	- 0d dd aa xx - Logical not
# XOR	r, r, r	- 0e dd aa bb - Logical xor
# Branch instructions
# CMP	r, r	- 0f xx aa bb - Compare							- done
# BEQ	r		- 10 xx rr xx - Branch if eq flag is set
# BEQ	c		- 11 cc cc cc
# BNE	r		- 12 xx rr xx - Branch if ne flag is set		- done
# BNE	c		- 13 cc cc cc
# BGT	r		- 14 xx rr xx - Branch if gt flag is set
# BGT	c		- 15 cc cc cc
# BLT	r		- 16 xx rr xx - Branch if lt flag is set
# BLT	c		- 17 cc cc cc
# BGE	r		- 18 xx rr xx - Branch if ge flag is set
# BGE	c		- 19 cc cc cc
# BLE	r		- 1a xx rr xx - Branch if le flag is set
# BLE	c		- 1b cc cc cc
# BNZ	r		- 1c xx rr xx - Branch if zero flag is set
# BNZ	c		- 1d cc cc cc
# BL	r		- 1e xx rr xx - Branch and set link register	- done
# BL	c		- 1f cc cc cc
# B	r			- 20 xx rr xx - Unconditional branch			- done
# B	c			- 21 cc cc cc - 24 bit pc inc/dec (2's complement)

TOKEN_NAME = 0
TOKEN_NUMBER = 1
TOKEN_OPEN_BRACE = 2
TOKEN_CLOSE_BRACE = 3
TOKEN_COLON = 4
TOKEN_COMMA = 5
TOKEN_OTHER = 6
TOKEN_COMMENT = 7
TOKEN_EOL = 8
TOKEN_EOF = 9

class Token:
	def __init__(self):
		self.type = 0
		self.val = ""
		self.location = 0

def lex_token(reader):
	buffer = reader.buffer
	result = Token()
	while True:
		result.location = reader.location()
		if (not get_fresh_line(reader)):
			result.type = TOKEN_EOF
			return result
		c = buffer.buffer[buffer.cur]
		buffer.cur += 1
		if (c == '\n'):
			buffer.need_line = True
			if (buffer.need_eol):
				result.type = TOKEN_EOL
				buffer.need_eol = False
				return result
			continue
		if (c == ' '):
			while (buffer.buffer[buffer.cur] == ' '):
				buffer.cur += 1
			continue
		elif (c.isalpha()):
			base = buffer.cur - 1
			while (buffer.buffer[buffer.cur].isalnum()):
				buffer.cur += 1
			result.type = TOKEN_NAME
			result.val = buffer.buffer[base:buffer.cur]
			break
		elif (c == '$'):
			base = buffer.cur
			while (buffer.buffer[buffer.cur].isdigit()):
				buffer.cur += 1
			result.type = TOKEN_NUMBER
			result.val = int(buffer.buffer[base:buffer.cur])
			break
		elif (c == '/'):
			if (buffer.buffer[buffer.cur] == '*'):
				#result.type = TOKEN_COMMENT
				base = buffer.cur - 1
				while (buffer.buffer[buffer.cur] != '*' or
				       buffer.buffer[buffer.cur + 1] != '/'):
					buffer.cur += 1
				#result.val = buffer.buffer[base:buffer.cur + 1]
				continue
			# No other cases at this point, our assembler is fairly
			# simple.
			#break
		elif (c == ':'):
			result.type = TOKEN_COLON
			break
		elif (c == ','):
			result.type = TOKEN_COMMA
			break
	buffer.need_eol = True
	return result

class Parser:
	def __init__(self):
		self.tokens = []
		self.tokens_avail = 0

parse_in = None

def peek_token(parser):
	if (parser.tokens_avail == 0):
		tok = lex_token(parse_in)
		parser.tokens.append(tok)
		parser.tokens_avail = 1
	return parser.tokens[0]

def consume_token(parser):
	del parser.tokens[0]
	parser.tokens_avail -= 1

def expect(parser, tok_type, msg):
	# A side effect of having newlines as lexable tokens is they must be
	# skipped sometimes.
	#while (peek_token(parser).type == TOKEN_EOL):
		#consume_token(parser)
	if (peek_token(parser).type != tok_type):
		print(peek_token(parser).type)
		error_at(peek_token(parser).location, msg)

class Instruction:
	def __init__(self):
		self.code = -1
		self.operands = []
		self.oprs = [None, None, None]

	def print(self):
		print("{}\t{}".format(hex(self.code), self.oprs))

def lookup_register(tok):
	name = tok.val
	if (name == "r0"):
		return 0
	elif (name == "r1"):
		return 1
	elif (name == "r2"):
		return 2
	elif (name == "r3"):
		return 3
	elif (name == "r4"):
		return 4
	elif (name == "r5"):
		return 5
	elif (name == "r6"):
		return 6
	elif (name == "r7"):
		return 7
	elif (name == "r8"):
		return 8
	elif (name == "r9"):
		return 9
	elif (name == "r10"):
		return 10
	elif (name == "r11"):
		return 11
	# Special registers
	elif (name == "sp"):	# Stack pointer
		return 12
	elif (name == "fp"):	# Frame pointer
		return 13
	elif (name == "lr"):	# Link register
		return 14
	elif (name == "pc"):	# Program counter
		return 15
	else:
		error_at(tok.location,
			 "{} is not a valid register".format(name))

REGISTER = 0x01
IMMEDIATE = 0x02


def lookup_instruction(tok, result):
	if (tok.val == "load"):
		result.code = 0x00
		result.operands = [REGISTER, REGISTER]
	elif (tok.val == "store"):
		result.code = 0x01
		result.operands = [REGISTER, REGISTER]
	elif (tok.val == "ldi"):
		result.code = 0x02
		result.operands = [REGISTER, IMMEDIATE]
	elif (tok.val == "push"):
		result.code = 0x03
		result.operands = [REGISTER]
	elif (tok.val == "pop"):
		result.code = 0x04
		result.operands = [REGISTER]
	elif (tok.val == "mov"):
		result.code = 0x05
		result.operands = [REGISTER, REGISTER]
	elif (tok.val == "add"):
		result.code = 0x06
		result.operands = [REGISTER, REGISTER, REGISTER]
	elif (tok.val == "sub"):
		result.code = 0x07
		result.operands = [REGISTER, REGISTER, REGISTER]
	elif (tok.val == "cmp"):
		result.code = 0x0f
		result.operands = [REGISTER, REGISTER]
	elif (tok.val == "bne"):
		result.code = 0x12
		result.operands = [REGISTER]
	elif (tok.val == "bl"):
		result.code = 0x1e
		result.operands = [REGISTER]
	elif (tok.val == "b"):
		result.code = 0x20
		result.operands = [REGISTER]
	else:
		error_at(tok.location, "unknown instruction '{}'".format(tok.val))

def register_operand(operand, result, tok):
	if (result.operands[operand] & IMMEDIATE
	    and tok.type == TOKEN_NUMBER):
		result.oprs[operand] = tok.val
	elif (result.operands[operand] == IMMEDIATE):
		error_at(tok.location, "expected immediate")
	else:
		result.oprs[operand] = lookup_register(tok)

def assemble(parser):
	result = Instruction()
	# Start by obtaining the label and instruction
	while True:
		expect(parser, TOKEN_NAME, "expected name or keyword")
		name_token = peek_token(parser)
		consume_token(parser)
		if (peek_token(parser).type == TOKEN_COLON):
			# name_token indicates a label. Store the label and restart.
			consume_token(parser)
			# Optional newline here, just consume it.
			if (peek_token(parser).type == TOKEN_EOL):
				consume_token(parser)
			continue
		else:
			# name_token is the instruction
			lookup_instruction(name_token, result)
			break
	# Now there's the operand section.
	operand = 0
	while (operand < len(result.operands)):
		register_operand(operand, result, peek_token(parser))
		consume_token(parser)
		operand += 1
		if (operand < len(result.operands)):
			expect(parser, TOKEN_COMMA, "expected ','")
			consume_token(parser)
	expect(parser, TOKEN_EOL, "expected eol")
	consume_token(parser)
	return result

def test_main(argc, argv):
	global parse_in
	parse_in = create_reader(argv[1])
	parser = Parser()
	while (peek_token(parser).type != TOKEN_EOF):
		insn = assemble(parser)
		insn.print()

test_main(len(sys.argv), sys.argv)

