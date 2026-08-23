# PGXS build for eter_ssi.
# Build + install against the target Postgres:  make PG_CONFIG=$(which pg_config) install
MODULE_big = eter_ssi
OBJS = eter_ssi.o
EXTENSION = eter_ssi
# The extension's schema version is declared once, in eter_ssi.control
# (default_version). The versioned install script PGXS wants
# (eter_ssi--<version>.sql) is GENERATED from the version-free source
# eter_ssi.sql, so the version is never hardcoded into a committed filename.
EXTVERSION = $(shell sed -n "s/^default_version[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" eter_ssi.control)
DATA_built = eter_ssi--$(EXTVERSION).sql
PGFILEDESC = "eter_ssi - SSI dependency capture for EterDB"

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Generate the PGXS-named install script from the version-free source.
eter_ssi--$(EXTVERSION).sql: eter_ssi.sql
	cp $< $@
