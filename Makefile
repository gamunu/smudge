# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Gamunu Balagalla

# Plain make build of the HPLIP hpcups filter for macOS.
# Usage: make            (builds build/hpcups)
#        make ARCHS="arm64 x86_64"   (universal, needs a universal libjpeg.a)

CC      ?= cc
CXX     ?= c++
ARCHS   ?= arm64
ARCHFLAGS := $(foreach a,$(ARCHS),-arch $(a))
MINVER  ?= 26.0

# Static libjpeg so the filter has no runtime dependency outside the system.
JPEG_PREFIX ?= $(shell pkg-config --variable=prefix libjpeg 2>/dev/null || echo /opt/homebrew)
JPEG_INC    ?= $(JPEG_PREFIX)/include
JPEG_LIB    ?= $(JPEG_PREFIX)/lib/libjpeg.a

DEFS    := -DDISABLE_IMAGEPROCESSOR -DAPDK_LITTLE_ENDIAN -D_GNU_SOURCE -DCONFDIR='"/etc/hp"'
# The filter parses raster data from whoever can print to the queue. Keep the
# stack canaries and the checked libc string calls on. The sanitizer builds
# turn this off: ASan does the same checks and more.
HARDEN  := -fstack-protector-strong -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2
# OPT can be replaced, for example by the sanitizer build in `make asan`.
OPT     ?= -O2 -g0
COMMON  := $(ARCHFLAGS) -mmacosx-version-min=$(MINVER) $(OPT) $(HARDEN) \
           -Isrc/hpcups -Isrc/common -Isrc/compat -Isrc/jbigkit -I$(JPEG_INC) $(DEFS)
# HPLIP and jbigkit are upstream code with thousands of warnings, so they
# build with -w. Code written here builds with warnings as errors.
VENDOR_WARN := -w
OWN_WARN    := -Wall -Wextra -Wformat=2 -Werror
CFLAGS  := $(COMMON)
CXXFLAGS := $(COMMON) -std=gnu++14
LDFLAGS ?=
LDLIBS  := $(JPEG_LIB) -lcups -lz

# Build directory. `make asan` and `make fuzz` use their own.
OUT     ?= build

CPP_SRCS := $(wildcard src/hpcups/*.cpp)
# jccolor.c holds HP's patched colour converter and needs libjpeg 6b private
# headers. src/compat/hp_csc.c redoes its table math for the JetReady path.
C_SRCS   := $(filter-out src/hpcups/jccolor.c,$(wildcard src/hpcups/*.c)) src/common/hplip_utils.c src/compat/hp_csc.c \
            src/compat/hp_jbig.c $(wildcard src/jbigkit/*.c)
OBJS     := $(patsubst src/%.cpp,$(OUT)/obj/%.o,$(CPP_SRCS)) \
            $(patsubst src/%.c,$(OUT)/obj/%.o,$(C_SRCS))

all: $(OUT)/hpcups

$(OUT)/hpcups: $(OBJS)
	$(CXX) $(ARCHFLAGS) -mmacosx-version-min=$(MINVER) $(LDFLAGS) -o $@ $(OBJS) $(LDLIBS)

$(OUT)/obj/%.o: src/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(VENDOR_WARN) -c $< -o $@

$(OUT)/obj/compat/%.o: src/compat/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(OWN_WARN) -c $< -o $@

$(OUT)/obj/%.o: src/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(VENDOR_WARN) -c $< -o $@

app:
	scripts/build-app.sh

# One installer with the driver and the app. Version: see scripts/version.sh.
pkg: build/hpcups
	scripts/build-pkg.sh

$(OUT)/csc-check: tests/csc-check.c src/compat/hp_csc.c src/compat/hp_csc.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $(OWN_WARN) $(LDFLAGS) -o $@ tests/csc-check.c src/compat/hp_csc.c

test: $(OUT)/hpcups $(OUT)/csc-check
	$(OUT)/csc-check
	HPCUPS=$(OUT)/hpcups scripts/test-local.sh

# The offline tests again, with the filter built under AddressSanitizer and
# UndefinedBehaviorSanitizer. Any report fails the run.
SAN := -fsanitize=address,undefined -fno-sanitize-recover=all
asan:
	$(MAKE) OUT=build/asan HARDEN= OPT="-O1 -g -fno-omit-frame-pointer $(SAN)" LDFLAGS="$(SAN)" test

# libFuzzer needs LLVM's own clang; Apple's clang ships no fuzzer runtime.
# FUZZ_LLVM is the bin directory of a Homebrew llvm.
FUZZ_LLVM ?= $(firstword $(wildcard /opt/homebrew/opt/llvm/bin /opt/homebrew/opt/llvm@*/bin))
FUZZ_SAN  := -fsanitize=fuzzer-no-link,address,undefined -fno-sanitize-recover=all
FUZZ_TIME ?= 60

# The fuzz build renames the filter's main() so the harness can drive StartPrintJob().
fuzz-build:
	@[ -x "$(FUZZ_LLVM)/clang++" ] || { echo "no LLVM clang, brew install llvm or set FUZZ_LLVM" >&2; exit 1; }
	$(MAKE) OUT=build/fuzz HARDEN= CC=$(FUZZ_LLVM)/clang CXX=$(FUZZ_LLVM)/clang++ \
	    OPT="-O1 -g -fno-omit-frame-pointer $(FUZZ_SAN) -Dmain=hpcups_main" build/fuzz/obj/hpcups/HPCupsFilter.o $(OBJS:build/%=build/fuzz/%)
	$(FUZZ_LLVM)/clang++ $(ARCHFLAGS) -mmacosx-version-min=$(MINVER) -O1 -g $(subst fuzzer-no-link,fuzzer,$(FUZZ_SAN)) \
	    -Isrc/hpcups -Isrc/common -Isrc/compat -I$(JPEG_INC) $(DEFS) -std=gnu++14 \
	    -o build/fuzz/fuzz-raster tests/fuzz/fuzz-raster.cpp $(OBJS:build/%=build/fuzz/%) $(LDLIBS)

# Fuzz the filter with CUPS raster input for FUZZ_TIME seconds. The corpus
# starts from rasters made with cupsfilter, one per print language.
fuzz: fuzz-build
	scripts/fuzz-seed.sh build/fuzz
	cd build/fuzz && FUZZ_PPD_DIR=$(CURDIR)/build/fuzz/ppds ./fuzz-raster -max_total_time=$(FUZZ_TIME) \
	    -rss_limit_mb=4096 -max_len=1048576 -close_fd_mask=2 -artifact_prefix=crash- corpus seeds

clean:
	rm -rf build

.PHONY: all app pkg test asan fuzz fuzz-build clean
