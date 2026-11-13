# SPDX-License-Identifier: GPL-2.0
CC ?= cc
PREFIX ?= /usr/local
CFLAGS ?= -O2 -g
WARN = -Wall -Wextra -Werror -std=gnu11
.PHONY: all check install clean FORCE
all: build/rtnl-watchdog build/rtnl-watchdog-probe
build:
	mkdir -p $@
build/helper-path.h: FORCE | build
	@printf '%s\n' '#define WD_HELPER_PATH "$(PREFIX)/libexec/rtnl-watchdog-probe"' > $@.tmp
	@if ! cmp -s $@.tmp $@; then mv $@.tmp $@; else rm $@.tmp; fi
build/rtnl-watchdog: main.c state.c config.c process.c files.c output.c watchdog.h output.h protocol.h build/helper-path.h | build
	$(CC) $(CPPFLAGS) -include build/helper-path.h $(CFLAGS) $(WARN) main.c state.c config.c process.c files.c output.c $(LDFLAGS) -lpthread -o $@
build/rtnl-watchdog-probe: probe.c protocol.c process.c state.c watchdog.h protocol.h | build
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARN) probe.c protocol.c process.c state.c $(LDFLAGS) -o $@
build/test-protocol: tests/test_protocol.c protocol.c protocol.h | build
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARN) -I. tests/test_protocol.c protocol.c $(LDFLAGS) -o $@
build/test-state: tests/test_state.c state.c config.c watchdog.h protocol.h | build
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARN) -I. tests/test_state.c state.c config.c $(LDFLAGS) -o $@
build/test-lock-child: tests/lock_child.c | build
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARN) tests/lock_child.c $(LDFLAGS) -o $@
build/test-runtime: tests/test_runtime.c state.c config.c process.c files.c output.c watchdog.h output.h protocol.h | build
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARN) -I. tests/test_runtime.c state.c config.c process.c files.c output.c $(LDFLAGS) -lpthread -o $@
check: build/test-protocol build/test-state build/test-runtime build/test-lock-child build/rtnl-watchdog-probe
	./build/test-protocol
	./build/test-state
	./build/test-runtime build/test-lock-child build/rtnl-watchdog-probe
install: all
	install -Dm755 build/rtnl-watchdog $(DESTDIR)$(PREFIX)/bin/rtnl-watchdog
	install -Dm755 build/rtnl-watchdog-probe $(DESTDIR)$(PREFIX)/libexec/rtnl-watchdog-probe
clean:
	rm -rf build
