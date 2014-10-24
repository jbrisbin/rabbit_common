PROJECT = rabbit_common

ERLC_OPTS = +debug_info \
            +compressed \
            +report \
            +warn_export_all \
            +nowarn_export_vars \
            +warn_shadow_vars \
            +warn_unused_function \
            +warn_deprecated_function \
            +warn_obsolete_guard \
            +warn_unused_import

COMPILE_FIRST = gen_server2 \
                supervisor2 \
                mirrored_supervisor

include erlang.mk
