## A JSON document whose shape is not known in advance, read and written
## byte for byte the same way every time: objects are written with their keys
## sorted by their UTF-8 bytes, so equal values always have equal text.
JsonValue := [Null, Boolean(Bool), Number(Str), Text(Str), Array(List(JsonValue)), Object(List({ key : Str, value : JsonValue }))].{

	## Read one JSON value. A repeated object key is an error.
	parse : Str -> Try(JsonValue, Str)
	parse = |source| {
		parsed = value(skip(Str.to_utf8(source)), 0)?
		if skip(parsed.rest).is_empty() {
			Ok(parsed.value)
		} else {
			Err("trailing characters after the JSON value")
		}
	}

	## Two-space indented text with sorted keys and a final newline.
	render : JsonValue -> Str
	render = |json| "${pretty(json, 0)}\n"

	## One line with sorted keys and no spaces, without a final newline.
	compact : JsonValue -> Str
	compact = |json|
		match json {
			Array(items) => "[${Str.join_with(items.map(JsonValue.compact), ",")}]"
			Object(fields) => "{${Str.join_with(sorted(fields).map(|field| "${quote(field.key)}:${JsonValue.compact(field.value)}"), ",")}}"
			_ => scalar(json)
		}

	## One line with sorted keys, a space after each `,` and `:`.
	spaced : JsonValue -> Str
	spaced = |json|
		match json {
			Array(items) => "[${Str.join_with(items.map(JsonValue.spaced), ", ")}]"
			Object(fields) => "{${Str.join_with(sorted(fields).map(|field| "${quote(field.key)}: ${JsonValue.spaced(field.value)}"), ", ")}}"
			_ => scalar(json)
		}

	## An object from its fields, in any order.
	object : List((Str, JsonValue)) -> JsonValue
	object = |pairs| Object(pairs.map(|(key, item)| { key, value: item }))

	text : Str -> JsonValue
	text = |s| Text(s)

	number : I64 -> JsonValue
	number = |n| Number(n.to_str())

	texts : List(Str) -> JsonValue
	texts = |items| Array(items.map(|s| Text(s)))

	array : List(JsonValue) -> JsonValue
	array = |items| Array(items)

	## The value of an object's field.
	get : JsonValue, Str -> Try(JsonValue, Str)
	get = |json, name|
		match json {
			Object(fields) =>
				match fields.find_first(|field| field.key == name) {
					Ok(field) => Ok(field.value)
					Err(NotFound) => Err("missing JSON field ${name}")
				}
			_ => Err("expected a JSON object with field ${name}")
		}

	## The string value of an object's field.
	get_text : JsonValue, Str -> Try(Str, Str)
	get_text = |json, name|
		match JsonValue.get(json, name)? {
			Text(s) => Ok(s)
			_ => Err("JSON field ${name} must be a string")
		}

	## The fields of an object, in the order they were written.
	fields : JsonValue -> Try(List({ key : Str, value : JsonValue }), Str)
	fields = |json|
		match json {
			Object(found) => Ok(found)
			_ => Err("expected a JSON object")
		}

	## The keys of an object, in the order they were written.
	keys : JsonValue -> List(Str)
	keys = |json|
		match json {
			Object(found) => found.map(|field| field.key)
			_ => []
		}

	## The strings of an array of strings.
	strings : JsonValue -> Try(List(Str), Str)
	strings = |json|
		match json {
			Array(items) =>
				items.fold(
					Ok([]),
					|acc, item|
						match (acc, item) {
							(Ok(found), Text(s)) => Ok(found.append(s))
							(Err(e), _) => Err(e)
							_ => Err("expected an array of strings")
						},
				)
			_ => Err("expected an array of strings")
		}

	## The value of a whole number.
	integer : JsonValue -> Try(I64, Str)
	integer = |json|
		match json {
			Number(digits) => I64.from_str(digits).map_err(|_| "expected a whole number")
			_ => Err("expected a number")
		}

	## Sort strings by their UTF-8 bytes, which is code point order.
	sort : List(Str) -> List(Str)
	sort = |items| List.sort_with(items, order)

	## Compare strings by their UTF-8 bytes.
	order : Str, Str -> [Before, Same, After]
	order = |a, b| compare(Str.to_utf8(a), Str.to_utf8(b))
}

compare : List(U8), List(U8) -> [Before, Same, After]
compare = |a, b|
	match (a, b) {
		([], []) => Same
		([], _) => Before
		(_, []) => After
		([x, .. as xs], [y, .. as ys]) =>
			if x < y {
				Before
			} else if x > y {
				After
			} else {
				compare(xs, ys)
			}
	}

sorted = |fields| List.sort_with(fields, |a, b| JsonValue.order(a.key, b.key))

pretty : JsonValue, U64 -> Str
pretty = |json, depth| {
	inner = Str.repeat("  ", depth + 1)
	outer = Str.repeat("  ", depth)
	match json {
		Array([]) => "[]"
		Object([]) => "{}"
		Array(items) => "[\n${Str.join_with(items.map(|item| "${inner}${pretty(item, depth + 1)}"), ",\n")}\n${outer}]"
		Object(found) => "{\n${Str.join_with(sorted(found).map(|field| "${inner}${quote(field.key)}: ${pretty(field.value, depth + 1)}"), ",\n")}\n${outer}}"
		_ => scalar(json)
	}
}

scalar : JsonValue -> Str
scalar = |json|
	match json {
		Null => "null"
		Boolean(b) => if (b) "true" else "false"
		Number(digits) => digits
		Text(s) => quote(s)
		_ => ""
	}

quote : Str -> Str
quote = |s| "\"${Str.from_utf8_lossy(escape(Str.to_utf8(s), []))}\""

escape : List(U8), List(U8) -> List(U8)
escape = |bytes, out|
	match bytes {
		[] => out
		[byte, .. as rest] => {
			next =
				if byte == '"' {
					out.concat(['\\', '"'])
				} else if byte == '\\' {
					out.concat(['\\', '\\'])
				} else if byte == '\n' {
					out.concat(['\\', 'n'])
				} else if byte == '\r' {
					out.concat(['\\', 'r'])
				} else if byte == '\t' {
					out.concat(['\\', 't'])
				} else if byte == 8 {
					out.concat(['\\', 'b'])
				} else if byte == 12 {
					out.concat(['\\', 'f'])
				} else if byte < 32 {
					out.concat(Str.to_utf8("\\u00")).append(hex_digit(byte // 16)).append(hex_digit(byte % 16))
				} else {
					out.append(byte)
				}
			escape(rest, next)
		}
	}

hex_digit : U8 -> U8
hex_digit = |n| if (n < 10) '0' + n else 'a' + n - 10

Parsed(a) : { value : a, rest : List(U8) }

skip : List(U8) -> List(U8)
skip = |bytes|
	match bytes {
		[' ', .. as rest] => skip(rest)
		['\n', .. as rest] => skip(rest)
		['\r', .. as rest] => skip(rest)
		['\t', .. as rest] => skip(rest)
		_ => bytes
	}

value : List(U8), U64 -> Try(Parsed(JsonValue), Str)
value = |bytes, depth| {
	if depth > 64 {
		return Err("JSON nests too deeply")
	}
	match bytes {
		['{', .. as rest] => object_fields(skip(rest), depth, [], Bool.True)
		['[', .. as rest] => array_items(skip(rest), depth, [], Bool.True)
		['"', .. as rest] => {
			parsed = string(rest, [])?
			Ok({ value: Text(parsed.value), rest: parsed.rest })
		}
		['t', 'r', 'u', 'e', .. as rest] => Ok({ value: Boolean(Bool.True), rest })
		['f', 'a', 'l', 's', 'e', .. as rest] => Ok({ value: Boolean(Bool.False), rest })
		['n', 'u', 'l', 'l', .. as rest] => Ok({ value: Null, rest })
		_ => {
			digits = number_bytes(bytes, [])
			if digits.is_empty() or !valid_number(digits) {
				Err("invalid JSON value")
			} else {
				Ok({ value: Number(Str.from_utf8_lossy(digits)), rest: bytes.drop_first(digits.len()) })
			}
		}
	}
}

number_bytes : List(U8), List(U8) -> List(U8)
number_bytes = |bytes, out|
	match bytes {
		[byte, .. as rest] if (byte >= '0' and byte <= '9') or byte == '-' or byte == '+' or byte == '.' or byte == 'e' or byte == 'E' => number_bytes(rest, out.append(byte))
		_ => out
	}

# The JSON number grammar: -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
valid_number : List(U8) -> Bool
valid_number = |bytes| {
	unsigned = match bytes {
		['-', .. as rest] => rest
		_ => bytes
	}
	after_int = match unsigned {
		['0', .. as rest] => Ok(rest)
		[d, .. as rest] if d >= '1' and d <= '9' => Ok(drop_digits(rest))
		_ => Err({})
	}
	match after_int {
		Err(_) => Bool.False
		Ok(rest) => {
			after_fraction = match rest {
				['.', d, .. as more] if is_digit(d) => drop_digits(more)
				['.', ..] => ['x']
				_ => rest
			}
			after_exponent = match after_fraction {
				['e', .. as more] => exponent(more)
				['E', .. as more] => exponent(more)
				_ => after_fraction
			}
			after_exponent.is_empty()
		}
	}
}

exponent = |bytes| {
	unsigned = match bytes {
		['+', .. as rest] => rest
		['-', .. as rest] => rest
		_ => bytes
	}
	match unsigned {
		[d, .. as rest] if is_digit(d) => drop_digits(rest)
		_ => ['x']
	}
}

is_digit = |byte| byte >= '0' and byte <= '9'

drop_digits : List(U8) -> List(U8)
drop_digits = |bytes|
	match bytes {
		[d, .. as rest] if is_digit(d) => drop_digits(rest)
		_ => bytes
	}

string : List(U8), List(U8) -> Try(Parsed(Str), Str)
string = |bytes, out|
	match bytes {
		[] => Err("unterminated JSON string")
		['"', .. as rest] =>
			match Str.from_utf8(out) {
				Ok(s) => Ok({ value: s, rest })
				Err(_) => Err("JSON string is not UTF-8")
			}
		['\\', '"', .. as rest] => string(rest, out.append('"'))
		['\\', '\\', .. as rest] => string(rest, out.append('\\'))
		['\\', '/', .. as rest] => string(rest, out.append('/'))
		['\\', 'b', .. as rest] => string(rest, out.append(8))
		['\\', 'f', .. as rest] => string(rest, out.append(12))
		['\\', 'n', .. as rest] => string(rest, out.append('\n'))
		['\\', 'r', .. as rest] => string(rest, out.append('\r'))
		['\\', 't', .. as rest] => string(rest, out.append('\t'))
		['\\', 'u', a, b, c, d, '\\', 'u', e, f, g, h, .. as rest] if is_high(hex4(a, b, c, d)) and is_low(hex4(e, f, g, h)) => {
			high = hex4(a, b, c, d) ?? 0
			low = hex4(e, f, g, h) ?? 0
			string(rest, utf8(out, 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)))
		}
		['\\', 'u', a, b, c, d, .. as rest] =>
			match hex4(a, b, c, d) {
				Ok(code) if code < 0xD800 or code > 0xDFFF => string(rest, utf8(out, code))
				_ => Err("invalid JSON \\u escape")
			}
		['\\', ..] => Err("invalid JSON escape")
		[byte, ..] if byte < 32 => Err("control character in JSON string")
		[byte, .. as rest] => string(rest, out.append(byte))
	}

is_high = |code|
	match code {
		Ok(c) => c >= 0xD800 and c <= 0xDBFF
		Err(_) => Bool.False
	}

is_low = |code|
	match code {
		Ok(c) => c >= 0xDC00 and c <= 0xDFFF
		Err(_) => Bool.False
	}

hex4 : U8, U8, U8, U8 -> Try(U32, [BadHex])
hex4 = |a, b, c, d| Ok((((hex(a)? * 16) + hex(b)?) * 16 + hex(c)?) * 16 + hex(d)?)

hex : U8 -> Try(U32, [BadHex])
hex = |byte|
	if byte >= '0' and byte <= '9' {
		Ok((byte - '0').to_u32())
	} else if byte >= 'a' and byte <= 'f' {
		Ok((byte - 'a' + 10).to_u32())
	} else if byte >= 'A' and byte <= 'F' {
		Ok((byte - 'A' + 10).to_u32())
	} else {
		Err(BadHex)
	}

utf8 : List(U8), U32 -> List(U8)
utf8 = |out, code|
	if code < 0x80 {
		out.append(low_byte(code))
	} else if code < 0x800 {
		out.append(low_byte(0xC0 + code // 64)).append(low_byte(0x80 + code % 64))
	} else if code < 0x10000 {
		out.append(low_byte(0xE0 + code // 4096)).append(low_byte(0x80 + (code // 64) % 64)).append(low_byte(0x80 + code % 64))
	} else {
		out.append(low_byte(0xF0 + code // 262144)).append(low_byte(0x80 + (code // 4096) % 64)).append(low_byte(0x80 + (code // 64) % 64)).append(low_byte(0x80 + code % 64))
	}

low_byte : U32 -> U8
low_byte = |n| U8.from_str((n % 256).to_str()) ?? 0

array_items : List(U8), U64, List(JsonValue), Bool -> Try(Parsed(JsonValue), Str)
array_items = |bytes, depth, items, first|
	match bytes {
		[']', .. as rest] if first => Ok({ value: Array(items), rest })
		_ => {
			parsed = value(skip(bytes), depth + 1)?
			match skip(parsed.rest) {
				[',', .. as rest] => array_items(skip(rest), depth, items.append(parsed.value), Bool.False)
				[']', .. as rest] => Ok({ value: Array(items.append(parsed.value)), rest })
				_ => Err("expected , or ] in JSON array")
			}
		}
	}

object_fields : List(U8), U64, List({ key : Str, value : JsonValue }), Bool -> Try(Parsed(JsonValue), Str)
object_fields = |bytes, depth, found, first|
	match bytes {
		['}', .. as rest] if first => Ok({ value: Object(found), rest })
		['"', .. as rest] => {
			key = string(rest, [])?
			if found.any(|field| field.key == key.value) {
				return Err("repeated JSON key ${key.value}")
			}
			match skip(key.rest) {
				[':', .. as after] => {
					parsed = value(skip(after), depth + 1)?
					next = found.append({ key: key.value, value: parsed.value })
					match skip(parsed.rest) {
						[',', .. as more] => object_fields(skip(more), depth, next, Bool.False)
						['}', .. as more] => Ok({ value: Object(next), rest: more })
						_ => Err("expected , or } in JSON object")
					}
				}
				_ => Err("expected : in JSON object")
			}
		}
		_ => Err("expected a key in JSON object")
	}

sample = JsonValue.object([("b", JsonValue.texts(["x", "y"])), ("a", JsonValue.number(1)), ("c", JsonValue.object([])), ("d", JsonValue.array([]))])

expect JsonValue.render(sample) == "{\n  \"a\": 1,\n  \"b\": [\n    \"x\",\n    \"y\"\n  ],\n  \"c\": {},\n  \"d\": []\n}\n"
expect JsonValue.compact(sample) == "{\"a\":1,\"b\":[\"x\",\"y\"],\"c\":{},\"d\":[]}"
expect JsonValue.parse(JsonValue.render(sample)).map_ok(JsonValue.compact) == Ok(JsonValue.compact(sample))
expect JsonValue.parse("{\"z\": [1, -2.5e3, true, false, null], \"a\": \"q\\\"\\n\\u00e9\\ud83d\\ude00\"}").map_ok(JsonValue.compact) == Ok("{\"a\":\"q\\\"\\né😀\",\"z\":[1,-2.5e3,true,false,null]}")
expect JsonValue.compact(JsonValue.text("tab\tbell\u(0007)")) == "\"tab\\tbell\\u0007\""
expect JsonValue.parse("{\"a\": 1, \"a\": 2}").is_err()
expect JsonValue.parse("[1,]").is_err() and JsonValue.parse("01").is_err() and JsonValue.parse("{} x").is_err() and JsonValue.parse("\"\\ud800\"").is_err()
expect JsonValue.sort(["b", "B", "a", "_"]) == ["B", "_", "a", "b"]
number_field = |source| {
	json = JsonValue.parse(source)?
	JsonValue.integer(JsonValue.get(json, "n")?)
}

expect number_field("{\"n\": 42}") == Ok(42)
expect JsonValue.spaced(sample) == "{\"a\": 1, \"b\": [\"x\", \"y\"], \"c\": {}, \"d\": []}"
