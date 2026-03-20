# Rule implementations for the configuration system.
#
# _config_instance_rule  — the only rule defined here.
#
# It is a configuration rule (is_configuration_rule = True) that provides:
#   • PlatformInfo        — makes the target usable as --target-platforms or a
#                           modifier alias.
#   • ConfigInstanceInfo  — carries the fully-resolved typed field values for
#                           consumers such as the code-generation rule.
#
# The matching macro (config_instance() in defs.bzl) handles:
#   • type validation against CONFIG_SCHEMA
#   • parent-dict merging at parse time
#   • deriving the constraint-value dep labels

load(":providers.bzl", "ConfigInstanceInfo")
load(":schema.bzl", "CONFIG_SCHEMA")

def _config_instance_impl(ctx: AnalysisContext) -> list[Provider]:
    # Build ConfigurationInfo from constraint-value deps.
    # The macro already resolved which constraint value is active for each
    # cfg-enabled field and passed the deps here.
    constraints = {}
    for cv_dep in ctx.attrs.constraint_value_deps:
        cv_info = cv_dep[ConstraintValueInfo]
        constraints[cv_info.setting.label] = cv_info

    cfg = ConfigurationInfo(constraints = constraints, values = {})

    return [
        DefaultInfo(),
        # Makes this target usable as --target-platforms //configs:<name>
        # and as a modifier alias.
        PlatformInfo(
            label = str(ctx.label.raw_target()),
            configuration = cfg,
        ),
        ConfigInstanceInfo(
            config_name = str(ctx.label.raw_target()),
            str_values = ctx.attrs.str_values,
            bool_values = ctx.attrs.bool_values,
            int_values = ctx.attrs.int_values,
            list_values = ctx.attrs.list_values,
        ),
    ]

_config_instance_rule = rule(
    impl = _config_instance_impl,
    is_configuration_rule = True,
    attrs = {
        # Typed field values (pre-validated and parent-merged by the macro).
        "str_values": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "bool_values": attrs.dict(attrs.string(), attrs.bool(), default = {}),
        "int_values": attrs.dict(attrs.string(), attrs.int(), default = {}),
        "list_values": attrs.dict(attrs.string(), attrs.list(attrs.string()), default = {}),
        # One dep per cfg-enabled field, pointing at the active constraint value.
        # Buck2 uses these to populate ConfigurationInfo.constraints.
        "constraint_value_deps": attrs.list(
            attrs.dep(providers = [ConstraintValueInfo]),
            default = [],
        ),
    },
)

# ---------------------------------------------------------------------------
# _config_codegen_rule  (dynamically generated attrs from CONFIG_SCHEMA)
# ---------------------------------------------------------------------------
#
# Each cfg-enabled field gets an attrs.string() / attrs.bool() with a
# select() default so that the resolved value matches the active platform.
# Non-cfg int fields with a values list are also constraint-backed via
# attrs.string() + select().
#
# The codegen implementation reads these resolved attrs and writes config.rs.

def _make_codegen_attrs():
    """Build the attrs dict for _config_codegen_rule from CONFIG_SCHEMA."""
    result = {}
    for field_name, field in CONFIG_SCHEMA.items():
        attr_name = "_field_" + field_name

        if field.type == "string_enum":
            if field.cfg:
                entries = {}
                for val in field.values:
                    entries["//config:schema__" + field_name + "[" + val + "]"] = val
                entries["DEFAULT"] = field.default
                result[attr_name] = attrs.string(default = select(entries))
            else:
                result[attr_name] = attrs.string(default = field.default)

        elif field.type == "bool":
            if field.cfg:
                result[attr_name] = attrs.bool(default = select({
                    "//config:schema__" + field_name + "[true]": True,
                    "DEFAULT": False,
                }))
            else:
                result[attr_name] = attrs.bool(default = field.default)

        elif field.type == "int":
            if field.values != None:
                # Constraint-backed: stored as string, converted to int in codegen.
                entries = {}
                for val in field.values:
                    entries["//config:schema__" + field_name + "[" + str(val) + "]"] = str(val)
                entries["DEFAULT"] = str(field.default)
                result[attr_name] = attrs.string(default = select(entries))
            else:
                # Fixed: always schema default.
                result[attr_name] = attrs.string(default = str(field.default))

        elif field.type == "string_list":
            # Not constraint-backed; always generates the schema default.
            # For per-item conditional compilation use individual bool_field entries.
            result[attr_name] = attrs.list(attrs.string(), default = list(field.default))

    return result

def _config_codegen_impl(ctx: AnalysisContext) -> list[Provider]:
    """Generate a config.rs file from the resolved attr values."""
    lines = [
        "// @generated by Buck2 config_codegen — do not edit by hand.",
        "// Rebuild with: buck2 build <target> --target-platforms //configs:<name>",
        "",
    ]

    for field_name, field in CONFIG_SCHEMA.items():
        attr_name = "_field_" + field_name
        const_name = field_name.upper()
        val = getattr(ctx.attrs, attr_name)

        if field.type == "string_enum":
            lines.append('pub const {}: &str = "{}";'.format(const_name, val))

        elif field.type == "bool":
            lines.append("pub const {}: bool = {};".format(
                const_name,
                "true" if val else "false",
            ))

        elif field.type == "int":
            # val is a string (selected from constraint or fixed default).
            lines.append("pub const {}: i64 = {};".format(const_name, val))

        elif field.type == "string_list":
            # val is a list[str].
            items = ", ".join(['"' + v + '"' for v in val])
            lines.append("pub const {}: &[&str] = &[{}];".format(const_name, items))

    output = ctx.actions.declare_output("config.rs")
    ctx.actions.write(output, "\n".join(lines) + "\n")
    return [DefaultInfo(default_output = output)]

_config_codegen_rule = rule(
    impl = _config_codegen_impl,
    attrs = _make_codegen_attrs(),
)

# ---------------------------------------------------------------------------
# Public symbols consumed by defs.bzl
# ---------------------------------------------------------------------------

config_system_rules = struct(
    config_instance = _config_instance_rule,
    config_codegen = _config_codegen_rule,
)
