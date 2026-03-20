# Field type descriptor constructors for the configuration schema.
#
# These return plain Starlark structs — no Buck2 targets are created here.
# They are evaluated at .bzl load time and used by config_schema() and
# config_instance() macros.

def string_enum_field(values, default, cfg = False, doc = ""):
    """A field constrained to one of a fixed set of string values.

    Args:
        values: List of allowed string values.
        default: The default value (must be in `values`).
        cfg:    If True, this field is emitted as a --cfg=name="value" rustc flag.
        doc:    Human-readable description.
    """
    if default not in values:
        fail("string_enum_field '{}': default '{}' must be one of {}".format(doc or "?", default, values))
    if len(values) < 2:
        fail("string_enum_field must have at least 2 values")
    return struct(
        type = "string_enum",
        values = values,
        default = default,
        cfg = cfg,
        doc = doc,
    )

def bool_field(default = False, cfg = False, doc = ""):
    """A boolean field.

    Args:
        default: Default value (True or False).
        cfg:    If True, emits --cfg=name when the value is True.
        doc:    Human-readable description.
    """
    if type(default) != type(True):
        fail("bool_field: default must be a bool, got {}".format(type(default)))
    return struct(
        type = "bool",
        values = None,
        default = default,
        cfg = cfg,
        doc = doc,
    )

def int_field(default = 0, values = None, doc = ""):
    """An integer field.

    Args:
        default: Default integer value.
        values:  Optional list of allowed integer values. When provided the
                 field is constraint-backed so builds with different configs
                 resolve to the correct value via select().  When omitted the
                 field always takes the default value in generated code.
        doc:     Human-readable description.
    """
    if type(default) != type(0):
        fail("int_field: default must be an int, got {}".format(type(default)))
    if values != None:
        if default not in values:
            fail("int_field: default {} not in values {}".format(default, values))
        for v in values:
            if type(v) != type(0):
                fail("int_field: all values must be ints, got {}".format(type(v)))
    return struct(
        type = "int",
        values = values,
        default = default,
        cfg = False,  # integers are not emitted as --cfg flags
        doc = doc,
    )

def string_list_field(default = [], doc = ""):
    """A list-of-strings field.

    These values are carried in ConfigInstanceInfo for validation and
    inheritance, but are NOT constraint-backed.  Use individual bool_field
    entries (e.g. has_qemu, has_virtio) when you need per-feature conditional
    compilation via --cfg flags.

    Args:
        default: Default list of strings.
        doc:     Human-readable description.
    """
    for v in default:
        if type(v) != type(""):
            fail("string_list_field: all default values must be strings")
    return struct(
        type = "string_list",
        values = None,
        default = list(default),
        cfg = False,
        doc = doc,
    )
