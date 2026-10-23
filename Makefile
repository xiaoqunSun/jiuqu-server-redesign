SKYNET_DIR := third_party/skynet
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
SKYNET_PLATFORM := macosx
TLS_MODULE_FLAGS := -bundle -undefined dynamic_lookup
OPENSSL_PREFIX := $(shell brew --prefix openssl@3 2>/dev/null)
ifeq ($(OPENSSL_PREFIX),)
OPENSSL_PREFIX := $(shell pkg-config --variable=prefix openssl 2>/dev/null)
endif
else
SKYNET_PLATFORM := linux
TLS_MODULE_FLAGS := -shared
OPENSSL_PREFIX := $(shell pkg-config --variable=prefix openssl 2>/dev/null)
endif

OPENSSL_INCLUDEDIR ?= $(if $(OPENSSL_PREFIX),$(OPENSSL_PREFIX)/include,/usr/include)
OPENSSL_LIBDIR ?= $(if $(OPENSSL_PREFIX),$(OPENSSL_PREFIX)/lib,/usr/lib)

.PHONY: all patch-skynet skynet zlib tls run clean

all: skynet zlib tls

patch-skynet:
	@set -eu; \
	baseline_revision=$$(git -C $(SKYNET_DIR) rev-parse HEAD); \
	if [ "$$baseline_revision" != "ba64be6f9fa044933c77de1317f466afbade8eaa" ]; then \
		echo "third_party/skynet must be pinned to v1.8.0 (ba64be6f9fa044933c77de1317f466afbade8eaa)" >&2; exit 1; \
	fi; \
	if git -C $(SKYNET_DIR) apply --reverse --check ../../patches/skynet-v1.8.0-tls.patch >/dev/null 2>&1; then \
		:; \
	elif git -C $(SKYNET_DIR) apply --check ../../patches/skynet-v1.8.0-tls.patch >/dev/null 2>&1; then \
		git -C $(SKYNET_DIR) apply ../../patches/skynet-v1.8.0-tls.patch; \
	else \
		echo "Skynet v1.8.0 TLS patch cannot be applied cleanly" >&2; exit 1; \
	fi

skynet: patch-skynet
	$(MAKE) -C $(SKYNET_DIR) $(SKYNET_PLATFORM)

ifeq ($(UNAME_S),Darwin)
ZLIB_MODULE_FLAGS := -bundle -undefined dynamic_lookup
else
ZLIB_MODULE_FLAGS := -shared
endif

zlib: lualib-src/lua_zlib.c
	mkdir -p $(SKYNET_DIR)/luaclib
	$(CC) -O2 -fPIC -I$(SKYNET_DIR)/3rd/lua $(ZLIB_MODULE_FLAGS) $< -o $(SKYNET_DIR)/luaclib/zlib.so -lz

tls: skynet third_party/skynet/lualib-src/ltls.c
	mkdir -p $(SKYNET_DIR)/luaclib
	$(CC) -O2 -fPIC -I$(SKYNET_DIR)/3rd/lua -I$(OPENSSL_INCLUDEDIR) $(TLS_MODULE_FLAGS) -L$(OPENSSL_LIBDIR) -Wl,-rpath,$(OPENSSL_LIBDIR) $(SKYNET_DIR)/lualib-src/ltls.c -o $(SKYNET_DIR)/luaclib/ltls.so -lssl -lcrypto

run: all
	$(SKYNET_DIR)/skynet etc/config.lua

clean:
	$(MAKE) -C $(SKYNET_DIR) clean
	rm -f $(SKYNET_DIR)/luaclib/zlib.so
	rm -f $(SKYNET_DIR)/luaclib/ltls.so
