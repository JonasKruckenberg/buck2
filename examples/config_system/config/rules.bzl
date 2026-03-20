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
# Public symbols consumed by defs.bzl
# ---------------------------------------------------------------------------

config_system_rules = struct(
    config_instance = _config_instance_rule,
)
