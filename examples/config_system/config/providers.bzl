# Provider definitions for the configuration system.

# Attached to config_instance() targets.
# Carries the fully-resolved (parent-merged) typed values for every schema
# field.  Also consumed by _config_codegen_rule for generating Rust source.
ConfigInstanceInfo = provider(
    doc = "Fully-resolved values for a named configuration instance.",
    fields = {
        # Human-readable name of this config (its target label as a string).
        "config_name": provider_field(str),

        # string_enum field values:  field_name -> str
        "str_values": provider_field(dict),

        # bool field values:         field_name -> bool
        "bool_values": provider_field(dict),

        # int field values:          field_name -> int
        "int_values": provider_field(dict),

        # string_list field values:  field_name -> list[str]
        "list_values": provider_field(dict),
    },
)
