class_name PythonBridgeTypeMapper
extends RefCounted
## Explicit, extensible type mapping table between Godot and Python.
##
## This module is the single source of truth for the `$pb` tags used on the
## wire. The serializer consults it for built-in types and for custom
## registered types. The table is also the basis of the TYP_MAPPING
## documentation.
##
## Custom types can be added at runtime:
##   PythonBridgeTypeMapper.register("mytype", encode_fn, decode_fn)
##
## where `encode_fn(value, chunks: Array) -> Variant` returns the tagged
## JSON representation and `decode_fn(encoded, chunks: Array) -> Variant`
## reconstructs the Godot value.

const TAG := "$pb"

# Built-in tags (see also python/python_bridge/serializer.py)
const T_NULL := "null"
const T_BOOL := "bool"
const T_INT := "int"
const T_FLOAT := "float"
const T_STR := "str"
const T_VEC2 := "vec2"
const T_VEC3 := "vec3"
const T_VEC4 := "vec4"
const T_COLOR := "color"
const T_TRANSFORM3D := "transform3d"
const T_ARR := "arr"
const T_DICT := "dict"
const T_TUPLE := "tuple"
const T_SET := "set"
const T_BYTES := "bytes"
const T_I8 := "i8"
const T_U8 := "u8"
const T_I16 := "i16"
const T_U16 := "u16"
const T_I32 := "i32"
const T_U32 := "u32"
const T_I64 := "i64"
const T_U64 := "u64"
const T_F32 := "f32"
const T_F64 := "f64"
const T_NDARRAY := "ndarray"
const T_IMAGE := "image"
const T_PYOBJECT := "pyobject"
const T_UNSUPPORTED := "unsupported"

## Human-readable mapping table used for documentation and debugging.
## godot_type / python_type are descriptive; tag is the wire identifier.
const MAPPINGS: Array[Dictionary] = [
	{"tag": T_NULL, "godot": "null", "python": "None"},
	{"tag": T_BOOL, "godot": "bool", "python": "bool"},
	{"tag": T_INT, "godot": "int", "python": "int"},
	{"tag": T_FLOAT, "godot": "float", "python": "float"},
	{"tag": T_STR, "godot": "String", "python": "str"},
	{"tag": T_VEC2, "godot": "Vector2", "python": "list[2] (x, y)"},
	{"tag": T_VEC3, "godot": "Vector3", "python": "list[3] (x, y, z)"},
	{"tag": T_VEC4, "godot": "Vector4", "python": "list[4] (x, y, z, w)"},
	{"tag": T_COLOR, "godot": "Color", "python": "list[4] (r, g, b, a)"},
	{"tag": T_TRANSFORM3D, "godot": "Transform3D", "python": "list[12] (basis 9 + origin 3)"},
	{"tag": T_ARR, "godot": "Array", "python": "list"},
	{"tag": T_DICT, "godot": "Dictionary", "python": "dict (str keys)"},
	{"tag": T_TUPLE, "godot": "Array", "python": "tuple"},
	{"tag": T_SET, "godot": "Array", "python": "set / frozenset"},
	{"tag": T_BYTES, "godot": "PackedByteArray", "python": "bytes / bytearray"},
	{"tag": T_I32, "godot": "PackedInt32Array", "python": "numpy int32 / raw buffer"},
	{"tag": T_I64, "godot": "PackedInt64Array", "python": "numpy int64 / raw buffer"},
	{"tag": T_F32, "godot": "PackedFloat32Array", "python": "numpy float32 / raw buffer"},
	{"tag": T_F64, "godot": "PackedFloat64Array", "python": "numpy float64 / raw buffer"},
	{"tag": T_NDARRAY, "godot": "Packed*Array / Array", "python": "numpy.ndarray"},
	{"tag": T_IMAGE, "godot": "Image", "python": "raw pixels + metadata"},
	{"tag": T_PYOBJECT, "godot": "String (repr)", "python": "other object"},
	{"tag": T_UNSUPPORTED, "godot": "null", "python": "unsupported type"},
]

## Registry of custom encode/decode pairs, keyed by tag.
## Entries: { "encode": Callable, "decode": Callable, "class": String }
## where `class` is the Godot class name this encoder handles (optional;
## used to route Object values to their encoder during serialization).
static var _custom: Dictionary = {}

## Registers a custom tag with encode/decode functions.
## `class_name` optionally names the Godot class handled by `encode_fn`;
## when provided, Object values of that class are routed to this encoder.
static func register(tag: String, encode_fn: Callable, decode_fn: Callable, custom_class := "") -> void:
	_custom[tag] = {"encode": encode_fn, "decode": decode_fn, "class": custom_class}

## Returns all currently registered custom tags.
static func custom_tags() -> Array:
	return _custom.keys()

## Unregisters a custom tag. Returns true when the tag existed.
static func unregister(tag: String) -> bool:
	return _custom.erase(tag)

static func has_custom(tag: String) -> bool:
	return _custom.has(tag)

static func custom_encode(tag: String) -> Callable:
	if _custom.has(tag):
		return _custom[tag]["encode"]
	return Callable()

static func custom_decode(tag: String) -> Callable:
	if _custom.has(tag):
		return _custom[tag]["decode"]
	return Callable()

## Returns the tag whose registered class matches `value`, or "" when no
## custom encoder claims this value.
static func tag_for_value(value: Object) -> String:
	var cls := str(value.get_class())
	for tag in _custom.keys():
		if str(_custom[tag].get("class", "")) == cls:
			return tag
	return ""

## Returns the descriptive mapping entry for a tag, or {} when unknown.
static func info_for_tag(tag: String) -> Dictionary:
	for entry in MAPPINGS:
		if entry["tag"] == tag:
			return entry
	return {}