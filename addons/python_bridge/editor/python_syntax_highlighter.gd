class_name PythonBridgeSyntaxHighlighter
extends SyntaxHighlighter
## Lightweight Python syntax highlighter for the bridge's CodeEdit.
## Uses only documented Godot 4 APIs (SyntaxHighlighter virtual method
## _get_line_syntax_highlighting). This is a presentation helper for the
## editor dock; it is not part of the runtime core.

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

const COL_KEYWORD := Color(0.82, 0.4, 0.98)
const COL_BUILTIN := Color(0.35, 0.65, 0.98)
const COL_STRING := Color(0.72, 0.92, 0.58)
const COL_COMMENT := Color(0.55, 0.55, 0.55)
const COL_NUMBER := Color(0.95, 0.8, 0.4)
const COL_DECORATOR := Color(0.45, 0.85, 0.8)
const COL_DEFAULT := Color(0.9, 0.9, 0.9)

func _get_line_syntax_highlighting(line: int) -> Dictionary:
	var text := get_text_edit()
	var line_text := text.get_line(line)
	var regions := {}
	var i := 0
	var in_string := ""
	while i < line_text.length():
		var ch := line_text[i]
		# Comments
		if ch == "#":
			regions[i] = {"color": COL_COMMENT}
			return regions
		# Strings (single or triple, naive but adequate for editing)
		if ch == '"' or ch == "'":
			var quote := ch
			var triple := false
			if i + 2 < line_text.length() and line_text[i + 1] == quote and line_text[i + 2] == quote:
				triple = true
			regions[i] = {"color": COL_STRING}
			if triple:
				i += 3
				while i < line_text.length() and not (line_text[i] == quote
						and i + 2 < line_text.length()
						and line_text[i + 1] == quote and line_text[i + 2] == quote):
					i += 1
				i += 3
			else:
				i += 1
				while i < line_text.length() and line_text[i] != quote:
					if line_text[i] == "\\" and i + 1 < line_text.length():
						i += 1
					i += 1
				i += 1
			continue
		# Identifiers / keywords / builtins / decorators
		if _is_ident_char(ch):
			var start := i
			while i < line_text.length() and _is_ident_char(line_text[i]):
				i += 1
			var word := line_text.substr(start, i - start)
			if KEYWORDS.has(word):
				regions[start] = {"color": COL_KEYWORD}
			elif BUILTINS.has(word):
				regions[start] = {"color": COL_BUILTIN}
			continue
		# Decorators (@decorator)
		if ch == "@":
			regions[i] = {"color": COL_DECORATOR}
		# Numbers
		if ch.is_valid_int() or (ch == "." and i + 1 < line_text.length()
				and line_text[i + 1].is_valid_int()):
			regions[i] = {"color": COL_NUMBER}
		i += 1
	return regions

func _is_ident_char(c: String) -> bool:
	return c == "_" or c.is_valid_identifier()