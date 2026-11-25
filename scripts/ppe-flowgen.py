#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Generate many distinct UDP 5-tuples for airoha PPE capacity experiments.

This is a traffic source, not a measurement result.  It sends UDP and nothing
else: it never writes a device, a PPE register, an SRAM/DRAM table, a flowtable
entry, procfs or sysfs, and it starts no subprocess.

Every flow gets its own UDP socket, a distinct destination IPv4 address and a
distinct source port.  The destination addresses are sampled from --dst-prefix
instead of being walked sequentially, because the PPE hash is a bitwise-linear
mixer: consecutive destination addresses and consecutive source ports cancel
each other out, and the folded hash then lands in only a few hundred of the
32768 slots - the failure behind the invalid 8192-16383 capacity sweeps.

The hash is a copy of airoha_ppe_foe_get_entry_hash() for
PPE_PKT_TYPE_IPV4_HNAPT, and the fold is airoha_ppe_fold_hash() from
target/linux/airoha/patches-7.4/212-net-airoha-address-PPE-entries-from-their-own-table.patch:

    32768 entries -> hash & (n - 1)
    24576 entries -> ((hash >> 13) % 3) * 8192 + (hash & 8191)
    other         -> hash % n

--plan recomputes both for the three table geometries and prints how the
generated flows land in the four 8192-slot windows
[0..8191], [8192..16383], [16384..24575] and [24576..32767], without creating a
socket.  --dry-run prints the flow set and creates no socket either.

Usage:
    scripts/ppe-flowgen.py --plan
    scripts/ppe-flowgen.py --dry-run --dst-prefix 198.18.0.0/16
    scripts/ppe-flowgen.py --rate 200000 --duration 30 \\
        --dst-prefix 198.18.0.0/16 --src-ip 192.168.1.2
"""

import argparse
import collections
import contextlib
import errno
import io
import ipaddress
import math
import random
import resource
import socket
import sys
import time

# One PPE SRAM table without flow counters: 8192 entries (13 bits).  With flow
# counters each PPE keeps 4096 data entries, so both PPEs hold 8192 and the
# DRAM region adds 16384, which is where 32768 / 24576 / 16384 come from.
PPE_SRAM_BITS = 13
PPE_SRAM_NUM_ENTRIES = 1 << PPE_SRAM_BITS
PPE_HASH_GEOMETRIES = (32768, 24576, 16384)
HASH_WINDOW = (1 << (PPE_SRAM_BITS + 2)) - 1  # 32767, the 32768-entry table
SLICES = tuple(
    (base, base + PPE_SRAM_NUM_ENTRIES - 1)
    for base in range(0, HASH_WINDOW + 1, PPE_SRAM_NUM_ENTRIES)
)

DEFAULT_DST_PREFIX = "198.18.0.0/16"
DEFAULT_FLOWS = 16384
DEFAULT_SRC_PORTS = (1024, 65535)
DEFAULT_DST_PORT = 9
DEFAULT_SEED = 0x5EED1234
# --plan has no packet source address to read from, so the IPv4 hash preview
# uses this TEST-NET-1 address when --src-ip is not given.  The bucket shares
# only depend on the varied destination address and source port; the source
# address XOR-shifts the sample without narrowing it.
PREVIEW_SRC_IP = "192.0.2.1"

PAYLOAD = b"PPE-flowgen"
MAX_BIND_ATTEMPTS = 16

Config = collections.namedtuple(
    "Config",
    "flows dst_prefix src_ip src_ports dst_port rate duration seed",
)
Flow = collections.namedtuple("Flow", "src_ip src_port dst_ip dst_port")
SendResult = collections.namedtuple(
    "SendResult", "sent errors first_error elapsed interrupted"
)


def _positive_int(text):
    try:
        value = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError("expected a positive integer: %r" % text)
    if value <= 0:
        raise argparse.ArgumentTypeError("expected a positive integer: %r" % text)
    return value


def _positive_float(text):
    try:
        value = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError("expected a positive number: %r" % text)
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError("expected a positive number: %r" % text)
    return value


def _dst_prefix(text):
    try:
        network = ipaddress.ip_network(text, strict=False)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("invalid IPv4 prefix %r: %s" % (text, exc))
    if network.version != 4:
        raise argparse.ArgumentTypeError("--dst-prefix must be an IPv4 prefix")
    return network


def _src_ip(text):
    try:
        return ipaddress.IPv4Address(text)
    except ipaddress.AddressValueError as exc:
        raise argparse.ArgumentTypeError("invalid IPv4 address %r: %s" % (text, exc))


def _dst_port(text):
    try:
        value = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError("expected a UDP port: %r" % text)
    if not 1 <= value <= 65535:
        raise argparse.ArgumentTypeError("UDP port must be in 1..65535: %r" % text)
    return value


def _port_range(text):
    if text.count("-") != 1:
        raise argparse.ArgumentTypeError("expected LOW-HIGH, for example 1024-65535")
    low_text, high_text = text.split("-")
    try:
        low, high = int(low_text), int(high_text)
    except ValueError:
        raise argparse.ArgumentTypeError("expected numeric LOW-HIGH, for example 1024-65535")
    if not 1 <= low <= high <= 65535:
        raise argparse.ArgumentTypeError("source ports must satisfy 1 <= LOW <= HIGH <= 65535")
    return low, high


def build_parser():
    parser = argparse.ArgumentParser(
        prog="ppe-flowgen.py",
        description=(
            "Generate UDP flows with distinct destination IPv4 addresses and distinct "
            "source ports for airoha PPE capacity/DRAM experiments. This is a traffic "
            "source, not a measurement."
        ),
        epilog=(
            "examples:\n"
            "  %(prog)s --plan\n"
            "  %(prog)s --dry-run --dst-prefix 198.18.0.0/16\n"
            "  %(prog)s --rate 200000 --duration 30 --dst-prefix 198.18.0.0/16 "
            "--src-ip 192.168.1.2\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--flows",
        type=_positive_int,
        default=DEFAULT_FLOWS,
        metavar="N",
        help="number of distinct UDP flows, one socket each (default: %(default)s)",
    )
    parser.add_argument(
        "--dst-prefix",
        type=_dst_prefix,
        default=DEFAULT_DST_PREFIX,
        metavar="CIDR",
        help="IPv4 prefix to sample destination addresses from; network and broadcast "
        "addresses are skipped for prefixes of /30 and larger (default: %(default)s)",
    )
    parser.add_argument(
        "--src-ip",
        type=_src_ip,
        default=None,
        metavar="ADDR",
        help="local IPv4 address to bind every flow socket to; also used by --plan "
        "for the hash preview (default: wildcard, the kernel picks the routed address)",
    )
    parser.add_argument(
        "--src-port-cycle",
        nargs="?",
        const="1024-65535",
        type=_port_range,
        default=DEFAULT_SRC_PORTS,
        metavar="LOW-HIGH",
        help="range to sample one distinct source port per flow from, sampled instead "
        "of walked sequentially; the bare flag selects 1024-65535 (default: 1024-65535)",
    )
    parser.add_argument(
        "--dst-port",
        type=_dst_port,
        default=DEFAULT_DST_PORT,
        metavar="PORT",
        help="destination UDP port of every flow (default: %(default)s)",
    )
    parser.add_argument(
        "--rate",
        type=_positive_float,
        metavar="PPS",
        help="total packets per second across all flows; required unless "
        "--plan/--dry-run/--self-test is used",
    )
    parser.add_argument(
        "--duration",
        type=_positive_float,
        metavar="SECONDS",
        help="send for this many seconds; required with --rate",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--plan",
        action="store_true",
        help="print the four-interval fold_hash preview for 32768/24576/16384 entries "
        "and exit; no sockets, no packets",
    )
    mode.add_argument(
        "--dry-run",
        action="store_true",
        help="print the planned flow set and exit; no sockets, no packets",
    )
    mode.add_argument(
        "--self-test",
        action="store_true",
        help="run offline assertions and exit; no root, no sockets, no packets",
    )
    return parser


def _config_from_args(parser, args):
    if not (args.plan or args.dry_run or args.self_test):
        missing = []
        if args.rate is None:
            missing.append("--rate")
        if args.duration is None:
            missing.append("--duration")
        if missing:
            parser.error(
                "%s required to send traffic; use --plan or --dry-run to preview, "
                "or --self-test for offline checks" % " and ".join(missing)
            )

    return Config(
        flows=args.flows,
        dst_prefix=args.dst_prefix,
        src_ip=str(args.src_ip) if args.src_ip is not None else None,
        src_ports=args.src_port_cycle,
        dst_port=args.dst_port,
        rate=args.rate,
        duration=args.duration,
        seed=DEFAULT_SEED,
    )


def _usable_address_offsets(network):
    """Return (first, stop) offsets into the prefix, excluding /30+ edge slots."""
    total = network.num_addresses
    if total >= 4:
        return 1, total - 1
    if total == 2:
        # RFC 3021: both addresses of a /31 are usable.
        return 0, 2
    return 0, 1


def build_flows(cfg):
    """Build the flow tuples; the random sample keeps the PPE hash spread out."""
    first, stop = _usable_address_offsets(cfg.dst_prefix)
    usable = stop - first
    port_low, port_high = cfg.src_ports
    usable_ports = port_high - port_low + 1
    if cfg.flows > usable:
        raise ValueError(
            "--dst-prefix %s has %d usable IPv4 addresses, fewer than --flows %d; "
            "widen the prefix or lower --flows" % (cfg.dst_prefix, usable, cfg.flows)
        )
    if cfg.flows > usable_ports:
        raise ValueError(
            "--src-port-cycle %d-%d has %d usable source ports, fewer than "
            "--flows %d; widen the range or lower --flows"
            % (port_low, port_high, usable_ports, cfg.flows)
        )

    rng = random.Random(cfg.seed)
    offsets = rng.sample(range(first, stop), cfg.flows)
    source_ports = rng.sample(range(port_low, port_high + 1), cfg.flows)
    base = int(cfg.dst_prefix.network_address)
    dsts = [str(ipaddress.IPv4Address(base + offset)) for offset in offsets]
    src_ip = cfg.src_ip if cfg.src_ip is not None else PREVIEW_SRC_IP
    return [
        Flow(src_ip, source_port, dst_ip, cfg.dst_port)
        for source_port, dst_ip in zip(source_ports, dsts)
    ]


def _flow_hash(flow):
    """Replicate airoha_ppe_foe_get_entry_hash() for IPv4 HNAPT."""
    # dest_port is the first u16 of the tuple struct, so it is the low half of
    # the u32 ports view on the little-endian airoha targets.
    hv1 = (flow.dst_port & 0xFFFF) | ((flow.src_port & 0xFFFF) << 16)
    hv2 = int(ipaddress.IPv4Address(flow.dst_ip))
    hv3 = int(ipaddress.IPv4Address(flow.src_ip))
    u32 = 0xFFFFFFFF
    mix = (hv1 & hv2) | ((~hv1 & u32) & hv3)
    mix = ((mix >> 24) | ((mix & 0xFFFFFF) << 8)) & u32
    mix ^= hv1 ^ hv2 ^ hv3
    mix ^= mix >> 16
    return mix & u32


def ppe_fold_hash(hash_value, num_entries):
    """Replicate airoha_ppe_fold_hash() from patch 212."""
    if num_entries & (num_entries - 1) == 0:
        return hash_value & (num_entries - 1)
    if num_entries == 3 * PPE_SRAM_NUM_ENTRIES:
        return ((hash_value >> PPE_SRAM_BITS) % 3) * PPE_SRAM_NUM_ENTRIES + (
            hash_value & (PPE_SRAM_NUM_ENTRIES - 1)
        )
    return hash_value % num_entries


def _slice_counts(values):
    counts = [0] * len(SLICES)
    for value in values:
        counts[value >> PPE_SRAM_BITS] += 1
    return counts


def _print_slice_rows(counts, total, table_entries):
    for (low, high), count in zip(SLICES, counts):
        share = 100.0 * count / total if total else 0.0
        note = " (outside this table)" if low >= table_entries else ""
        label = "[%d..%d]" % (low, high)
        print("    %-16s count=%-6d share=%.2f%%%s" % (label, count, share, note))


def print_plan(flows, cfg):
    hashes = [_flow_hash(flow) for flow in flows]
    distinct_dst = len({flow.dst_ip for flow in flows})
    distinct_sport = len({flow.src_port for flow in flows})
    print("traffic source, not a measurement conclusion")
    print(
        "PLAN flows=%d distinct_dst=%d distinct_sport=%d"
        % (len(flows), distinct_dst, distinct_sport)
    )
    print(
        "     dst-prefix=%s dst-port=%d src-port-cycle=%d-%d"
        % (cfg.dst_prefix, cfg.dst_port, cfg.src_ports[0], cfg.src_ports[1])
    )
    if cfg.src_ip is None:
        print(
            "     hash-preview-src=%s (set --src-ip to hash the address the packets "
            "will actually use)" % PREVIEW_SRC_IP
        )
    else:
        print("     src-ip=%s" % cfg.src_ip)
    raw = [hash_value & HASH_WINDOW for hash_value in hashes]
    print(
        "pre-fold slices (hash & 32767; all four populated means the high fold "
        "bits are in play):"
    )
    _print_slice_rows(_slice_counts(raw), len(raw), 32768)
    print("fold_hash preview (patch 212 semantics):")
    rules = {
        32768: "hash & (n - 1)",
        24576: "((hash >> 13) % 3) * 8192 + (hash & 8191)",
        16384: "hash & (n - 1)",
    }
    for num_entries in PPE_HASH_GEOMETRIES:
        folded = [ppe_fold_hash(hash_value, num_entries) for hash_value in hashes]
        used = len(set(folded))
        print(
            "  n=%d unique_entries=%d/%d rule=%s"
            % (num_entries, used, num_entries, rules[num_entries])
        )
        _print_slice_rows(_slice_counts(folded), len(folded), num_entries)
    return 0


def print_dry_run(flows, cfg):
    print("traffic source, not a measurement conclusion")
    print("DRY-RUN: no sockets created, no packets sent")
    print(
        "would-prepare flows=%d distinct_dst=%d distinct_sport=%d dst-prefix=%s "
        "src-port-cycle=%d-%d dst-port=%d (planned values, not measured)"
        % (
            len(flows),
            len({flow.dst_ip for flow in flows}),
            len({flow.src_port for flow in flows}),
            cfg.dst_prefix,
            cfg.src_ports[0],
            cfg.src_ports[1],
            cfg.dst_port,
        )
    )
    if cfg.rate is not None and cfg.duration is not None:
        print(
            "would-send rate=%gpps duration=%gs packets=%d "
            "(requested values, not measured)"
            % (cfg.rate, cfg.duration, int(cfg.rate * cfg.duration))
        )
    return 0


def _ensure_nofile(needed):
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    unlimited = resource.RLIM_INFINITY
    if soft == unlimited or soft >= needed:
        return
    target = needed
    if hard != unlimited:
        target = min(needed, hard)
    if target <= soft:
        raise RuntimeError(
            "need %d file descriptors for the flow sockets, but RLIMIT_NOFILE is "
            "soft=%s hard=%s; raise 'ulimit -n' or lower --flows"
            % (needed, soft, hard)
        )
    try:
        resource.setrlimit(resource.RLIMIT_NOFILE, (target, hard))
    except (OSError, ValueError) as exc:
        raise RuntimeError(
            "need %d file descriptors but RLIMIT_NOFILE could not be raised "
            "(soft=%s hard=%s): %s; raise 'ulimit -n' or lower --flows"
            % (needed, soft, hard, exc)
        )
    soft_now, _ = resource.getrlimit(resource.RLIMIT_NOFILE)
    if soft_now != unlimited and soft_now < needed:
        raise RuntimeError(
            "need %d file descriptors but only %s are allowed after raising "
            "RLIMIT_NOFILE; raise 'ulimit -n' or lower --flows" % (needed, soft_now)
        )


def _pick_unused_port(low, high, used, rng):
    for _ in range(256):
        port = rng.randint(low, high)
        if port not in used:
            return port
    for port in range(low, high + 1):
        if port not in used:
            return port
    raise RuntimeError("no unused UDP source port left in %d-%d" % (low, high))


def _close_sockets(prepared):
    for _flow, sock in prepared:
        try:
            sock.close()
        except OSError:
            pass


def prepare_sockets(flows, bind_ip, port_low, port_high, rng):
    _ensure_nofile(len(flows) + 128)
    prepared = []
    used_ports = set()
    for flow in flows:
        port = flow.src_port
        last_error = None
        sock = None
        for _attempt in range(MAX_BIND_ATTEMPTS):
            if port in used_ports:
                port = _pick_unused_port(port_low, port_high, used_ports, rng)
                continue
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            except OSError as exc:
                _close_sockets(prepared)
                raise RuntimeError("cannot create a UDP socket: %s" % exc)
            try:
                sock.bind((bind_ip, port))
                sock.setblocking(False)
            except OSError as exc:
                sock.close()
                last_error = exc
                if exc.errno == errno.EADDRNOTAVAIL:
                    _close_sockets(prepared)
                    raise RuntimeError(
                        "cannot bind source address %s: %s; use an address of this "
                        "host or leave --src-ip unset" % (bind_ip, exc)
                    )
                port = _pick_unused_port(port_low, port_high, used_ports, rng)
                continue
            used_ports.add(port)
            prepared.append((flow._replace(src_port=port), sock))
            break
        else:
            _close_sockets(prepared)
            raise RuntimeError(
                "cannot bind a UDP source port in %d-%d: %s"
                % (port_low, port_high, last_error)
            )
    return prepared


def _send_loop(prepared, rate, duration):
    total = int(rate * duration)
    interval = 1.0 / rate
    start = time.monotonic()
    stop = start + duration
    deadline = start
    sent = errors = 0
    first_error = None
    interrupted = False
    index = 0
    num_flows = len(prepared)
    try:
        while sent + errors < total:
            now = time.monotonic()
            if now >= stop:
                break
            wait = deadline - now
            if wait > 0.002:
                time.sleep(wait - 0.001)
                if time.monotonic() >= stop:
                    break
            flow, sock = prepared[index]
            index += 1
            if index >= num_flows:
                index = 0
            try:
                sock.sendto(PAYLOAD, (flow.dst_ip, flow.dst_port))
                sent += 1
            except BlockingIOError:
                errors += 1
            except OSError as exc:
                errors += 1
                if first_error is None:
                    first_error = "%s: %s" % (type(exc).__name__, exc)
            deadline += interval
    except KeyboardInterrupt:
        interrupted = True
    return SendResult(sent, errors, first_error, time.monotonic() - start, interrupted)


def run_send(flows, cfg):
    bind_ip = cfg.src_ip if cfg.src_ip is not None else "0.0.0.0"
    print("traffic source, not a measurement conclusion")
    print(
        "sending flows=%d src-ip=%s dst-prefix=%s src-port-cycle=%d-%d dst-port=%d "
        "rate=%gpps duration=%gs"
        % (
            len(flows),
            bind_ip,
            cfg.dst_prefix,
            cfg.src_ports[0],
            cfg.src_ports[1],
            cfg.dst_port,
            cfg.rate,
            cfg.duration,
        )
    )
    rng = random.Random(cfg.seed ^ 0x9E3779B9)
    try:
        prepared = prepare_sockets(
            flows, bind_ip, cfg.src_ports[0], cfg.src_ports[1], rng
        )
    except RuntimeError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("INTERRUPTED while preparing sockets", file=sys.stderr)
        return 130
    try:
        result = _send_loop(prepared, cfg.rate, cfg.duration)
    finally:
        _close_sockets(prepared)

    pps = result.sent / result.elapsed if result.elapsed > 0 else 0.0
    print(
        "PREPARED flows=%d distinct_dst=%d distinct_sport=%d pps=%.1f"
        % (
            len(prepared),
            len({flow.dst_ip for flow, _sock in prepared}),
            len({flow.src_port for flow, _sock in prepared}),
            pps,
        )
    )
    print(
        "SENT packets=%d errors=%d seconds=%.2f (measured)"
        % (result.sent, result.errors, result.elapsed)
    )
    if result.first_error is not None:
        print("first send error: %s" % result.first_error, file=sys.stderr)
    if result.interrupted:
        print(
            "INTERRUPTED: partial run, the PREPARED values above are measured over "
            "the time before the interrupt",
            file=sys.stderr,
        )
        return 130
    if result.sent == 0 and result.errors > 0:
        print(
            "ERROR: no packet was accepted; check routing to --dst-prefix and the "
            "--src-ip choice",
            file=sys.stderr,
        )
        return 1
    return 0


def _default_config():
    return Config(
        flows=DEFAULT_FLOWS,
        dst_prefix=ipaddress.ip_network(DEFAULT_DST_PREFIX),
        src_ip=None,
        src_ports=DEFAULT_SRC_PORTS,
        dst_port=DEFAULT_DST_PORT,
        rate=None,
        duration=None,
        seed=DEFAULT_SEED,
    )


def self_test():
    checks = 0

    def check(description, condition):
        nonlocal checks
        assert condition, description
        print("selftest ok: %s" % description)
        checks += 1

    parser = build_parser()
    cfg = _default_config()
    flows = build_flows(cfg)

    check("flow count matches --flows", len(flows) == cfg.flows)
    check(
        "every 5-tuple is unique",
        len({(flow.src_ip, flow.src_port, flow.dst_ip, flow.dst_port, "udp") for flow in flows})
        == len(flows),
    )
    check("distinct destination addresses >= 10000", len({flow.dst_ip for flow in flows}) >= 10000)
    check("source ports are distinct", len({flow.src_port for flow in flows}) == len(flows))
    check(
        "all destinations are inside --dst-prefix",
        all(ipaddress.IPv4Address(flow.dst_ip) in cfg.dst_prefix for flow in flows),
    )
    check("flow build is deterministic", build_flows(cfg) == flows)

    hashes = [_flow_hash(flow) for flow in flows]
    check(
        "32768-entry fold is hash & (n - 1)",
        all(ppe_fold_hash(hash_value, 32768) == (hash_value & 32767) for hash_value in hashes),
    )
    check(
        "24576-entry fold matches hash % 24576",
        all(ppe_fold_hash(hash_value, 24576) == (hash_value % 24576) for hash_value in hashes),
    )
    check(
        "16384-entry fold is hash & (n - 1)",
        all(ppe_fold_hash(hash_value, 16384) == (hash_value & 16383) for hash_value in hashes),
    )
    check(
        "unknown geometry falls back to hash % n",
        all(
            ppe_fold_hash(hash_value, 20000) == (hash_value % 20000)
            for hash_value in (0, 8191, 8192, 16384, 24576, 32767, 65535, 0xFFFFFFFF)
        ),
    )
    check(
        "32768-entry fold reaches every slot",
        len({ppe_fold_hash(hash_value, 32768) for hash_value in range(32768)}) == 32768,
    )
    check(
        "24576-entry fold reaches every slot",
        len({ppe_fold_hash(hash_value, 24576) for hash_value in range(32768)}) == 24576,
    )
    check(
        "16384-entry fold reaches every slot",
        len({ppe_fold_hash(hash_value, 16384) for hash_value in range(32768)}) == 16384,
    )
    check(
        "24576-entry fold reaches the slots a mask would lose",
        any(8192 <= ppe_fold_hash(hash_value, 24576) <= 16383 for hash_value in hashes),
    )
    check(
        "the pre-fold hash uses all four 8192-slot windows",
        all(count > 0 for count in _slice_counts([hash_value & 32767 for hash_value in hashes])),
    )

    try:
        build_flows(cfg._replace(dst_prefix=ipaddress.ip_network("10.0.0.0/24"), flows=1000))
    except ValueError as exc:
        check("a too-small --dst-prefix is rejected", "usable IPv4 addresses" in str(exc))
    else:
        check("a too-small --dst-prefix is rejected", False)
    try:
        build_flows(cfg._replace(src_ports=(1024, 1100), flows=1000))
    except ValueError as exc:
        check("a too-small --src-port-cycle is rejected", "usable source ports" in str(exc))
    else:
        check("a too-small --src-port-cycle is rejected", False)

    for argv in ([], ["--rate", "1000"], ["--duration", "1"]):
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                _config_from_args(parser, parser.parse_args(argv))
        except SystemExit:
            check("missing send parameters are rejected (%s)" % (" ".join(argv) or "both"), True)
        else:
            check("missing send parameters are rejected (%s)" % (" ".join(argv) or "both"), False)

    real_socket = socket.socket

    def _no_socket(*_args, **_kwargs):
        raise AssertionError("a socket was created in an offline mode")

    socket.socket = _no_socket
    try:
        offline_output = io.StringIO()
        with contextlib.redirect_stdout(offline_output):
            print_plan(flows, cfg)
            print_dry_run(flows, cfg)
    finally:
        socket.socket = real_socket
    offline_text = offline_output.getvalue()
    check("--plan and --dry-run create no sockets", True)
    check(
        "--plan reports distinct_dst=16384",
        "distinct_dst=%d" % len({flow.dst_ip for flow in flows}) in offline_text,
    )
    for low, high in SLICES:
        label = "[%d..%d]" % (low, high)
        check("%s is printed" % label, label in offline_text)
    check(
        "--dry-run declares that no packets are sent",
        "no sockets created, no packets sent" in offline_text,
    )

    class _CountingSocket:
        def __init__(self):
            self.packets = 0

        def sendto(self, _data, _addr):
            self.packets += 1

    fake = [(flows[index], _CountingSocket()) for index in range(4)]
    result = _send_loop(fake, rate=500.0, duration=0.04)
    check(
        "send loop counts and measures packets",
        result.sent > 0 and result.errors == 0 and result.elapsed > 0,
    )

    print("selftest ok: %d checks passed" % checks)
    return 0


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    cfg = _config_from_args(parser, args)
    try:
        flows = build_flows(cfg)
    except ValueError as exc:
        parser.error(str(exc))
    if args.plan:
        return print_plan(flows, cfg)
    if args.dry_run:
        return print_dry_run(flows, cfg)
    return run_send(flows, cfg)


if __name__ == "__main__":
    sys.exit(main())
