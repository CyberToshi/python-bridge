class_name PythonBridgeSyntaxHighlighter
extends SyntaxHighlighter
## Python syntax highlighter for the bridge's CodeEdit.
## Uses only documented Godot 4 APIs (SyntaxHighlighter virtual method
## _get_line_syntax_highlighting). This is a presentation helper for the
## editor dock; it is not part of the runtime core.
##
## Tokenizer features (kept deliberately small but correct for editing):
##   - keywords, builtins, self/cls
##   - function/class names after `def` / `class`
##   - decorators (`@name` fully colored)
##   - strings: single-quoted, double-quoted, and triple-quoted strings
##     spanning MULTIPLE lines
##   - comments run to end of line
##   - numbers: decimal, hex (0x), binary (0b), octal (0o), floats with `.`
##     and `e`/`E` exponents, `_` separators
##
## Multi-line triple-quoted strings are handled by re-scanning the lines
## before the current one (only triple-quote state is tracked there, with
## comments and single-line strings skipped so `#` inside a string never
## starts a comment). Files in the dock are small, so the linear scan is
## not a performance concern.

const KEYWORDS := [
	"and", "as", "assert", "async", "await", "break", "class", "continue",
	"def", "del", "elif", "else", "except", "False", "finally", "for",
	"from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal",
	"not", "or", "pass", "raise", "return", "True", "try", "while", "with",
	"yield",
]

const BUILTINS := [
	"abs", "all", "any", "bool", "bytes", "dict", "enumerate", "filter",
	"float", "format", "frozenset", "getattr", "hasattr", "int", "isinstance",
	"issubclass", "iter", "len", "list", "map", "max", "min", "next", "object",
	"open", "print", "range", "repr", "reversed", "round", "set", "slice",
	"sorted", "str", "sum", "super", "tuple", "type", "zip",
]

const COL_KEYWORD := Color(0.78, 0.48, 0.98)
const COL_BUILTIN := Color(0.42, 0.65, 0.98)
const COL_FUNC := Color(0.96, 0.84, 0.52)      # names after def/class
const COL_STRING := Color(0.72, 0.92, 0.58)
const COL_COMMENT := Color(0.55, 0.55, 0.55)
const COL_NUMBER := Color(0.95, 0.8, 0.4)
const COL_DECORATOR := Color(0.45, 0.85, 0.8)
const COL_DEFAULT := Color(0.9, 0.9, 0.9)

func _get_line_syntax_highlighting(line: int) -> Dictionary:
	var text: TextEdit = get_text_edit()
	# Re-scan previous lines to find out whether `line` starts inside an
	# open triple-quoted string. Only triple-quote state is tracked, so
	# comments and one-line strings are handled correctly.
	var open_quote := ""
	for l in range(line):
		open_quote = _scan_triple_state(text.get_line(l), open_quote)
	var regions := {}
	_highlight_line(text.get_line(line), open_quote, regions)
	return regions

## Colors `line_text` into `regions` (SyntaxHighlighter region starts; a
## region persists until the next region key). Returns nothing; `regions`
## is mutated in place.
func _highlight_line(line_text: String, open_quote: String, regions: Dictionary) -> void:
	var n := line_text.length()
	var i := 0
	while i < n:
		# Inside an open triple-quoted string from a previous line.
		if open_quote != "":
			regions[i] = {"color": COL_STRING}
			var close_at := line_text.find(open_quote.repeat(3), i)
			if close_at < 0:
				return  # whole rest of the line is string; state carries over
			i = close_at + 3
			open_quote = ""
			continue
		var ch := line_text[i]
		# Comment: runs to the end of the line.
		if ch == "#":
			regions[i] = {"color": COL_COMMENT}
			return
		# Strings.
		if ch == '"' or ch == "'":
			var triple := line_text.substr(i, 3) == ch.repeat(3)
			regions[i] = {"color": COL_STRING}
			if triple:
				i += 3
				var close_at := line_text.find(ch.repeat(3), i)
				if close_at < 0:
					# No closing triple on this line: state carries over.
					open_quote = ch
					return
				i = close_at + 3
				continue
			# Single-line string with `\` escapes.
			i += 1
			while i < n:
				if line_text[i] == "\\":
					i += 1
				elif line_text[i] == ch:
					i += 1
					break
				i += 1
			continue
		# Identifiers: keywords, builtins, self/cls, function names.
		if _is_ident_char(ch):
			var start := i
			while i < n and _is_ident_char(line_text[i]):
				i += 1
			var word := line_text.substr(start, i - start)
			if word == "def" or word == "class":
				regions[start] = {"color": COL_KEYWORD}
				# Color the name that follows (skip whitespace).
				var j := i
				while j < n and (line_text[j] == " " or line_text[j] == "\t"):
					j += 1
				if j < n and _is_ident_char(line_text[j]):
					var name_start := j
					while j < n and _is_ident_char(line_text[j]):
						j += 1
					regions[name_start] = {"color": COL_FUNC}
					i = j
			elif KEYWORDS.has(word):
				regions[start] = {"color": COL_KEYWORD}
			elif BUILTINS.has(word) or word == "self" or word == "cls":
				regions[start] = {"color": COL_BUILTIN}
			continue
		# Decorators: color `@` and the full name.
		if ch == "@":
			regions[i] = {"color": COL_DECORATOR}
			i += 1
			if i < n and _is_ident_char(line_text[i]):
				regions[i] = {"color": COL_DECORATOR}
				while i < n and _is_ident_char(line_text[i]):
					i += 1
			continue
		# Numbers (full literal, see _scan_number).
		if ch.is_valid_int() or (ch == "." and i + 1 < n and line_text[i + 1].is_valid_int()):
			regions[i] = {"color": COL_NUMBER}
			i = _scan_number(line_text, i)
			continue
		i += 1

## Scans `line_text` for triple-quote open/close events only, so that
## `_get_line_syntax_highlighting` knows the string state at the start of a
## line. Comments and single-line strings are skipped (a `"""` inside a
## comment is not a string).
func _scan_triple_state(line_text: String, open_quote: String) -> String:
	var n := line_text.length()
	var i := 0
	while i < n:
		if open_quote != "":
			if line_text.substr(i, 3) == open_quote.repeat(3):
				open_quote = ""
				i += 3
			else:
				i += 1
			continue
		var ch := line_text[i]
		if ch == "#":
			return open_quote
		if ch == '"' or ch == "'":
			if line_text.substr(i, 3) == ch.repeat(3):
				open_quote = ch
				i += 3
			else:
				# Single-line string: skip to the closing quote.
				i += 1
				while i < n:
					if line_text[i] == "\\":
						i += 1
					elif line_text[i] == ch:
						i += 1
						break
					i += 1
			continue
		i += 1
	return open_quote

## Advances past a complete number literal starting at `start`; returns the
## index of the first character after the literal.
func _scan_number(line_text: String, start: int) -> int:
	var i := start
	var n := line_text.length()
	# Base prefixes: 0x / 0b / 0o.
	if line_text[i] == "0" and i + 1 < n and line_text[i + 1] in ["x", "X", "b", "B", "o", "O"]:
		i += 2
		while i < n and (line_text[i].is_valid_hex_number() or line_text[i] == "_"):
			i += 1
		return i
	# Decimal / float / exponent.
	while i < n:
		var c := line_text[i]
		if c.is_valid_int() or c == "_":
			i += 1
		elif c == "." and i + 1 < n and line_text[i + 1].is_valid_int():
			i += 1
		elif (c == "e" or c == "E") and i + 1 < n:
			# Exponent only when followed by digits (optionally signed).
			var j := i + 1
			if line_text[j] == "+" or line_text[j] == "-":
				j += 1
			if j < n and line_text[j].is_valid_int():
				i = j + 1
				while i < n and line_text[i].is_valid_int():
					i += 1
			else:
				break
		else:
			break
	return i

func _is_ident_char(c: String) -> bool:
	return c == "_" or c.is_valid_identifier()