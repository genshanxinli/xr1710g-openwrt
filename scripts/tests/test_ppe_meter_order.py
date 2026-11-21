#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Behavioural regression test for the DS-Lite+PPPoE refusal in the PPE meter.

The tc police meter from issue #23 hands a flow a PPE meter group from a
63-entry bitmap.  A DS-Lite decapsulation flow that also carries a PPPoE
push is refused with -EOPNOTSUPP.  When that refusal sits *after*
airoha_ppe_meter_alloc(), every refused rule keeps its group: after the
63rd one the bitmap is full and every later tc police rule fails with
-EBUSY for the life of the module.  The refusal has to be decided before
the allocation, where "return -EOPNOTSUPP" is still the right exit.

This script does not read the answer out of the source alone.  It takes an
already patched kernel tree, extracts the two real functions from
drivers/net/ethernet/airoha/airoha_ppe.c (the allocation block between the
action loop and the bridge decision, plus airoha_ppe_meter_alloc()/_free()),
wraps them in a freestanding harness and runs 63 DS-Lite+PPPoE calls
through the extracted code.  A tree with the old order reports:

  case A: rejected=63/63 alloc_calls=63 groups_held=63
  case A control: rc=-16 groups_held=63

and fails.  A tree with the refusal before the allocation reports
alloc_calls=0 and the control flow still gets group 0.

usage:
  test_ppe_meter_order.py --tree DIR [--keep]

  DIR is a kernel tree with the airoha patch queue applied, e.g. the tree
  apply-queue-f0.sh --keep prints, or any build tree.  --keep writes the
  generated harness and the binary to a temporary directory and prints it.

Exit status: 0 when the order is correct and the harness passes, 1 when the
order or the behaviour is wrong, 2 on bad arguments or extract failure.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

PPE_C = "drivers/net/ethernet/airoha/airoha_ppe.c"

GUARD_IF = "if (offload_type == PPE_PKT_TYPE_IPV4_DSLITE && data.pppoe.num"
GUARD_CMT = "/* A DS-Lite decapsulation flow is plain IPv4-in-IPv6; a PPPoE"
ETHER_CHECK = "if (!is_valid_ether_addr(data.eth.h_source) ||"
ALLOC_CALL = "airoha_ppe_meter_alloc(eth->ppe, police, &meter)"

STUBS = r'''
/* Kernel API the extracted code touches, stubbed just enough to compile
 * and run freestanding.  Types and constants mirror
 * drivers/net/ethernet/airoha/airoha_eth.h:411-412 and :753-758. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint8_t  u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;

#define BIT(n)              (1UL << (n))
#define GENMASK(h, l)       (((~0UL) << (l)) & (~0UL >> (8 * sizeof(long) - 1 - (h))))
#define U32_MAX             0xffffffffU
#define min_t(type, a, b)   ((type)(a) < (type)(b) ? (type)(a) : (type)(b))
#define EOPNOTSUPP          95
#define EBUSY               16
#define EINVAL              22
#define PPE_PKT_TYPE_IPV4_HNAPT 0
#define PPE_PKT_TYPE_IPV4_DSLITE 3
#define AIROHA_PPE_METER_NUM  63
#define AIROHA_PPE_METER_NONE 0x7f
#define WARN_ON_ONCE(x)     (0)

static inline void set_bit(unsigned int n, unsigned long *bm)
{
	bm[n / 64] |= 1UL << (n % 64);
}

static inline void clear_bit(unsigned int n, unsigned long *bm)
{
	bm[n / 64] &= ~(1UL << (n % 64));
}

static inline int test_bit(unsigned int n, const unsigned long *bm)
{
	return (bm[n / 64] >> (n % 64)) & 1;
}

static inline unsigned long find_first_zero_bit(const unsigned long *bm,
						 unsigned long n)
{
	unsigned long i;

	for (i = 0; i < n; i++)
		if (!test_bit(i, bm))
			return i;
	return n;
}

static inline int is_valid_ether_addr(const u8 *addr)
{
	static const u8 zero[6];

	return memcmp(addr, zero, sizeof(zero)) != 0;
}

static inline int is_multicast_ether_addr(const u8 *addr)
{
	return addr[0] & 1;
}

struct net_device;

struct flow_action_entry {
	struct {
		u64 rate_bytes_ps;
		u64 peakrate_bytes_ps;
		u64 burst;
	} police;
};

struct airoha_ppe_meter {
	u32 refcount;
	u32 rate_bps;
	u32 peakrate_bps;
	u32 burst;
};

struct airoha_eth;

struct airoha_ppe {
	struct airoha_eth *eth;
	unsigned long meter_bitmap[(AIROHA_PPE_METER_NUM + 63) / 64];
	struct airoha_ppe_meter meter[AIROHA_PPE_METER_NUM];
	u32 meter_enabled;
};

struct airoha_eth {
	struct airoha_ppe *ppe;
};

struct airoha_flow_data {
	struct {
		u8 h_source[6];
		u8 h_dest[6];
	} eth;
	struct {
		int num;
	} pppoe;
	u8 meter;
	u32 mcast_mask;
};

/* hardware side the allocator talks to; the counters live in sw anyway */
static int airoha_ppe_meter_hw_config(struct airoha_eth *eth, int id, u64 rate,
				      u64 burst)
{
	(void)eth;
	(void)id;
	(void)rate;
	(void)burst;
	return 0;
}

static void airoha_ppe_meter_hw_disable(struct airoha_eth *eth, int id)
{
	(void)eth;
	(void)id;
}

static bool airoha_ppe_mcast_switch_egress(const struct net_device *dev)
{
	(void)dev;
	return false;
}

static u32 airoha_ppe_mcast_switch_mask(const struct net_device *dev, u32 in)
{
	(void)dev;
	(void)in;
	return 0;
}
'''

ALLOC_TMPL = r'''
static int g_alloc_calls;
static int g_groups_held;

#define airoha_ppe_meter_alloc airoha_ppe_meter_alloc_impl
#define airoha_ppe_meter_free airoha_ppe_meter_free_impl
@@ALLOC@@
#undef airoha_ppe_meter_alloc
#undef airoha_ppe_meter_free

static int airoha_ppe_meter_alloc(struct airoha_ppe *ppe,
				  const struct flow_action_entry *act, u8 *group)
{
	int rc = airoha_ppe_meter_alloc_impl(ppe, act, group);

	g_alloc_calls++;
	if (!rc)
		g_groups_held++;
	return rc;
}

static void airoha_ppe_meter_free(struct airoha_ppe *ppe, u8 group)
{
	g_groups_held--;
	airoha_ppe_meter_free_impl(ppe, group);
}
'''

TAIL_TMPL = r'''
/* Extracted verbatim from @@TREE@@:@@LINES@@: the allocation block that sits
 * between the action loop and the bridge decision, in file order. */
static int flow_tail(struct airoha_eth *eth, struct airoha_flow_data data,
		     int offload_type, const struct flow_action_entry *police)
{
	struct net_device *odev = NULL;
	struct flow_cls_key {
		u32 ingress_ifindex;
	} key0;
	struct {
		struct flow_cls_key *key;
	} meta;
	u8 meter = AIROHA_PPE_METER_NONE;
	int err = 0;

	meta.key = &key0;
@@TAIL@@
	return 0;
}

int main(void)
{
	struct airoha_eth eth;
	struct airoha_ppe ppe;
	struct flow_action_entry police = {
		.police = { .rate_bytes_ps = 1000000, .burst = 10000 },
	};
	int i, rc, rejects = 0;

	setvbuf(stdout, NULL, _IONBF, 0);
	memset(&eth, 0, sizeof(eth));
	memset(&ppe, 0, sizeof(ppe));
	ppe.eth = &eth;
	eth.ppe = &ppe;

	/* 63 DS-Lite flows that also push a PPPoE header: every one of them
	 * is refused, so none may take a meter group. */
	for (i = 0; i < 63; i++) {
		struct airoha_flow_data data;

		memset(&data, 0, sizeof(data));
		data.pppoe.num = 1;
		memset(data.eth.h_source, 2, 6);
		memset(data.eth.h_dest, 4, 6);		/* unicast */

		rc = flow_tail(&eth, data, PPE_PKT_TYPE_IPV4_DSLITE, &police);
		if (rc == -EOPNOTSUPP)
			rejects++;
	}

	printf("case A: rejected=%d/63 alloc_calls=%d groups_held=%d\n",
	       rejects, g_alloc_calls, g_groups_held);
	assert(rejects == 63);
	assert(g_alloc_calls == 0);
	assert(g_groups_held == 0);

	/* Control: an ordinary IPv4 flow still gets the first group, i.e.
	 * the 63 refusals did not exhaust the pool. */
	{
		struct airoha_flow_data data;

		memset(&data, 0, sizeof(data));
		memset(data.eth.h_source, 2, 6);
		memset(data.eth.h_dest, 4, 6);
		rc = flow_tail(&eth, data, PPE_PKT_TYPE_IPV4_HNAPT, &police);
		printf("case A control: plain IPv4 rc=%d groups_held=%d\n",
		       rc, g_groups_held);
		assert(rc == 0);
		assert(g_groups_held == 1);
		airoha_ppe_meter_free(&ppe, 0);
		assert(g_groups_held == 0);
	}

	printf("harness: PASS (refusals made %d meter allocations)\n",
	       g_alloc_calls);
	return 0;
}
'''


def brace_end(src, start):
	"""Index just past the '}' that closes the block starting at start."""
	depth = 0
	for i in range(start, len(src)):
		if src[i] == "{":
			depth += 1
		elif src[i] == "}":
			depth -= 1
			if depth == 0:
				return i + 1
	raise SystemExit("unbalanced braces")


def extract_function(src, signature):
	"""Return the text of the function whose definition starts at signature."""
	m = re.search(signature, src, re.M)
	if not m:
		raise SystemExit("definition not found: %s" % signature)
	start = m.start()
	brace = src.index("{", m.end())
	return src[start:brace_end(src, brace)]


def extract_tail(src):
	"""The code region between the action loop and the bridge decision.

	Start at whichever of the refusal or the L2 check comes first, end
	after whichever of the refusal's return or the meter block comes last.
	The slice keeps the file order, so the harness exercises the same
	sequence the driver runs.
	"""
	cmt = src.index(GUARD_CMT)
	ether = src.index(ETHER_CHECK)
	start = min(cmt, ether)
	start = src.rfind("\n", 0, start) + 1

	guard_if = src.index(GUARD_IF, cmt)
	guard_end = src.index("\n\n", guard_if) + 2

	alloc = src.index(ALLOC_CALL)
	alloc_end = src.index("\n\t}\n", alloc) + 4

	end = max(guard_end, alloc_end)
	tail = src[start:end]
	if "airoha_ppe_meter_alloc" not in tail or GUARD_IF not in tail:
		raise SystemExit("tail extraction lost the guard or the allocation")
	return tail, start, end


def build_harness(tree):
	path = os.path.join(tree, PPE_C)
	with open(path) as f:
		src = f.read()

	guard_line = src.count("\n", 0, src.index(GUARD_CMT)) + 1
	guard_if_line = src.count("\n", 0, src.index(GUARD_IF)) + 1
	alloc_line = src.count("\n", 0, src.index(ALLOC_CALL)) + 1
	ether_line = src.count("\n", 0, src.index(ETHER_CHECK)) + 1

	alloc = extract_function(src, r"^static int airoha_ppe_meter_alloc\(")
	free = extract_function(src, r"^static void airoha_ppe_meter_free\(")
	tail, start, end = extract_tail(src)

	body = STUBS + ALLOC_TMPL.replace("@@ALLOC@@", alloc + "\n" + free)
	body += TAIL_TMPL.replace("@@TAIL@@", tail).replace(
		"@@TREE@@", tree).replace(
		"@@LINES@@", "%d-%d" % (src.count("\n", 0, start) + 1,
					src.count("\n", 0, end))
	)
	return body, (guard_line, guard_if_line, alloc_line, ether_line)


def main(argv=None):
	ap = argparse.ArgumentParser(
		description="Prove the DS-Lite+PPPoE refusal runs before the PPE "
			    "meter allocation.")
	ap.add_argument("--tree", required=True,
			help="kernel tree with the airoha queue applied")
	ap.add_argument("--keep", action="store_true",
			help="keep the generated harness and print its directory")
	args = ap.parse_args(argv)

	if not os.path.isfile(os.path.join(args.tree, PPE_C)):
		ap.error("%s: %s is missing" % (args.tree, PPE_C))
	if not shutil.which("gcc"):
		ap.error("gcc not found")

	c_source, lines = build_harness(args.tree)
	guard_line, guard_if_line, alloc_line, ether_line = lines

	work = tempfile.mkdtemp(prefix="ppe-meter-order.")
	try:
		c_file = os.path.join(work, "case_a.c")
		bin_file = os.path.join(work, "case_a")
		with open(c_file, "w") as f:
			f.write(c_source)
		cc = subprocess.run(
			["gcc", "-O2", "-Wall", "-Werror", "-o", bin_file, c_file],
			capture_output=True, text=True)
		if cc.returncode != 0:
			sys.stderr.write(cc.stderr)
			raise SystemExit("harness does not compile")

		print("tree: %s" % args.tree)
		print("static: refusal at line %d, airoha_ppe_meter_alloc() called at "
		      "line %d, L2 check at line %d"
		      % (guard_if_line, alloc_line, ether_line))
		if alloc_line < guard_if_line:
			print("static: FAIL (allocation precedes the refusal)")
		else:
			print("static: PASS (refusal precedes the allocation)")

		run = subprocess.run([bin_file], capture_output=True, text=True)
		print(run.stdout, end="")
		if run.returncode != 0:
			sys.stderr.write(run.stderr)
		if alloc_line < guard_if_line or run.returncode != 0:
			print("FAIL: refused DS-Lite+PPPoE flows must not consume a "
			      "meter group")
			return 1
		print("PASS: DS-Lite+PPPoE refusals leave the meter pool untouched")
		return 0
	finally:
		if args.keep:
			print("harness kept at %s" % work)
		else:
			shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
	sys.exit(main())
