# SPDX-License-Identifier: GPL-2.0
CC ?= cc
CLANG ?= clang
BPFTOOL ?= bpftool
PKG_CONFIG ?= pkg-config
VMLINUX_BTF ?= /sys/kernel/btf/vmlinux
VMLINUX_H ?= build/vmlinux.h
PREFIX ?= /usr/local
CFLAGS ?= -O2 -g
CPPFLAGS += $(shell $(PKG_CONFIG) --cflags libbpf json-c)
WARN = -Wall -Wextra -Werror -std=gnu11
LDLIBS += $(shell $(PKG_CONFIG) --libs libbpf json-c) -lpthread
SOURCES = monitor.c object.c config.c roots.c state.c output.c
.PHONY: all native bpf check install clean
all: native bpf
native: build/osctl-rtnl-monitor
bpf: build/monitor.bpf.o
build:
	mkdir -p $@
$(VMLINUX_H): | build
	$(BPFTOOL) btf dump file $(VMLINUX_BTF) format c > $@.tmp
	mv $@.tmp $@
build/monitor.bpf.o: monitor.bpf.c monitor.h $(VMLINUX_H) | build
	NIX_HARDENING_ENABLE="" $(CLANG) -g -O2 -target bpf -Wno-unused-command-line-argument -D__TARGET_ARCH_x86 -I$(dir $(VMLINUX_H)) $(shell $(PKG_CONFIG) --cflags libbpf) -Wall -Werror -c $< -o $@
build/osctl-rtnl-monitor: $(SOURCES) core.h monitor.h | build
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARN) $(SOURCES) $(LDFLAGS) $(LDLIBS) -o $@
build/test-core: tests/test_core.c config.c state.c roots.c output.c core.h monitor.h | build
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARN) -I. tests/test_core.c config.c state.c roots.c output.c $(LDFLAGS) $(LDLIBS) -o $@
build/test-object: tests/test_object.c object.c config.c core.h monitor.h | build
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARN) -I. tests/test_object.c object.c config.c $(LDFLAGS) $(LDLIBS) -o $@
check: build/test-core build/test-object build/monitor.bpf.o
	./build/test-core
	./build/test-object build/monitor.bpf.o
install: all
	install -Dm755 build/osctl-rtnl-monitor $(DESTDIR)$(PREFIX)/bin/osctl-rtnl-monitor
	install -Dm644 build/monitor.bpf.o $(DESTDIR)$(PREFIX)/lib/osctl-rtnl-monitor/monitor.bpf.o
clean:
	rm -rf build
