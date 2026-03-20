# Public API for the configuration system.
#
# Macros exported from this file:
#
#   config_schema(name, visibility)
#       Called ONCE in //config/BUCK.  Creates the constraint targets that
#       back cfg-enabled schema fields.
#
#   config_instance(name, values, parent, visibility)
#       Called in configs/BUCK for each named configuration.
#       Validates types, merges parent values, and creates a target that
#       provides PlatformInfo + ConfigInstanceInfo.
#
#   config_codegen(name, visibility)
#       Creates a rule target whose output is a generated config.rs file.
#       Attrs use select() so the generated constants match whichever
#       --target-platforms is active at build time.
#
#   schema_rustc_flags_select()
#       Returns a list of select() expressions suitable for the rustc_flags
#       attribute of rust_library / rust_binary / system_rust_toolchain.
#       Resolves --cfg flags from the active target platform's constraints.

load(":rules.bzl", "config_system_rules")
load(":schema.bzl", "CONFIG_SCHEMA")

# The package that owns the schema's constraint targets.
# Must match the package where config_schema() is called (//config/BUCK).
_SCHEMA_PKG = "//config"
_SCHEMA_NAME = "schema"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _constraint_label(field_name, value):
    """Return the constraint-value subtarget label for a given field + value."""
    return "{0}:{1}__{2}[{3}]".format(
        _SCHEMA_PKG,
        _SCHEMA_NAME,
        field_name,
        value,
    )

def _validate_and_split(values):
    """Validate all values against CONFIG_SCHEMA and split by type.

    Returns (str_values, bool_values, int_values, list_values).
    Fails fast with a helpful message if any value is the wrong type or
    out of range.
    """
    str_values = {}
    bool_values = {}
    int_values = {}
    list_values = {}

    for field_name, field in CONFIG_SCHEMA.items():
        if field_name not in values:
            continue
        val = values[field_name]

        if field.type == "string_enum":
            if type(val) != type(""):
                fail("config field '{}': expected str, got {}".format(field_name, type(val)))
            if val not in field.values:
                fail("config field '{}': '{}' not in allowed values {}".format(
                    field_name, val, field.values,
                ))
            str_values[field_name] = val

        elif field.type == "bool":
            if type(val) != type(True):
                fail("config field '{}': expected bool, got {}".format(field_name, type(val)))
            bool_values[field_name] = val

        elif field.type == "int":
            if type(val) != type(0):
                fail("config field '{}': expected int, got {}".format(field_name, type(val)))
            if field.values != None and val not in field.values:
                fail("config field '{}': {} not in allowed values {}".format(
                    field_name, val, field.values,
                ))
            int_values[field_name] = val

        elif field.type == "string_list":
            if type(val) != type([]):
                fail("config field '{}': expected list, got {}".format(field_name, type(val)))
            for item in val:
                if type(item) != type(""):
                    fail("config field '{}': list items must be strings".format(field_name))
            list_values[field_name] = val

        else:
            fail("Unknown field type '{}' for field '{}'".format(field.type, field_name))

    for k in values.keys():
        if k not in CONFIG_SCHEMA:
            fail("config: unknown field '{}' (not in schema)".format(k))

    return (str_values, bool_values, int_values, list_values)

def _merge_with_defaults(str_values, bool_values, int_values, list_values):
    """Fill in schema defaults for any field not yet present."""
    for field_name, field in CONFIG_SCHEMA.items():
        if field.type == "string_enum" and field_name not in str_values:
            str_values[field_name] = field.default
        elif field.type == "bool" and field_name not in bool_values:
            bool_values[field_name] = field.default
        elif field.type == "int" and field_name not in int_values:
            int_values[field_name] = field.default
        elif field.type == "string_list" and field_name not in list_values:
            list_values[field_name] = list(field.default)
    return (str_values, bool_values, int_values, list_values)

def _compute_constraint_deps(str_values, bool_values, int_values):
    """Return the list of constraint-value dep labels for cfg-enabled fields."""
    deps = []
    for field_name, field in CONFIG_SCHEMA.items():
        if field.type == "string_enum" and field.cfg:
            deps.append(_constraint_label(field_name, str_values[field_name]))
        elif field.type == "bool" and field.cfg:
            deps.append(_constraint_label(
                field_name,
                "true" if bool_values[field_name] else "false",
            ))
        elif field.type == "int" and field.values != None:
            deps.append(_constraint_label(field_name, str(int_values[field_name])))
    return deps

# ---------------------------------------------------------------------------
# config_schema()
# ---------------------------------------------------------------------------

def config_schema(name, visibility = ["PUBLIC"]):
    """Create the constraint targets that back the configuration schema.

    Must be called EXACTLY ONCE, in //config/BUCK.

    For every cfg-enabled string_enum / bool field and every int field with
    a `values` list, a native constraint() target is created.  These targets
    are the foundation of the select()-based platform resolution.
    """
    for field_name, field in CONFIG_SCHEMA.items():
        constraint_name = name + "__" + field_name

        if field.type == "string_enum" and field.cfg:
            native.constraint(
                name = constraint_name,
                values = field.values,
                default = field.default,
                visibility = visibility,
            )

        elif field.type == "bool" and field.cfg:
            native.constraint(
                name = constraint_name,
                values = ["true", "false"],
                default = "true" if field.default else "false",
                visibility = visibility,
            )

        elif field.type == "int" and field.values != None:
            native.constraint(
                name = constraint_name,
                values = [str(v) for v in field.values],
                default = str(field.default),
                visibility = visibility,
            )

# ---------------------------------------------------------------------------
# config_instance()
# ---------------------------------------------------------------------------

def config_instance(name, values, parent = None, visibility = ["PUBLIC"]):
    """Declare a named configuration instance.

    Creates a single Buck2 target that provides both PlatformInfo (so it can
    be used as --target-platforms or a modifier alias) and ConfigInstanceInfo
    (so code-gen rules can read the typed values).

    Args:
        name:       Target name (e.g. "riscv64-qemu").
        values:     Dict of field_name -> value overrides.  Any field not
                    listed here is inherited from `parent` or falls back to
                    the schema default.
        parent:     Optional Starlark dict of parent values (the `values`
                    dict of another config_instance call).  Merged before
                    applying `values`.  This is a plain dict, not a target
                    label, so merging happens at parse time.
        visibility: Buck2 visibility list.

    Example:
        _BASE = {"arch": "x86_64", "build_mode": "debug", ...}
        config_instance(name = "base", values = _BASE)
        config_instance(
            name = "riscv64-qemu",
            parent = _BASE,
            values = {"arch": "riscv64", "heap_size": 131072, "has_qemu": True},
        )
    """
    merged_raw = {}
    if parent != None:
        merged_raw.update(parent)
    merged_raw.update(values)

    (str_v, bool_v, int_v, list_v) = _validate_and_split(merged_raw)
    (str_v, bool_v, int_v, list_v) = _merge_with_defaults(str_v, bool_v, int_v, list_v)
    constraint_deps = _compute_constraint_deps(str_v, bool_v, int_v)

    config_system_rules.config_instance(
        name = name,
        str_values = str_v,
        bool_values = bool_v,
        int_values = int_v,
        list_values = list_v,
        constraint_value_deps = constraint_deps,
        visibility = visibility,
    )

# ---------------------------------------------------------------------------
# config_codegen()
# ---------------------------------------------------------------------------

def config_codegen(name, visibility = ["PUBLIC"]):
    """Create a target that generates config.rs from the active platform.

    The generated file contains pub const declarations for every schema field.
    Because the rule's attrs use select() defaults, the resolved values
    automatically match whichever --target-platforms is active at build time.

    Usage in a BUCK file:
        config_codegen(name = "my_config_gen")
        rust_library(
            name = "my_config",
            srcs = [":my_config_gen"],
            crate_root = ":my_config_gen",
            edition = "2021",
        )

    Then in Rust:
        extern crate my_config;
        println!("{}", my_config::ARCH);
    """
    config_system_rules.config_codegen(
        name = name,
        visibility = visibility,
    )

# ---------------------------------------------------------------------------
# schema_rustc_flags_select()
# ---------------------------------------------------------------------------

def schema_rustc_flags_select():
    """Return select() expressions that emit --cfg flags for the active config.

    Add the return value to the rustc_flags attribute of rust_library,
    rust_binary, or system_rust_toolchain so that every Rust target compiled
    in a given configuration gets the right conditional-compilation flags.

    The flags are resolved from the target configuration (not the execution
    platform), so cross-compilation works correctly.

    Usage:
        rust_binary(
            name = "app",
            srcs = ["src/main.rs"],
            rustc_flags = schema_rustc_flags_select(),
        )

    In Rust:
        #[cfg(arch = "riscv64")]
        fn platform_init() { ... }

        #[cfg(has_qemu)]
        mod qemu { ... }
    """
    result = []

    for field_name, field in CONFIG_SCHEMA.items():
        if field.type == "string_enum" and field.cfg:
            entries = {}
            for val in field.values:
                entries[_constraint_label(field_name, val)] = [
                    '--cfg={}="{}"'.format(field_name, val),
                ]
            entries["DEFAULT"] = []
            result = result + select(entries)

        elif field.type == "bool" and field.cfg:
            result = result + select({
                _constraint_label(field_name, "true"): ["--cfg=" + field_name],
                "DEFAULT": [],
            })

    return result
