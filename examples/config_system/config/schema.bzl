# The single global configuration schema.
#
# Edit this file to add, remove, or modify configuration fields.
# Every config instance (in configs/BUCK) must supply a value for every
# field defined here (or rely on the default via parent inheritance).
#
# Field types:
#   string_enum_field  — one of a fixed set of strings; cfg=True → --cfg flag
#   bool_field         — True/False;                    cfg=True → --cfg flag
#   int_field          — integer; values=[...] makes it constraint-backed
#   string_list_field  — list of strings (not constraint-backed)

load(":field_types.bzl", "bool_field", "int_field", "string_enum_field", "string_list_field")

# The name of the schema target created in //config/BUCK.
# config_instance() and config_codegen() use this to locate constraint targets.
SCHEMA_TARGET = "//config:schema"

# The configuration schema.  One entry per field.
CONFIG_SCHEMA = {
    # Which CPU architecture the binary targets.
    # Drives --cfg=arch="<value>" for conditional compilation.
    "arch": string_enum_field(
        values = ["x86_64", "aarch64", "riscv64"],
        default = "x86_64",
        cfg = True,
        doc = "Target CPU architecture",
    ),

    # Optimisation / debug-info level.
    # Drives --cfg=build_mode="<value>" for conditional compilation.
    "build_mode": string_enum_field(
        values = ["debug", "release"],
        default = "debug",
        cfg = True,
        doc = "Build optimisation level",
    ),

    # Heap size in bytes.  Only the listed values are allowed so that the
    # field is constraint-backed and resolves correctly per-platform.
    "heap_size": int_field(
        values = [16384, 65536, 131072, 262144],
        default = 65536,
        doc = "Heap size in bytes",
    ),

    # Whether to compile QEMU virtio transport support.
    # Drives --cfg=has_qemu for conditional compilation.
    "has_qemu": bool_field(
        default = False,
        cfg = True,
        doc = "Include QEMU virtio transport",
    ),

    # Whether to compile UART support.
    # Drives --cfg=has_uart for conditional compilation.
    "has_uart": bool_field(
        default = True,
        cfg = True,
        doc = "Include UART driver",
    ),
}
