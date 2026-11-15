# SPDX-License-Identifier: GPL-2.0-or-later
#
# udpblast3 is a diagnostic helper, not an OpenWrt package.  Build it on
# the host for loopback tests, or with the target toolchain for the AP:
#
#   make CC=aarch64-openwrt-linux-musl-gcc LDFLAGS=-static
#   make CC=aarch64-linux-gnu-gcc LDFLAGS=-static   # compile check only
#
# No code from this directory is linked into the firmware image.

CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra
CPPFLAGS ?=
LDFLAGS ?=

PROG = udpblast3

all: $(PROG)

$(PROG): udpblast3.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(PROG)

.PHONY: all clean
