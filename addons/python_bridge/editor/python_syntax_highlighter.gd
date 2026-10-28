class_name PythonBridgeSyntaxHighlighter
extends SyntaxHighlighter
## Python-Syntax-Highlighting für die CodeEdit-Widgets des Docks.
##
## Bewusst klein, aber KORREKT: Godots `SyntaxHighlighter` erwartet ein
## Dictionary "Spalte -> {color}". Diese Farbe gilt ab der Spalte bis zur
## nächsten Region. Die frühere Fassung setzte nur Token-Anfänge und nie einen
## Reset - dadurch blieb nach String/Kommentar/Zahl der restliche Zeilentext
## in der Token-Farbe (das war das "verbuggte" Highlighting).
##
## Regeln hier:
##   - Jede Region bekommt nach ihrem Ende explizit COL_DEFAULT, außer der
##     String/Kommentar reicht bis zum Zeilenende.
##   - Spalte 0 ist immer explizit COL_DEFAULT, damit die Theme-Farbe nicht
##     durchscheint.
##   - Dreifach-Anführungszeichen über mehrere Zeilen: der Zustand wird pro
##     Zeile gecacht (nur Triple-Quotes), statt ihn für jede Zeile neu aus
##     allen vorherigen Zeilen zu rekonstruieren.
##     `invalidate()` nach jeder Textänderung hält den Cache konsistent.
##
## Die Tokenizer-Funktionen (`highlight_line`, `state_after_line`) sind rein
## und ohne TextEdit aufrufbar - genau das nutzt die Headless-Test-Suite.

const KEYWORDS := [
	"and", "as", "assert", "async", "await", "break", "class", "continue",
	"def", "del", "elif", "else", "except", "False", "finally", "for",
	"from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal",
	"not", "or", "pass", "raise", "return", "True", "try", "while", "with",
	"yield", "match", "case",
]

const BUILTINS := [
	"abs", "all", "any", "bin", "bool", "bytearray", "bytes", "callable", "chr",
	"classmethod", "compile", "complex", "delattr", "dict", "dir", "divmod",
	"enumerate", "eval", "exec", "filter", "float", "format", "frozenset",
	"getattr", "globals", "hasattr", "hash", "help", "hex", "id", "input",
	"int", "isinstance", "issubclass", "iter", "len", "list", "locals", "map",
	"max", "memoryview", "min", "next", "object", "oct", "open", "ord", "pow",
	"print", "property", "range", "repr", "reversed", "round", "set", "setattr",
	"slice", "sorted", "staticmethod", "str", "sum", "super", "tuple", "type",
	"vars", "zip",
]

const COL_DEFAULT := Color(0.87, 0.88, 0.90)
const COL_KEYWORD := Color(0.78, 0.48, 0.98)
const COL_BUILTIN := Color(0.42, 0.65, 0.98)
const COL_DEF_NAME := Color(0.96, 0.84, 0.52)
const COL_CALL := Color(0.58, 0.84, 0.96)
const COL_STRING := Color(0.72, 0.92, 0.58)
const COL_COMMENT := Color(0.52, 0.56, 0.62)
const COL_NUMBER := Color(0.95, 0.75, 0.45)
const COL_DECORATOR := Color(0.45, 0.85, 0.80)
const COL_SELF := Color(0.98, 0.62, 0.55)

## Cache: Zeilenindex -> {"text": String, "open": String}.
var _states: Array = []

# ------------------------------------------------------------------ API
## Nach jeder Textänderung aufrufen (das Dock macht das in `text_changed`).
## Ohne Reset würden mehrzeilige Strings nach Edits falsch weiterlaufen.
func invalidate() -> void:
	_states.clear()

## Reiner Tokenizer: "Spalte -> {color}" für EINE Zeile.
## `open_quote` ist "" oder ein offener Triple-Quote-String (' oder ").
func highlight_line(line_text: String, open_quote := "") -> Dictionary:
	var n := line_text.length()
	var regions := {0: {"color": COL_DEFAULT}}
	var i := 0
	while i < n:
		# Fortsetzung eines mehrzeiligen Triple-Quote-Strings.
		if open_quote != "":
			_set_color(regions, i, COL_STRING, n)
			var close_at := line_text.find(open_quote, i)
			if close_at < 0:
				return regions  # String läuft über das Zeilenende hinaus
			i = close_at + open_quote.length()
			open_quote = ""
			_set_color(regions, i, COL_DEFAULT, n)
			continue

		var ch := line_text.substr(i, 1)

		# Kommentar: bis Zeilenende.
		if ch == "#":
			_set_color(regions, i, COL_COMMENT, n)
			return regions

		# Strings (ein- und mehrzeilig).
		if ch == "\"" or ch == "'":
			var quote := ch
			var triple := line_text.substr(i, 3) == quote.repeat(3)
			_set_color(regions, i, COL_STRING, n)
			var j := i + (3 if triple else 1)
			var closed := false
			while j < n:
				if triple:
					if line_text.substr(j, 3) == quote.repeat(3):
						j += 3
						closed = true
						break
					j += 1
				else:
					if line_text.substr(j, 1) == "\\":
						j += 2
						continue
					if line_text.substr(j, 1) == quote:
						j += 1
						closed = true
						break
					j += 1
			if not closed:
				if triple:
					open_quote = quote.repeat(3)
				return regions
			i = j
			_set_color(regions, i, COL_DEFAULT, n)
			continue

		# Decorator: @name, @pkg.mod.name
		if ch == "@":
			_set_color(regions, i, COL_DECORATOR, n)
			i += 1
			while i < n and (_is_ident_char(line_text.substr(i, 1)) or line_text.substr(i, 1) == "."):
				i += 1
			_set_color(regions, i, COL_DEFAULT, n)
			continue

		# Zahlen (vollständiges Literal).
		if _is_digit(ch) or (ch == "." and i + 1 < n and _is_digit(line_text.substr(i + 1, 1))):
			var start := i
			i = _scan_number(line_text, i)
			_set_color(regions, start, COL_NUMBER, n)
			_set_color(regions, i, COL_DEFAULT, n)
			continue

		# Bezeichner: Keywords, Builtins, def/class-Namen, Aufrufe.
		if _is_ident_start(ch):
			var start := i
			while i < n and _is_ident_char(line_text.substr(i, 1)):
				i += 1
			var word := line_text.substr(start, i - start)
			if KEYWORDS.has(word):
				_set_color(regions, start, COL_KEYWORD, n)
				if word == "def" or word == "class":
					var k := i
					while k < n and (line_text.substr(k, 1) == " " or line_text.substr(k, 1) == "\t"):
						k += 1
					if k < n and _is_ident_char(line_text.substr(k, 1)):
						var name_start := k
						while k < n and _is_ident_char(line_text.substr(k, 1)):
							k += 1
						_set_color(regions, name_start, COL_DEF_NAME, n)
						i = k
			elif word == "self" or word == "cls":
				_set_color(regions, start, COL_SELF, n)
			elif BUILTINS.has(word):
				_set_color(regions, start, COL_BUILTIN, n)
			elif _followed_by_paren(line_text, i):
				_set_color(regions, start, COL_CALL, n)
			_set_color(regions, i, COL_DEFAULT, n)
			continue

		i += 1
	return regions

## Offener Triple-Quote-String am ENDE dieser Zeile ("" = keiner).
## Kommentare und einzeilige Strings werden übersprungen, damit `"""` in einem
## Kommentar oder String keinen mehrzeiligen String startet.
func state_after_line(line_text: String, open_quote := "") -> String:
	var n := line_text.length()
	var i := 0
	while i < n:
		if open_quote != "":
			if line_text.substr(i, 3) == open_quote:
				open_quote = ""
				i += 3
			else:
				i += 1
			continue
		var ch := line_text.substr(i, 1)
		if ch == "#":
			return open_quote
		if ch == "\"" or ch == "'":
			if line_text.substr(i, 3) == ch.repeat(3):
				open_quote = ch.repeat(3)
				i += 3
			else:
				i += 1
				while i < n:
					if line_text.substr(i, 1) == "\\":
						i += 2
						continue
					if line_text.substr(i, 1) == ch:
						i += 1
						break
					i += 1
			continue
		i += 1
	return open_quote

# ------------------------------------------------------------------ SyntaxHighlighter
func _get_line_syntax_highlighting(line: int) -> Dictionary:
	var text := get_text_edit()
	if text == null or line < 0 or line >= text.get_line_count():
		return {}
	return highlight_line(text.get_line(line), _state_before(text, line))

## Offener Triple-Quote-Zustand am Anfang von `line`. Nutzt den Zeilen-Cache;
## ab der ersten nicht mehr passenden Zeile wird neu gescannt und der stale
## Rest verworfen (Änderung in Zeile N invalidiert N und alles danach).
func _state_before(text: TextEdit, line: int) -> String:
	var open := ""
	for i in line:
		var line_text := text.get_line(i)
		var cached: Variant = _states[i] if i < _states.size() else null
		if cached is Dictionary and str(cached.get("text", "")) == line_text:
			open = str(cached.get("open", ""))
			continue
		open = state_after_line(line_text, open)
		var entry := {"text": line_text, "open": open}
		if i < _states.size():
			_states[i] = entry
			_states.resize(i + 1)
		else:
			_states.append(entry)
	return open

# ------------------------------------------------------------------ Intern
func _set_color(regions: Dictionary, index: int, color: Color, line_length: int) -> void:
	# Spalte == Zeilenlänge ist kein gültiger Startpunkt; die Farbe bis zum
	# Zeilenende kommt dann von der letzten gültigen Region.
	if index >= 0 and index < line_length:
		regions[index] = {"color": color}

func _scan_number(line_text: String, start: int) -> int:
	var n := line_text.length()
	var i := start
	# Basisliterale: 0x/0X, 0b/0B, 0o/0O mit dem jeweiligen Ziffernsatz.
	if line_text.substr(i, 1) == "0" and i + 1 < n:
		var base := line_text.substr(i + 1, 1).to_lower()
		if base == "x" or base == "b" or base == "o":
			i += 2
			while i < n and (_digit_for_base(line_text.substr(i, 1), base) or line_text.substr(i, 1) == "_"):
				i += 1
			return i
	# Dezimal / Float / Exponent.
	while i < n:
		var c := line_text.substr(i, 1)
		if _is_digit(c) or c == "_":
			i += 1
		elif c == "." and i + 1 < n and _is_digit(line_text.substr(i + 1, 1)):
			i += 1
		elif (c == "e" or c == "E") and i + 1 < n:
			var j := i + 1
			var sign := line_text.substr(j, 1)
			if sign == "+" or sign == "-":
				j += 1
			if j < n and _is_digit(line_text.substr(j, 1)):
				i = j
				while i < n and _is_digit(line_text.substr(i, 1)):
					i += 1
			else:
				break
		else:
			break
	# Komplexe Literale: 1j / 1.5J
	var tail := line_text.substr(i, 1)
	if tail == "j" or tail == "J":
		i += 1
	return i

func _digit_for_base(c: String, base: String) -> bool:
	if base == "b":
		return c == "0" or c == "1"
	if base == "o":
		return c >= "0" and c <= "7"
	return c.is_valid_hex_number()

func _followed_by_paren(line_text: String, index: int) -> bool:
	var n := line_text.length()
	var j := index
	while j < n and (line_text.substr(j, 1) == " " or line_text.substr(j, 1) == "\t"):
		j += 1
	return j < n and line_text.substr(j, 1) == "("

func _is_ident_start(c: String) -> bool:
	return c == "_" or _is_letter(c)

func _is_ident_char(c: String) -> bool:
	return c == "_" or _is_letter(c) or _is_digit(c)

func _is_letter(c: String) -> bool:
	# Buchstabe (inkl. Unicode): Groß-/Kleinschreibung unterscheidet sich.
	return c != "" and c.to_lower() != c.to_upper()

func _is_digit(c: String) -> bool:
	return c != "" and c.is_valid_int()
