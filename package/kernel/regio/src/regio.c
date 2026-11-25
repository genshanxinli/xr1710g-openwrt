// SPDX-License-Identifier: GPL-2.0
/*
 * regio - debugfs MMIO window for the XR1710G (Airoha AN7581) investigation.
 *
 * The stock image has no /dev/mem and busybox is built without the devmem
 * applet, so nothing in userspace can read a peripheral register.  Every
 * hardware question in this project (NPU core state, QDMA ring config, PCIe
 * link registers, SCU PLL feedback, GDM counters, rbus block-DMA counters)
 * needs raw register access, so this module provides the smallest possible
 * door and bolts it down.
 *
 * Interface (write a command, then read the result back):
 *   echo "r 1fa202b4"     > /sys/kernel/debug/regio   ; cat /sys/kernel/debug/regio
 *   echo "d 1fa000ec 32"  > /sys/kernel/debug/regio   ; cat /sys/kernel/debug/regio
 *   echo "m 1fa000f8 1fa000fc 1fa00100 1fa00108" > ...; cat ...
 *   echo "w 1fa202b4 18000000" > ...                  ; cat ...
 *
 *   r <addr>              single 32-bit read
 *   d <addr> <n>          dump n consecutive 32-bit words (one ioremap, fast)
 *   m <addr> [addr...]    read up to 32 scattered addresses in one command
 *   w <addr> <val>        single 32-bit write
 *
 * Reads are allowed inside read_ranges (a module parameter).  Writes are off
 * unless allow_write=1, and even then:
 *   - regio_never[] blocks both read and write for the SPI-NAND controller
 *     (a stray write there is how you brick the box) and DRAM;
 *   - regio_ro[] allows reads but refuses writes for the clock/PLL block and
 *     uart1+watchdog (both of which hang or reset the box on a raw write).
 *
 * Registering a small "m"/"d" command matters for more than convenience:
 * every separate userspace write to this file is a separate syscall, and
 * shell redirection is free to split it, which is exactly how the old
 * "ERR parse" first-line symptom happened.  Batching also means one
 * ioremap/iounmap pair per command instead of one per register, which is
 * both faster and far less disruptive on sensitive peripheral windows.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/debugfs.h>
#include <linux/uaccess.h>
#include <linux/io.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/stdarg.h>
#include <linux/moduleparam.h>

#define REGIO_MAX_CMD	512
#define REGIO_MAX_ARGS	32
#define REGIO_MAX_DUMP	256
#define REGIO_OUT_SIZE	8192

static char *read_ranges = "0x1e860000-0x1e88ffff,0x1ec00000-0x1ec0ffff,0x1fa00000-0x1fefffff";
module_param(read_ranges, charp, 0444);
MODULE_PARM_DESC(read_ranges, "Comma separated hex ranges readable via regio");

static bool allow_write;
module_param(allow_write, bool, 0644);
MODULE_PARM_DESC(allow_write, "Enable register writes (default: off)");

static char *write_ranges = "0x1ec00000-0x1ec0ffff,0x1fa00000-0x1fbaffff";
module_param(write_ranges, charp, 0444);
MODULE_PARM_DESC(write_ranges, "Comma separated hex ranges writable via regio");

/* Regions that are refused no matter what the parameters say, for BOTH read
 * and write (regio_forbidden() is consulted on every op).  Keep this list for
 * things we must not even touch.
 *
 * NOTE (2026-10-31): the original table had "SPI-NAND controller" at
 * 0x1fb00000 and "NAND/SPI pad block" at 0x1fbf0000.  Both were wrong:
 *   - 0x1fb00000 is the `scuclk: clock-controller@1fb00000` node, not NAND.
 *   - 0x1fbf0000 is uart1@1fbf0000 plus watchdog@1fbf0100 (an7581.dtsi:405-420).
 *   - The real SPI-NAND controller is spi@1fa10000 (an7581.dtsi:720, two windows
 *     0x1fa10000+0x140 and 0x1fa11000+0x160; on hardware it shows up as
 *     1fa10000.spi and owns mtd0..mtd3) -- and it sat INSIDE the writable
 *     range 0x1fa00000-0x1fbaffff with no protection at all.  That was a live
 *     brick risk, not a cosmetic label error: a stray write there is exactly
 *     how you end up with unreadable flash.
 * Regions that are safe to read but must never be written live in regio_ro
 * below.
 *
 * NOTE (2026-11-14, roadmap R2 R13 + M1): 0x1e900000-0x1ebfffff is the NPU
 * block proper (`npu@1e900000`, reg length 0x313000 => 0x1e900000..0x1ec12fff
 * per the upstream binding).  An A53 load/store into that window hangs the
 * whole box (independent `h0m3us3r/w1700k-sdr` register reference; the only
 * surviving 0x1e9 read on this board was a single 8-word ioremap that is still
 * unexplained, so it is treated as a hang risk, not as evidence of safety).
 * Counters live in a separate, safe window at 0x1e860000-0x1e88ffff
 * (band0 0x1e8776e0 / band1 0x1e877ae0 / band2 0x1e86f640); NPU-internal state
 * (NDBG 0x1e906800) must be reached through the NPU window/firmware, never by
 * an A53 read.  Blocking it here makes that rule structural instead of a
 * convention that every new script has to remember.
 */
static const struct {
	u32 start;
	u32 end;
	const char *why;
} regio_never[] = {
	{ 0x1fa10000, 0x1fa11fff, "SPI-NAND controller" },
	{ 0x80000000, 0xffffffff, "DRAM" },
	{ 0x1e900000, 0x1ebfffff, "NPU internal (A53 read hangs the box)" },
};

/* Readable, but writes refused: the hardware does not survive being poked
 * here, and no experiment in this project needs to.
 *
 *  0x1fa20000-0x1fa203ff  chip_scu: clock dividers and CPU PLL
 *                         (clk-en7523.c base_reg 0x1b4/0x1b8/0x1bc/0x1fc,
 *                         airoha-cpu-pmdomain.c CPUPLL_SDM_PCW 0x2b4).
 *                         Writing 1fa201bc<-0 (bus 300->600MHz) hung the box
 *                         on 2026-10-31; bus div_sel==0 is illegal per vendor
 *                         private/tcci/cpu_bus_arm_test.c:960.  Reads stay
 *                         allowed because they are how we verified the clock
 *                         tree in the first place.
 *  0x1fbf0000-0x1fbf013f  uart1 + watchdog.  Writing the WDT load/control
 *                         registers can reset the board, and the driver's
 *                         wdt_freq is a probe-time cache so a raw write here
 *                         would make the timeout silently wrong.
 */
static const struct {
	u32 start;
	u32 end;
	const char *why;
} regio_ro[] = {
	{ 0x1fa20000, 0x1fa203ff, "clock/PLL (read-only)" },
	{ 0x1fbf0000, 0x1fbf013f, "UART1 + watchdog (read-only)" },
	{ 0x1fb00000, 0x1fb00fff, "scuclk block (read-only)" },
};

struct regio_range {
	u32 start;
	u32 end;
};

#define REGIO_MAX_RANGES 16

static struct regio_range regio_rd[REGIO_MAX_RANGES];
static int regio_rd_n;
static struct regio_range regio_wr[REGIO_MAX_RANGES];
static int regio_wr_n;

static int regio_parse_ranges(const char *s, struct regio_range *out, int max)
{
	int n = 0;
	char *orig, *buf, *tok;

	if (!s || !*s)
		return 0;

	orig = buf = kstrdup(s, GFP_KERNEL);
	if (!orig)
		return -ENOMEM;

	for (tok = strsep(&buf, ","); tok && n < max; tok = strsep(&buf, ",")) {
		unsigned long long a, b;
		char *dash;

		while (*tok == ' ')
			tok++;
		if (!*tok)
			continue;

		dash = strchr(tok, '-');
		if (!dash)
			continue;
		*dash = '\0';

		if (kstrtoull(tok, 16, &a) || kstrtoull(dash + 1, 16, &b))
			continue;
		if (a > b || b > 0xffffffffULL)
			continue;

		out[n].start = (u32)a;
		out[n].end = (u32)b;
		n++;
	}

	kfree(orig);
	return n;
}

static bool regio_in(const struct regio_range *r, int n, u32 addr)
{
	int i;

	for (i = 0; i < n; i++)
		if (addr >= r[i].start && addr <= r[i].end)
			return true;
	return false;
}

/* A dump is ioremapped as one block, so [lo, hi] must sit inside ONE allowed
 * range.  Two endpoints in two different ranges would leave a hole in the
 * middle that nobody checked (the fixed 2026-11-14 hole is the NPU hang zone).
 */
static bool regio_span(u32 lo, u32 hi)
{
	int i;

	if (lo > hi)
		return false;
	for (i = 0; i < regio_rd_n; i++)
		if (lo >= regio_rd[i].start && hi <= regio_rd[i].end)
			return true;
	return false;
}

static const char *regio_forbidden(u32 addr)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(regio_never); i++)
		if (addr >= regio_never[i].start && addr <= regio_never[i].end)
			return regio_never[i].why;
	return NULL;
}

/* Same as regio_forbidden() for a closed [lo, hi] span.  A "d" dump is one
 * ioremap + n readl()s, so checking only the first and last address of the
 * span is not enough: a span that starts in one allowed range and ends in
 * another walks over everything in between.  (Concretely: base 0x1e860000 in
 * the NPU counter window and end 0x1ec00000 in the NPU mailbox window would
 * walk straight through the 0x1e900000-0x1ebfffff hang zone.  It was accepted
 * before this guard existed because regio_in() only looked at the endpoints.)
 */
static const char *regio_forbidden_span(u32 lo, u32 hi)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(regio_never); i++)
		if (lo <= regio_never[i].end && hi >= regio_never[i].start)
			return regio_never[i].why;
	return NULL;
}

/* Read-only regions: readable, but a write is refused.  Split out from
 * regio_never so the clock tree stays inspectable while the two hardware
 * blocks that hang or reset the box on a stray write stay protected.
 */
static const char *regio_write_ro(u32 addr)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(regio_ro); i++)
		if (addr >= regio_ro[i].start && addr <= regio_ro[i].end)
			return regio_ro[i].why;
	return NULL;
}

static char *regio_out;
static DEFINE_MUTEX(regio_lock);
static struct dentry *regio_dentry;

/* Append helper: keeps track of how much of regio_out is used. */
struct regio_buf {
	char *p;
	size_t len;
	size_t cap;
};

static void rb_printf(struct regio_buf *b, const char *fmt, ...)
{
	va_list ap;
	int n;

	if (b->len >= b->cap)
		return;
	va_start(ap, fmt);
	n = vsnprintf(b->p + b->len, b->cap - b->len, fmt, ap);
	va_end(ap);
	if (n > 0)
		b->len += min((size_t)n, b->cap - b->len - 1);
}

static ssize_t regio_read(struct file *f, char __user *ubuf, size_t len,
			  loff_t *ppos)
{
	ssize_t ret;

	mutex_lock(&regio_lock);
	ret = simple_read_from_buffer(ubuf, len, ppos, regio_out,
				      strlen(regio_out));
	mutex_unlock(&regio_lock);

	return ret;
}

static ssize_t regio_write(struct file *f, const char __user *ubuf, size_t len,
			   loff_t *ppos)
{
	char *orig, *cmd, *tok, *op;
	unsigned long long addr_ull, val_ull;
	u32 args[REGIO_MAX_ARGS];
	int nargs = 0;
	struct regio_buf b;
	ssize_t ret = len;

	if (len >= REGIO_MAX_CMD)
		return -EINVAL;

	orig = cmd = kzalloc(REGIO_MAX_CMD, GFP_KERNEL);
	if (!orig)
		return -ENOMEM;

	if (copy_from_user(orig, ubuf, len)) {
		kfree(orig);
		return -EFAULT;
	}
	orig[len] = '\0';

	mutex_lock(&regio_lock);
	b.p = regio_out;
	b.len = 0;
	b.cap = REGIO_OUT_SIZE;

	/* strsep over every whitespace-separated token, so a command never
	 * depends on how the shell happened to split the write().
	 */
	tok = strsep(&cmd, " \t\n\r");
	while (tok && !*tok)
		tok = strsep(&cmd, " \t\n\r");

	if (!tok) {
		rb_printf(&b, "ERR empty command\n");
		goto out;
	}
	op = tok;

	for (tok = strsep(&cmd, " \t\n\r"); tok; tok = strsep(&cmd, " \t\n\r")) {
		if (!*tok)
			continue;
		if (kstrtoull(tok, 16, &addr_ull))
			continue;
		if (nargs < REGIO_MAX_ARGS)
			args[nargs++] = (u32)addr_ull;
	}

	if (!strcmp(op, "r")) {
		void __iomem *p;
		const char *why;

		if (nargs < 1) {
			rb_printf(&b, "ERR usage: r <addr>\n");
			goto out;
		}
		why = regio_forbidden(args[0]);
		if (why) {
			rb_printf(&b, "ERR %08x is %s\n", args[0], why);
			goto out;
		}
		if (!regio_in(regio_rd, regio_rd_n, args[0])) {
			rb_printf(&b, "ERR %08x outside read_ranges\n", args[0]);
			goto out;
		}
		p = ioremap(args[0] & ~0x3UL, 4);
		if (!p) {
			rb_printf(&b, "ERR ioremap %08x\n", args[0]);
			goto out;
		}
		rb_printf(&b, "%08x = %08x\n", args[0] & ~0x3UL, readl(p));
		iounmap(p);

	} else if (!strcmp(op, "d")) {
		void __iomem *p;
		u32 base, i, n;
		const char *why;

		if (nargs < 2) {
			rb_printf(&b, "ERR usage: d <addr> <count>\n");
			goto out;
		}
		base = args[0] & ~0x3UL;
		n = args[1];
		if (n == 0 || n > REGIO_MAX_DUMP) {
			rb_printf(&b, "ERR count must be 1..%d\n", REGIO_MAX_DUMP);
			goto out;
		}
		why = regio_forbidden(base);
		if (why) {
			rb_printf(&b, "ERR %08x is %s\n", base, why);
			goto out;
		}
		/* The whole span, not just its endpoints (see
		 * regio_forbidden_span() and regio_span()).
		 */
		why = regio_forbidden_span(base, base + (n - 1) * 4);
		if (why) {
			rb_printf(&b, "ERR %08x..%08x crosses %s\n",
				  base, base + (n - 1) * 4, why);
			goto out;
		}
		if (!regio_span(base, base + (n - 1) * 4)) {
			rb_printf(&b, "ERR %08x..%08x outside read_ranges\n",
				  base, base + (n - 1) * 4);
			goto out;
		}
		p = ioremap(base, n * 4);
		if (!p) {
			rb_printf(&b, "ERR ioremap %08x len %u\n", base, n * 4);
			goto out;
		}
		for (i = 0; i < n; i++)
			rb_printf(&b, "%08x = %08x\n", base + i * 4,
				  readl(p + i * 4));
		iounmap(p);

	} else if (!strcmp(op, "m")) {
		int i;

		if (nargs < 1) {
			rb_printf(&b, "ERR usage: m <addr> [addr...]\n");
			goto out;
		}
		for (i = 0; i < nargs; i++) {
			void __iomem *p;
			const char *why;
			u32 a = args[i] & ~0x3UL;

			why = regio_forbidden(a);
			if (why) {
				rb_printf(&b, "%08x = ERR is %s\n", a, why);
				continue;
			}
			if (!regio_in(regio_rd, regio_rd_n, a)) {
				rb_printf(&b, "%08x = ERR outside read_ranges\n", a);
				continue;
			}
			p = ioremap(a, 4);
			if (!p) {
				rb_printf(&b, "%08x = ERR ioremap\n", a);
				continue;
			}
			rb_printf(&b, "%08x = %08x\n", a, readl(p));
			iounmap(p);
		}

	} else if (!strcmp(op, "w")) {
		void __iomem *p;
		const char *why;

		if (nargs < 2) {
			rb_printf(&b, "ERR usage: w <addr> <val>\n");
			goto out;
		}
		if (!allow_write) {
			rb_printf(&b, "ERR writes disabled (allow_write=0)\n");
			goto out;
		}
		why = regio_forbidden(args[0]);
		if (why) {
			rb_printf(&b, "ERR %08x is %s\n", args[0], why);
			goto out;
		}
		why = regio_write_ro(args[0]);
		if (why) {
			rb_printf(&b, "ERR %08x is %s\n", args[0], why);
			goto out;
		}
		if (!regio_in(regio_wr, regio_wr_n, args[0])) {
			rb_printf(&b, "ERR %08x outside write_ranges\n", args[0]);
			goto out;
		}
		val_ull = args[1];
		p = ioremap(args[0] & ~0x3UL, 4);
		if (!p) {
			rb_printf(&b, "ERR ioremap %08x\n", args[0]);
			goto out;
		}
		writel((u32)val_ull, p);
		iounmap(p);
		rb_printf(&b, "OK %08x <= %08x\n", args[0] & ~0x3UL, (u32)val_ull);

	} else {
		rb_printf(&b, "ERR op %s (use r/d/m/w)\n", op);
	}

out:
	regio_out[b.len] = '\0';
	mutex_unlock(&regio_lock);
	kfree(orig);
	return ret;
}

static const struct file_operations regio_fops = {
	.owner = THIS_MODULE,
	.read = regio_read,
	.write = regio_write,
	.llseek = default_llseek,
};

static int __init regio_init(void)
{
	regio_rd_n = regio_parse_ranges(read_ranges, regio_rd, REGIO_MAX_RANGES);
	regio_wr_n = regio_parse_ranges(write_ranges, regio_wr, REGIO_MAX_RANGES);

	regio_out = kzalloc(REGIO_OUT_SIZE, GFP_KERNEL);
	if (!regio_out)
		return -ENOMEM;

	regio_dentry = debugfs_create_file("regio", 0600, NULL, NULL,
					   &regio_fops);
	if (IS_ERR_OR_NULL(regio_dentry)) {
		pr_err("regio: cannot create debugfs entry\n");
		kfree(regio_out);
		return -ENODEV;
	}

	snprintf(regio_out, REGIO_OUT_SIZE, "ready\n");
	pr_info("regio: %d read ranges, %d write ranges, writes %s\n",
		regio_rd_n, regio_wr_n, allow_write ? "ENABLED" : "disabled");
	return 0;
}

static void __exit regio_exit(void)
{
	debugfs_remove(regio_dentry);
	kfree(regio_out);
}

module_init(regio_init);
module_exit(regio_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("XR1710G AN7581 MMIO debug window");
