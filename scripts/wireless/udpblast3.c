// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * udpblast3 - paced multi-socket UDP source for A-path measurements.
 *
 * Each process owns several UDP sockets and spreads one aggregate pacing
 * schedule over them, so a single process can offer a rate that a
 * single-socket sender cannot.  Every socket is bound to the requested
 * interface when -i is used, which keeps the traffic on the AP netdev
 * under test instead of leaking out of the LAN bridge.
 *
 * The final line on stdout is machine readable:
 *
 *   SUMMARY dest=... port=... sockets=... pkt_size=... requested_mbps=...
 *           duration_s=... sent_pkts=... sent_bytes=... achieved_mbps=...
 *           send_errors=...
 *
 * Progress goes to stderr.  `--rate` is the aggregate UDP payload rate of
 * this process, not the wire rate; IP/UDP and 802.11 headers come on top.
 *
 * Build (device):
 *   aarch64-openwrt-linux-musl-gcc -O2 -Wall -Wextra -static \
 *       -o udpblast3 udpblast3.c
 */

#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <getopt.h>
#include <net/if.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_PORT		5201
#define DEFAULT_RATE_MBPS	1000.0
#define DEFAULT_SECONDS		10.0
#define DEFAULT_SOCKETS		1
#define DEFAULT_PKT_SIZE	1472
#define DEFAULT_SNDBUF		(1U << 18)
#define MAX_SOCKETS		64
#define MIN_PKT_SIZE		18
#define MAX_PKT_SIZE		65507
#define TICK_NS			1000000LL	/* 1 ms pacing tick */
#define MAX_BURST_TICKS		4

static volatile sig_atomic_t stop_requested;

static void handle_signal(int sig)
{
	(void)sig;
	stop_requested = 1;
}

static void usage(FILE *out)
{
	fprintf(out,
"Usage: udpblast3 -d DEST [options]\n"
"\n"
"  -d, --dest ADDR       destination IPv4/IPv6 address (required)\n"
"  -p, --port PORT       destination UDP port (default %d)\n"
"  -r, --rate MBPS       aggregate UDP payload rate (default %.0f)\n"
"  -t, --seconds SECS    duration in seconds (default %.0f)\n"
"  -s, --sockets N       sockets per process, 1..%d (default %d)\n"
"  -b, --bytes N         UDP payload bytes, %d..%d (default %d)\n"
"  -i, --iface IFACE     bind every socket to this interface\n"
"  -S, --source ADDR     source IPv4/IPv6 address to bind\n"
"  -T, --tos N           IP TOS/DSCP byte, 0..255\n"
"  -q, --quiet           no once-per-second progress on stderr\n"
"  -h, --help            this help\n"
"\n"
"The program prints one SUMMARY line on stdout.  On SIGINT/SIGTERM it\n"
"stops at the next pacing tick and still prints the SUMMARY line.\n",
		DEFAULT_PORT, DEFAULT_RATE_MBPS, DEFAULT_SECONDS,
		MAX_SOCKETS, DEFAULT_SOCKETS, MIN_PKT_SIZE, MAX_PKT_SIZE,
		DEFAULT_PKT_SIZE);
}

static int parse_long(const char *s, long min, long max, long *out)
{
	char *end;
	long v;

	errno = 0;
	v = strtol(s, &end, 10);
	if (errno || end == s || *end != '\0' || v < min || v > max)
		return -1;
	*out = v;
	return 0;
}

static int parse_double(const char *s, double min, double max, double *out)
{
	char *end;
	double v;

	errno = 0;
	v = strtod(s, &end);
	if (errno || end == s || *end != '\0' || v < min || v > max)
		return -1;
	*out = v;
	return 0;
}

static long long now_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static int fill_addr(const char *addr, int port, struct sockaddr_storage *ss,
		     socklen_t *sslen)
{
	struct sockaddr_in *sin4 = (struct sockaddr_in *)ss;
	struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)ss;

	memset(ss, 0, sizeof(*ss));
	if (inet_pton(AF_INET, addr, &sin4->sin_addr) == 1) {
		sin4->sin_family = AF_INET;
		sin4->sin_port = htons(port);
		*sslen = sizeof(*sin4);
		return AF_INET;
	}
	if (inet_pton(AF_INET6, addr, &sin6->sin6_addr) == 1) {
		sin6->sin6_family = AF_INET6;
		sin6->sin6_port = htons(port);
		*sslen = sizeof(*sin6);
		return AF_INET6;
	}
	return -1;
}

int main(int argc, char **argv)
{
	static const struct option long_opts[] = {
		{ "dest",	required_argument,	NULL,	'd' },
		{ "port",	required_argument,	NULL,	'p' },
		{ "rate",	required_argument,	NULL,	'r' },
		{ "seconds",	required_argument,	NULL,	't' },
		{ "sockets",	required_argument,	NULL,	's' },
		{ "bytes",	required_argument,	NULL,	'b' },
		{ "iface",	required_argument,	NULL,	'i' },
		{ "source",	required_argument,	NULL,	'S' },
		{ "tos",	required_argument,	NULL,	'T' },
		{ "quiet",	no_argument,		NULL,	'q' },
		{ "help",	no_argument,		NULL,	'h' },
		{ NULL,		0,			NULL,	0 },
	};
	const char *dest = NULL, *iface = NULL, *src = NULL;
	long port = DEFAULT_PORT, nsocks = DEFAULT_SOCKETS;
	long pkt_size = DEFAULT_PKT_SIZE, tos = -1;
	double rate_mbps = DEFAULT_RATE_MBPS, seconds = DEFAULT_SECONDS;
	int quiet = 0, family, opt, i, ret = 0;
	struct sockaddr_storage dst, src_ss;
	socklen_t dst_len = 0, src_len = 0;
	int fds[MAX_SOCKETS];
	char *buf = NULL;
	long long start, deadline, next_tick, last_report, last_tick;
	long long sent_pkts = 0, sent_bytes = 0, send_errors = 0;
	double pps, credit = 0.0;
	int burst_cap;

	for (i = 0; i < MAX_SOCKETS; i++)
		fds[i] = -1;

	opterr = 1;
	while ((opt = getopt_long(argc, argv, "d:p:r:t:s:b:i:S:T:qh",
				  (const struct option *)long_opts, NULL)) != -1) {
		switch (opt) {
		case 'd':
			dest = optarg;
			break;
		case 'p':
			if (parse_long(optarg, 1, 65535, &port))
				goto bad_value;
			break;
		case 'r':
			if (parse_double(optarg, 0.0, 1000000.0, &rate_mbps))
				goto bad_value;
			break;
		case 't':
			if (parse_double(optarg, 0.001, 86400.0, &seconds))
				goto bad_value;
			break;
		case 's':
			if (parse_long(optarg, 1, MAX_SOCKETS, &nsocks))
				goto bad_value;
			break;
		case 'b':
			if (parse_long(optarg, MIN_PKT_SIZE, MAX_PKT_SIZE,
				       &pkt_size))
				goto bad_value;
			break;
		case 'i':
			if (strlen(optarg) >= IFNAMSIZ) {
				fprintf(stderr, "udpblast3: interface name too long\n");
				return 2;
			}
			iface = optarg;
			break;
		case 'S':
			src = optarg;
			break;
		case 'T':
			if (parse_long(optarg, 0, 255, &tos))
				goto bad_value;
			break;
		case 'q':
			quiet = 1;
			break;
		case 'h':
			usage(stdout);
			return 0;
		default:
			usage(stderr);
			return 2;
		}
	}
	if (optind != argc) {
		fprintf(stderr, "udpblast3: unexpected argument: %s\n", argv[optind]);
		return 2;
	}
	if (!dest) {
		fprintf(stderr, "udpblast3: --dest is required\n");
		usage(stderr);
		return 2;
	}

	family = fill_addr(dest, (int)port, &dst, &dst_len);
	if (family < 0) {
		fprintf(stderr, "udpblast3: not an IPv4/IPv6 address: %s\n", dest);
		return 2;
	}
	if (src && fill_addr(src, 0, &src_ss, &src_len) != family) {
		fprintf(stderr, "udpblast3: --source must match the destination family\n");
		return 2;
	}

	buf = malloc((size_t)pkt_size);
	if (!buf) {
		perror("udpblast3: malloc");
		return 1;
	}
	memset(buf, 0x5a, (size_t)pkt_size);

	for (i = 0; i < nsocks; i++) {
		int fd = socket(family, SOCK_DGRAM | SOCK_CLOEXEC, 0);
		int sndbuf = (int)DEFAULT_SNDBUF;

		if (fd < 0) {
			fprintf(stderr, "udpblast3: socket: %s\n", strerror(errno));
			ret = 1;
			goto out;
		}
		fds[i] = fd;

		/* Best effort: the kernel clamps this to net.core.wmem_max. */
		setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));

		if (iface &&
		    setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE,
			       iface, strlen(iface) + 1) < 0) {
			fprintf(stderr, "udpblast3: bind to %s: %s\n",
				iface, strerror(errno));
			ret = 1;
			goto out;
		}
		if (src &&
		    bind(fd, (struct sockaddr *)&src_ss, src_len) < 0) {
			fprintf(stderr, "udpblast3: bind source: %s\n",
				strerror(errno));
			ret = 1;
			goto out;
		}
		if (tos >= 0) {
			int t = (int)tos;

			if (family == AF_INET)
				setsockopt(fd, IPPROTO_IP, IP_TOS, &t, sizeof(t));
			else
				setsockopt(fd, IPPROTO_IPV6, IPV6_TCLASS,
					   &t, sizeof(t));
		}
	}

	{
		struct sigaction sa;

		memset(&sa, 0, sizeof(sa));
		sa.sa_handler = handle_signal;
		sigemptyset(&sa.sa_mask);
		sa.sa_flags = 0;	/* interrupt a blocked sendto() */
		sigaction(SIGINT, &sa, NULL);
		sigaction(SIGTERM, &sa, NULL);
		sigaction(SIGHUP, &sa, NULL);
	}

	pps = rate_mbps * 1000000.0 / ((double)pkt_size * 8.0);
	burst_cap = (int)(pps / 1000.0 * MAX_BURST_TICKS) + 1;
	if (burst_cap < 1)
		burst_cap = 1;
	if (burst_cap > 65536)
		burst_cap = 65536;

	start = now_ns();
	deadline = start + (long long)(seconds * 1000000000.0);
	last_tick = start;
	last_report = start;
	next_tick = start + TICK_NS;

	if (!quiet)
		fprintf(stderr,
			"udpblast3: dest=%s port=%ld sockets=%ld pkt_size=%ld "
			"rate=%.0f Mbit/s seconds=%.0f iface=%s\n",
			dest, port, nsocks, pkt_size, rate_mbps, seconds,
			iface ? iface : "-");

	while (!stop_requested) {
		long long now = now_ns();
		long long tick_now;
		long n, j;
		int sock = 0;

		if (now >= deadline)
			break;

		/* Credit the time since the previous tick against the rate. */
		credit += pps * (double)(now - last_tick) / 1000000000.0;
		last_tick = now;
		n = (long)credit;
		if (n > burst_cap) {
			/*
			 * A blocked send or a long scheduler delay must not
			 * turn into a multi-millisecond burst that hides the
			 * offered rate; drop the excess credit instead.
			 */
			n = burst_cap;
			credit = 0.0;
		} else {
			credit -= (double)n;
		}

		for (j = 0; j < n && !stop_requested; j++) {
			ssize_t rc;

			rc = sendto(fds[sock], buf, (size_t)pkt_size, 0,
				    (struct sockaddr *)&dst, dst_len);
			if (rc < 0) {
				if (errno == EINTR) {
					if (stop_requested)
						break;
					continue;
				}
				send_errors++;
				/*
				 * A closed destination port or a transient
				 * qdisc/ENOBUFS condition is not fatal.  A
				 * hard permission/routing error would repeat
				 * forever, so stop after a short burst of
				 * nothing but errors.
				 */
				if (sent_pkts == 0 && send_errors >= 1000) {
					fprintf(stderr,
						"udpblast3: sendto: %s\n",
						strerror(errno));
					goto done;
				}
			} else {
				sent_pkts++;
				sent_bytes += rc;
			}
			sock++;
			if (sock >= nsocks)
				sock = 0;
		}

		now = now_ns();
		if (!quiet && now - last_report >= 1000000000LL) {
			double elapsed = (double)(now - start) / 1000000000.0;

			fprintf(stderr,
				"udpblast3: %.0fs sent=%lld pkts %.1f Mbit/s "
				"errors=%lld\n",
				elapsed, sent_pkts,
				elapsed > 0.0 ?
					(double)sent_bytes * 8.0 / elapsed / 1000000.0 :
					0.0,
				send_errors);
			last_report = now;
		}

		tick_now = now_ns();
		if (next_tick <= tick_now) {
			next_tick += TICK_NS;
			if (next_tick <= tick_now)
				next_tick = tick_now + TICK_NS;
			continue;
		}
		while (!stop_requested && now_ns() < next_tick) {
			struct timespec ts;

			ts.tv_sec = (time_t)(next_tick / 1000000000LL);
			ts.tv_nsec = (long)(next_tick % 1000000000LL);
			if (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME,
					    &ts, NULL) == EINTR &&
			    !stop_requested)
				continue;
			break;
		}
		next_tick += TICK_NS;
	}

done:
	{
		long long end = now_ns();
		double elapsed = (double)(end - start) / 1000000000.0;
		double achieved = elapsed > 0.0 ?
			(double)sent_bytes * 8.0 / elapsed / 1000000.0 : 0.0;

		printf("SUMMARY dest=%s port=%ld sockets=%ld pkt_size=%ld "
		       "requested_mbps=%.1f duration_s=%.3f duration_ms=%lld "
		       "sent_pkts=%lld sent_bytes=%lld achieved_mbps=%.3f "
		       "send_errors=%lld\n",
		       dest, port, nsocks, pkt_size, rate_mbps, elapsed,
		       (long long)(elapsed * 1000.0), sent_pkts, sent_bytes,
		       achieved, send_errors);
		if (sent_pkts == 0 && rate_mbps > 0.0)
			ret = 1;
	}

out:
	for (i = 0; i < nsocks; i++)
		if (fds[i] >= 0)
			close(fds[i]);
	free(buf);
	return ret;

bad_value:
	fprintf(stderr, "udpblast3: invalid value for -%c: %s\n", opt, optarg);
	return 2;
}
