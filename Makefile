PG_CONFIG ?= pg_config
PGDATABASE ?= omnigres

EXTENSION = omni_git
MODULE_big = omni_git
OBJS = omni_git.o

PG_CPPFLAGS = $(shell pkg-config --cflags libgit2) $(shell pkg-config --cflags openssl)
SHLIB_LINK = $(shell pkg-config --libs libgit2) $(shell pkg-config --libs openssl) -lz

EXTENSION_VERSION = 0.1.0

DATA = sql/$(EXTENSION)--$(EXTENSION_VERSION).sql
EXTRA_CLEAN = sql/$(EXTENSION)--$(EXTENSION_VERSION).sql sql

PG_CONFIG := $(PG_CONFIG)
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Build the combined SQL file by resolving includes
sql/$(EXTENSION)--$(EXTENSION_VERSION).sql: $(wildcard migrate/*.sql) $(wildcard src/*.sql)
	mkdir -p sql
	./build-sql.sh > $@

# Make sure SQL file is built before install
all: sql/$(EXTENSION)--$(EXTENSION_VERSION).sql

install: install-control

install-control:
	cp omni_git.control $(shell $(PG_CONFIG) --sharedir)/extension/

.PHONY: install-control
