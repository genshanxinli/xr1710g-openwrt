#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Offline PPE slot/hash verifier.

Reads a saved /sys/kernel/debug/ppe/entries dump and compares, for every
IPv4/IPv6 five-tuple entry, the slot in the dump's first column with the
slot recomputed by the driver's airoha_ppe_foe_get_entry_hash() and
airoha_ppe_fold_hash().  It never reads a device and never writes anything.

The dump format is the one in airoha_ppe_debugfs.c:

  005e0 UNB IPv4 5T orig=1.2.3.4:1234->5.6.7.8:80 new=... eth=...
        etype=... data=... vlan=... ib1=0800017a ib2=...
        packets=... bytes=...

Only five-tuple entries (IB1.BIND_PACKET_TYPE 0 and 5) carry all the
fields the driver hashes.  Other types are counted as skipped and named on
stderr; they are still included in the dumped-slot occupancy, because the
slot column belongs to the table, not to a particular entry type.

The recomputation is:

  * airoha_ppe_foe_get_entry_hash() from the tuple, using the ORIGINAL
    (pre-NAT) tuple, exactly as the driver does;
  * airoha_ppe_fold_hash() as introduced by
    target/linux/airoha/patches-7.3/212-net-airoha-address-PPE-entries-from-their-own-table.patch:
    a power-of-two table masks with & (entries - 1), 24576 == 3 * 8192
    uses the (%3, low 13 bits) split, and anything else falls back to %.

The output starts with one self-describing line for a claim ledger:

  image=<label> geometry=<n> dumped_slots=<rows> compared=<rows> skipped=<n>
  ge0x2000=<n> ge0x4000=<n> match_rate=<hits>/<compared>
  status=<OK|INCONSISTENT|NO_DATA> max_slot=<0x...|none>

then the CSV header and one CSV row.  In the CSV, ge0x2000 and ge0x4000
count the RECOMPUTED (folded) hashes at or above those boundaries, while
the four [0..8191] ... [24576..32767] columns count the DUMPED slots in
each interval.  match_rate is "dump slot == folded hash" over the compared
rows.  Keeping the two distributions separate is what makes one line say
both "the dump sits low" and "this geometry would put N of them high".

status is INCONSISTENT when the dump contradicts the declared geometry:
a dumped slot outside the table, or a 32768-entry declaration whose slots
are all below 0x2000 (the b19-image pattern; see
issue #31 comment A6).  That case exits 1.  A clean
run exits 0.

This is an offline, standard-library-only tool.  It opens a dump for
reading (a path or - for stdin), or uses a built-in sample, or runs
--self-test.  It creates no files, opens no sockets and touches no device.
"""

import argparse
import ipaddress
import re
import sys

PROG = "ppe-slot-verify.py"

MASK32 = 0xFFFFFFFF
PPE_SRAM_NUM_ENTRIES = 8192
GEOMETRIES = (32768, 24576, 16384)
INTERVALS = ((0, 8191), (8192, 16383), (16384, 24575), (24576, 32767))
CSV_COLUMNS = (
    "image",
    "geometry",
    "dumped_slots",
    "ge0x2000",
    "ge0x4000",
    "match_rate",
    "[0..8191]",
    "[8192..16383]",
    "[16384..24575]",
    "[24576..32767]",
)

# IB1 fields: state is GENMASK(29, 28), packet type is GENMASK(27, 25).
IB1_TYPE_SHIFT = 25
IB1_TYPE_MASK = 0x7
IB1_STATE_SHIFT = 28
IB1_STATE_MASK = 0x3

PKT_IPV4_HNAPT = 0
PKT_IPV4_ROUTE = 1
PKT_BRIDGE = 2
PKT_IPV4_DSLITE = 3
PKT_IPV6_ROUTE_3T = 4
PKT_IPV6_ROUTE_5T = 5
PKT_IPV6_6RD = 6

PKT_NAMES = {
    PKT_IPV4_HNAPT: "IPv4 5T",
    PKT_IPV4_ROUTE: "IPv4 3T",
    PKT_BRIDGE: "L2B",
    PKT_IPV4_DSLITE: "IPv4 DS-LITE",
    PKT_IPV6_ROUTE_3T: "IPv6 3T",
    PKT_IPV6_ROUTE_5T: "IPv6 5T",
    PKT_IPV6_6RD: "IPv6 6RD",
}

# A slot below this is below the PPE2/PPE3 boundary of a 32768-entry table.
PPE2_START = 0x2000

EXIT_OK = 0
EXIT_VERDICT = 1

LINE_RE = re.compile(
    r"^((?:0[xX])?[0-9a-fA-F]+)\s+([A-Za-z][A-Za-z0-9_.-]*)\s+(.*)$"
)
IB1_RE = re.compile(r"\b(?:ib1)=(?:0[xX])?([0-9a-fA-F]+)\b")
FIELD_RE = re.compile(r"\b(orig|new)=([^\s]+)")
IMAGE_RE = re.compile(r"^[A-Za-z0-9._:@/+-]+$")


class FiveTuple:
    """Parsed orig/new tuple: address words, ports and address family."""

    __slots__ = ("family", "src_words", "dst_words", "src_port", "dst_port")

    def __init__(self, family, src_words, dst_words, src_port, dst_port):
        self.family = family
        self.src_words = src_words
        self.dst_words = dst_words
        self.src_port = src_port
        self.dst_port = dst_port


class Entry:
    """One line of the dump, before tuple decoding."""

    __slots__ = ("lineno", "slot", "ib1", "type", "state", "orig", "new")

    def __init__(self, lineno, slot, ib1, pkt_type, state, orig, new):
        self.lineno = lineno
        self.slot = slot
        self.ib1 = ib1
        self.type = pkt_type
        self.state = state
        self.orig = orig
        self.new = new


class Result:
    """Aggregate of one dump versus one declared geometry."""

    __slots__ = (
        "image",
        "geometry",
        "dumped_slots",
        "compared",
        "skipped",
        "bins",
        "out_of_range",
        "hash_ge_0x2000",
        "hash_ge_0x4000",
        "exact",
        "max_slot",
        "status",
        "reasons",
    )

    def __init__(self):
        self.image = ""
        self.geometry = 0
        self.dumped_slots = 0
        self.compared = 0
        self.skipped = {}
        self.bins = [0, 0, 0, 0]
        self.out_of_range = 0
        self.hash_ge_0x2000 = 0
        self.hash_ge_0x4000 = 0
        self.exact = 0
        self.max_slot = None
        self.status = "NO_DATA"
        self.reasons = []


def fold_hash(hash_value, num_entries):
    """airoha_ppe_fold_hash() from patches-7.3/212, branch for branch."""
    if not (num_entries & (num_entries - 1)):
        return hash_value & (num_entries - 1)
    if num_entries == 3 * PPE_SRAM_NUM_ENTRIES:
        return ((hash_value >> 13) % 3) * PPE_SRAM_NUM_ENTRIES + (
            hash_value & (PPE_SRAM_NUM_ENTRIES - 1)
        )
    return hash_value % num_entries


def entry_bin(slot):
    """Index of the 8192-wide occupancy interval holding slot, or None."""
    for index, (low, high) in enumerate(INTERVALS):
        if low <= slot <= high:
            return index
    return None


def _parse_ipv4(text):
    parts = text.split(".")
    if len(parts) != 4:
        raise ValueError("not a dotted-quad IPv4 address")
    value = 0
    for part in parts:
        if not part or not part.isdigit():
            raise ValueError("not a dotted-quad IPv4 address")
        octet = int(part)
        if octet > 255:
            raise ValueError("IPv4 octet out of range")
        if len(part) > 1 and part[0] == "0":
            raise ValueError("IPv4 octet has a leading zero")
        value = (value << 8) | octet
    return value


def _parse_ipv4_endpoint(text):
    if text.count(":") > 1:
        raise ValueError("not an IPv4 endpoint")
    if ":" in text:
        address, port = text.split(":")
        if not port.isdigit():
            raise ValueError("port is not decimal")
    else:
        address, port = text, None
    words = [_parse_ipv4(address)]
    port = None if port is None else int(port)
    if port is not None and port > 65535:
        raise ValueError("port out of range")
    return words, port


def _parse_ipv6_endpoint(text):
    try:
        address = ipaddress.IPv6Address(text)
        port = None
    except ValueError:
        # The debugfs prints an uncompressed address followed by ":port"
        # for a five-tuple.  ipaddress rejects that whole string, so split
        # the port off and require the prefix to be an address.
        if ":" not in text:
            raise ValueError("not an IPv6 endpoint")
        address_text, port_text = text.rsplit(":", 1)
        if not port_text.isdigit():
            raise ValueError("port is not decimal")
        address = ipaddress.IPv6Address(address_text)
        port = int(port_text)
        if port > 65535:
            raise ValueError("port out of range")

    value = int(address)
    words = [(value >> shift) & MASK32 for shift in (96, 64, 32, 0)]
    return words, port


def parse_five_tuple(text, family):
    """Parse 'src->dst' with both ports present; raise ValueError otherwise."""
    if text is None:
        raise ValueError("missing tuple")
    if text.count("->") != 1:
        raise ValueError("not a src->dst tuple")
    src_text, dst_text = text.split("->")
    parse_endpoint = _parse_ipv4_endpoint if family == "ipv4" else _parse_ipv6_endpoint
    src_words, src_port = parse_endpoint(src_text)
    dst_words, dst_port = parse_endpoint(dst_text)
    if src_port is None or dst_port is None:
        raise ValueError("not a five-tuple (missing port)")
    return FiveTuple(family, src_words, dst_words, src_port, dst_port)


def tuple_hash(tuple_value):
    """Raw airoha_ppe_foe_get_entry_hash() before folding."""
    ports = (tuple_value.src_port << 16) | tuple_value.dst_port
    if tuple_value.family == "ipv4":
        hv1 = ports
        hv2 = tuple_value.dst_words[0]
        hv3 = tuple_value.src_words[0]
    else:
        src = tuple_value.src_words
        dst = tuple_value.dst_words
        hv1 = src[3] ^ dst[3] ^ ports
        hv2 = src[2] ^ dst[2] ^ dst[0]
        hv3 = src[1] ^ dst[1] ^ src[0]

    hash_value = (hv1 & hv2) | ((~hv1 & MASK32) & hv3)
    hash_value = ((hash_value >> 24) | ((hash_value & 0x00FFFFFF) << 8)) & MASK32
    hash_value ^= hv1 ^ hv2 ^ hv3
    hash_value ^= hash_value >> 16
    return hash_value & MASK32


def iter_entries(text):
    """Yield Entry objects; silently ignore non-entry text."""
    for lineno, raw_line in enumerate(text.splitlines(), 1):
        line = raw_line.strip()
        if not line:
            continue
        match = LINE_RE.match(line)
        if not match:
            continue
        ib1_match = IB1_RE.search(line)
        if not ib1_match:
            continue
        slot = int(match.group(1), 16)
        ib1 = int(ib1_match.group(1), 16)
        pkt_type = (ib1 >> IB1_TYPE_SHIFT) & IB1_TYPE_MASK
        state = (ib1 >> IB1_STATE_SHIFT) & IB1_STATE_MASK
        fields = dict(FIELD_RE.findall(line))
        yield Entry(
            lineno,
            slot,
            ib1,
            pkt_type,
            state,
            fields.get("orig"),
            fields.get("new"),
        )


def _skip_reason(pkt_type):
    name = PKT_NAMES.get(pkt_type, "unknown type %d" % pkt_type)
    if pkt_type in (PKT_IPV4_DSLITE, PKT_IPV6_6RD):
        return "%s (driver does not hash this type)" % name
    return "%s (not a five-tuple)" % name


def analyze(text, image, geometry):
    """Compare one dump against one declared geometry."""
    result = Result()
    result.image = image
    result.geometry = geometry

    for entry in iter_entries(text):
        result.dumped_slots += 1
        if result.max_slot is None or entry.slot > result.max_slot:
            result.max_slot = entry.slot
        bin_index = entry_bin(entry.slot)
        if bin_index is None:
            result.out_of_range += 1
        else:
            result.bins[bin_index] += 1

        if entry.type not in (PKT_IPV4_HNAPT, PKT_IPV6_ROUTE_5T):
            reason = _skip_reason(entry.type)
            result.skipped[reason] = result.skipped.get(reason, 0) + 1
            continue

        family = "ipv4" if entry.type == PKT_IPV4_HNAPT else "ipv6"
        try:
            original = parse_five_tuple(entry.orig, family)
            # The translated half is parsed when the dump carries it, but
            # the driver hashes only the original tuple, so its absence
            # does not make the slot unverifiable.
            if entry.type == PKT_IPV4_HNAPT and entry.new is not None:
                parse_five_tuple(entry.new, family)
        except ValueError:
            reason = "%s (malformed five-tuple)" % PKT_NAMES.get(
                entry.type, "type %d" % entry.type
            )
            result.skipped[reason] = result.skipped.get(reason, 0) + 1
            continue

        folded = fold_hash(tuple_hash(original), geometry)
        result.compared += 1
        if folded >= PPE2_START:
            result.hash_ge_0x2000 += 1
        if folded >= 2 * PPE2_START:
            result.hash_ge_0x4000 += 1
        if folded == entry.slot:
            result.exact += 1

    if result.dumped_slots == 0:
        result.status = "NO_DATA"
        result.reasons.append("no PPE entry rows found in the dump")
    elif result.compared == 0:
        result.status = "NO_DATA"
        result.reasons.append("no comparable five-tuple entries found in the dump")
    elif result.max_slot >= geometry:
        result.status = "INCONSISTENT"
        result.reasons.append(
            "dumped slot 0x%x is outside the declared %d-entry table"
            % (result.max_slot, geometry)
        )
    elif geometry == 32768 and result.max_slot < PPE2_START:
        result.status = "INCONSISTENT"
        result.reasons.append(
            "all dumped slots are below 0x%x, so the dump's index space is "
            "at most %d, not the declared %d entries"
            % (PPE2_START, PPE2_START, geometry)
        )
    else:
        result.status = "OK"

    return result


def _skipped_text(result):
    return ", ".join(
        "%d x %s" % (count, reason)
        for reason, count in sorted(result.skipped.items())
    )


def match_rate_text(result):
    return "%d/%d" % (result.exact, result.compared)


def render(result):
    """Return the metadata line, the CSV header and the CSV row."""
    dumped = result.dumped_slots
    compared = result.compared
    max_slot = "none" if result.max_slot is None else "0x%05x" % result.max_slot
    skipped = dumped - compared

    meta = (
        "image=%s geometry=%d dumped_slots=%d compared=%d skipped=%d "
        "ge0x2000=%d ge0x4000=%d match_rate=%s status=%s max_slot=%s"
        % (
            result.image,
            result.geometry,
            dumped,
            compared,
            skipped,
            result.hash_ge_0x2000,
            result.hash_ge_0x4000,
            match_rate_text(result),
            result.status,
            max_slot,
        )
    )
    if result.out_of_range:
        meta += " out_of_range=%d" % result.out_of_range

    header = ",".join(CSV_COLUMNS)
    row = ",".join(
        (
            result.image,
            str(result.geometry),
            str(dumped),
            str(result.hash_ge_0x2000),
            str(result.hash_ge_0x4000),
            match_rate_text(result),
            str(result.bins[0]),
            str(result.bins[1]),
            str(result.bins[2]),
            str(result.bins[3]),
        )
    )
    return meta, header, row


def _exit_code(result):
    if result.status == "OK":
        return EXIT_OK
    return EXIT_VERDICT


def _make_sample(geometry):
    """Build a small consistent dump with entries in every reachable interval.

    The slots are the hashes the verifier recomputes, so a correct run
    reports 100% and populates every interval the geometry can reach.  This
    is a positive control for parsing, hashing and the interval table, not
    a capture from any device.
    """
    reachable = [index for index, (low, _) in enumerate(INTERVALS) if low < geometry]
    wanted = {index: 4 for index in reachable}
    chosen = []
    index = 0
    while any(count for count in wanted.values()):
        if index > 200000:
            raise RuntimeError("could not build the sample dump")
        # Vary the destination address and the source port; the driver's
        # hash then reaches every interval of a 32768-entry table quickly.
        dst = 0xCB007101 + (index % 250)
        src = 0xC0000201
        src_port = 32768 + (index % 32767)
        dst_port = 1 + (index % 65534)
        original = FiveTuple("ipv4", [src], [dst], src_port, dst_port)
        slot = fold_hash(tuple_hash(original), geometry)
        bin_index = entry_bin(slot)
        if bin_index in wanted and wanted[bin_index] > 0:
            chosen.append((slot, original))
            wanted[bin_index] -= 1
        index += 1

    chosen.sort(key=lambda item: item[0])
    lines = []
    for slot, original in chosen:
        new_src = original.dst_words[0]
        new_port = original.dst_port
        lines.append(
            "%05x UNB IPv4 5T "
            "orig=%d.%d.%d.%d:%d->%d.%d.%d.%d:%d "
            "new=%d.%d.%d.%d:%d->%d.%d.%d.%d:%d "
            "eth=02:00:00:00:00:01->02:00:00:00:00:02 "
            "etype=0800 data=00000000 vlan=0,0 ib1=%08x ib2=00000000 "
            "packets=n/a bytes=n/a"
            % (
                slot,
                original.src_words[0] >> 24,
                (original.src_words[0] >> 16) & 0xFF,
                (original.src_words[0] >> 8) & 0xFF,
                original.src_words[0] & 0xFF,
                original.src_port,
                original.dst_words[0] >> 24,
                (original.dst_words[0] >> 16) & 0xFF,
                (original.dst_words[0] >> 8) & 0xFF,
                original.dst_words[0] & 0xFF,
                original.dst_port,
                new_src >> 24,
                (new_src >> 16) & 0xFF,
                (new_src >> 8) & 0xFF,
                new_src & 0xFF,
                new_port,
                original.dst_words[0] >> 24,
                (original.dst_words[0] >> 16) & 0xFF,
                (original.dst_words[0] >> 8) & 0xFF,
                original.dst_words[0] & 0xFF,
                original.dst_port,
                # State UNB (1<<28), packet type IPv4 5T (0).
                (1 << IB1_STATE_SHIFT) | 0x17A,
            )
        )
    return "\n".join(lines) + "\n"


def _read_dump(path):
    if path == "-":
        return sys.stdin.read()
    with open(path, "r", encoding="utf-8", errors="replace") as dump_file:
        return dump_file.read()


def _validate_image(parser, image):
    if image is None:
        return None
    if not IMAGE_RE.match(image):
        parser.error(
            "--image must be a short label without spaces, commas or '=' "
            "(letters, digits and ._:@/+- only)"
        )
    return image


def build_parser():
    parser = argparse.ArgumentParser(
        prog=PROG,
        description=(
            "Offline verifier for a ppe/entries dump: compare the dumped "
            "slot with the driver's five-tuple fold_hash recomputation."
        ),
        epilog=(
            "exit status: 0 when the declared geometry and the dump agree, "
            "1 when the dump contradicts the geometry or has no comparable "
            "entries, 2 on a usage error.  The tool never writes files, "
            "opens sockets or touches a device."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "dump",
        nargs="?",
        metavar="DUMP",
        help="saved ppe/entries dump to read; '-' or no argument reads stdin",
    )
    parser.add_argument(
        "--image",
        metavar="LABEL",
        help=(
            "image the dump came from (required with a dump); every result "
            "row carries this label so geometries are never mixed silently"
        ),
    )
    parser.add_argument(
        "--geometry",
        type=int,
        choices=GEOMETRIES,
        help=(
            "declared table size: 32768 and 16384 fold with '& (n-1)', "
            "24576 with the modulo-3 and low-13-bits split"
        ),
    )
    parser.add_argument(
        "--sample",
        action="store_true",
        help="use the built-in synthetic dump instead of a file (image=sample)",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run the offline self-test and exit (no dump is read)",
    )
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.self_test:
        if args.sample or args.image is not None or args.geometry is not None or args.dump:
            parser.error("--self-test does not take a dump, --sample, --image or --geometry")
        return _self_test()

    image = _validate_image(parser, args.image)

    if args.sample:
        if args.dump is not None:
            parser.error("--sample does not take a dump file")
        if image is None:
            image = "sample"
        geometry = args.geometry if args.geometry is not None else 32768
        text = _make_sample(geometry)
    else:
        if image is None:
            parser.error("--image LABEL is required with a dump; every result must name its image")
        if args.geometry is None:
            parser.error("--geometry is required with a dump (32768, 24576 or 16384)")
        geometry = args.geometry
        try:
            text = _read_dump(args.dump if args.dump is not None else "-")
        except OSError as error:
            print("%s: cannot read dump: %s" % (PROG, error), file=sys.stderr)
            return EXIT_VERDICT

    result = analyze(text, image, geometry)
    meta, header, row = render(result)
    print(meta)
    print(header)
    print(row)

    skipped = result.dumped_slots - result.compared
    if skipped:
        print(
            "%s: skipped %d row(s): %s"
            % (PROG, skipped, _skipped_text(result)),
            file=sys.stderr,
        )
    for reason in result.reasons:
        print("%s: %s: %s" % (PROG, result.status, reason), file=sys.stderr)

    return _exit_code(result)


def _self_test():
    """Small deterministic checks for the parts that are easy to get wrong."""
    failures = []
    checks = 0

    def check(condition, message):
        nonlocal checks
        checks += 1
        if not condition:
            failures.append(message)

    # fold_hash: both branches, boundary values and the 24576 equivalence.
    fold_cases = (
        (0x00000000, 32768, 0x0000),
        (0x00007FFF, 32768, 0x7FFF),
        (0x00008000, 32768, 0x0000),
        (0xFFFFFFFF, 32768, 0x7FFF),
        (0x00008000, 24576, 0x2000),
        (0x0000FFFF, 24576, 0x3FFF),
        (0xFFFFFFFF, 24576, 0x3FFF),
        (0x00008000, 16384, 0x0000),
        (0x0001FFFF, 16384, 0x3FFF),
    )
    for hash_value, geometry, expected in fold_cases:
        check(
            fold_hash(hash_value, geometry) == expected,
            "fold_hash(0x%x, %d) != 0x%x" % (hash_value, geometry, expected),
        )
    for hash_value in (0, 1, 0x12345678, 0xFFFFFFFF):
        check(
            fold_hash(hash_value, 24576) == hash_value % 24576,
            "24576 branch disagrees with %% for 0x%x" % hash_value,
        )
        check(
            fold_hash(hash_value, 32768) == (hash_value & 32767),
            "32768 branch is not a mask for 0x%x" % hash_value,
        )

    # Every slot of each supported geometry is reachable.
    for geometry in GEOMETRIES:
        reached = {fold_hash(value, geometry) for value in range(2 * geometry)}
        check(
            reached == set(range(geometry)),
            "geometry %d does not reach every slot (got %d)" % (geometry, len(reached)),
        )

    # Interval boundaries and out-of-range slots.
    bins = (0, 8191, 8192, 16383, 16384, 24575, 24576, 32767)
    expected_bins = (0, 0, 1, 1, 2, 2, 3, 3)
    for slot, expected in zip(bins, expected_bins):
        check(entry_bin(slot) == expected, "entry_bin(0x%x) != %d" % (slot, expected))
    check(entry_bin(32768) is None, "entry_bin(32768) should be out of range")

    # A synthetic dump line with the expected hashes computed by hand from
    # the driver formula: 192.0.2.1:33004 -> 198.51.100.1:9999 hashes to
    # 0xa6fbe634 and folds to slot 0x06634 with the 32768-entry table.
    reference_line = (
        "06634 UNB IPv4 5T orig=192.0.2.1:33004->198.51.100.1:9999 "
        "new=203.0.113.5:33004->198.51.100.1:9999 "
        "eth=02:00:00:00:00:01->02:00:00:00:00:02 etype=0800 data=00000000 "
        "vlan=0,0 ib1=5000017a ib2=00000000 packets=n/a bytes=n/a"
    )
    entries = list(iter_entries(reference_line))
    check(len(entries) == 1, "reference dump line did not parse as one entry")
    if entries:
        entry = entries[0]
        check(entry.slot == 0x6634, "reference line slot parsed wrong")
        check(entry.type == PKT_IPV4_HNAPT, "reference line packet type parsed wrong")
        check(entry.state == 1, "reference line state parsed wrong")
        original = parse_five_tuple(entry.orig, "ipv4")
        check(
            original.src_port == 33004 and original.dst_port == 9999,
            "reference line ports parsed wrong",
        )
        check(
            tuple_hash(original) == 0xA6FBE634,
            "reference tuple raw hash is wrong",
        )
        check(
            fold_hash(tuple_hash(original), 32768) == 0x6634,
            "reference tuple folded hash is wrong",
        )

    # IPv6 five-tuples use the driver's word XORs; the expected raw hash
    # below was computed by hand from that formula, not from this file.
    ipv6_line = (
        "01fc4 UNB IPv6 5T "
        "orig=fe80:0000:0000:0000:02e0:4cff:fee2:012b:42401"
        "->ff02:0000:0000:0000:0000:0000:0000:00fb:100 "
        "eth=00:00:00:00:00:00->00:00:00:00:00:00 etype=0000 "
        "data=00000000 vlan=0,0 ib1=5a000143 ib2=02e04cff "
        "packets=n/a bytes=n/a"
    )
    entries = list(iter_entries(ipv6_line))
    check(len(entries) == 1, "IPv6 dump line did not parse as one entry")
    if entries:
        entry = entries[0]
        check(entry.type == PKT_IPV6_ROUTE_5T, "IPv6 line packet type parsed wrong")
        ipv6_tuple = parse_five_tuple(entry.orig, "ipv6")
        check(
            ipv6_tuple.src_words
            == [0xFE800000, 0x00000000, 0x02E04CFF, 0xFEE2012B],
            "IPv6 source words parsed wrong",
        )
        check(
            ipv6_tuple.dst_words
            == [0xFF020000, 0x00000000, 0x00000000, 0x000000FB],
            "IPv6 destination words parsed wrong",
        )
        check(
            ipv6_tuple.src_port == 42401 and ipv6_tuple.dst_port == 100,
            "IPv6 ports parsed wrong",
        )
        check(
            tuple_hash(ipv6_tuple) == 0x9A216397,
            "IPv6 raw hash is wrong",
        )

    # Parsing must reject a truncated tuple and not count header text.
    check(
        list(iter_entries("entries 32768 (sram 16384, dram 16384)\n")) == [],
        "header line parsed as a PPE entry",
    )
    checks += 1
    try:
        parse_five_tuple("192.0.2.1->198.51.100.2:80", "ipv4")
    except ValueError:
        pass
    else:
        failures.append("a tuple with a missing port was accepted")

    # A dump in the b19-image shape: all slots low, declared 32768.
    sample_text = _make_sample(32768)
    sample_lines = sample_text.splitlines()
    low_text = "\n".join(
        "%05x %s" % (index, line.split(" ", 1)[1])
        for index, line in enumerate(sample_lines)
    ) + "\n"
    low_result = analyze(low_text, "selftest-low", 32768)
    check(low_result.status == "INCONSISTENT", "all-low dump + 32768 was not INCONSISTENT")
    check(_exit_code(low_result) == 1, "INCONSISTENT did not exit 1")
    check(low_result.dumped_slots == len(sample_lines), "all-low dump row count is wrong")
    check(low_result.bins[0] == len(sample_lines), "all-low dump did not stay in interval 0")
    check(
        low_result.max_slot < PPE2_START,
        "all-low fixture unexpectedly reached 0x2000",
    )

    # The same dump under 24576 is not the 32768 contradiction.
    low_result = analyze(low_text, "selftest-low", 24576)
    check(low_result.status == "OK", "all-low dump + 24576 should not be INCONSISTENT")
    check(_exit_code(low_result) == 0, "OK did not exit 0")

    # A slot outside the declared table is always inconsistent.
    out_text = "%05x %s\n" % (32768, sample_lines[0].split(" ", 1)[1])
    out_result = analyze(out_text, "selftest-out", 32768)
    check(out_result.status == "INCONSISTENT", "out-of-range slot was accepted")
    check(_exit_code(out_result) == 1, "out-of-range slot did not exit 1")

    # Four populated intervals and a 100% match from the sample.
    sample_result = analyze(sample_text, "sample", 32768)
    check(sample_result.status == "OK", "sample is not consistent with 32768")
    check(sample_result.compared == 16, "sample compared row count is wrong")
    check(sample_result.exact == sample_result.compared, "sample does not match 100%")
    check(all(count > 0 for count in sample_result.bins), "sample does not fill all four intervals")
    check(_exit_code(sample_result) == 0, "sample did not exit 0")

    # CSV shape and the metadata line the ledger cites.
    meta, header, row = render(sample_result)
    check("image=" in meta and "geometry=" in meta, "metadata line lacks image=/geometry=")
    check("status=OK" in meta, "metadata line lacks status=OK")
    check(header.split(",") == list(CSV_COLUMNS), "CSV header is wrong")
    check(len(row.split(",")) == len(CSV_COLUMNS), "CSV row column count is wrong")
    check(row.split(",")[5] == "16/16", "CSV match_rate is wrong")
    check(row.split(",")[6:] == ["4", "4", "4", "4"], "CSV intervals are wrong")

    # An IPv4 5T line without the translated half is incomplete: the
    # verifier compares the original tuple but still requires the record
    # to parse as a full five-tuple pair.
    missing_new = (
        "00000 UNB IPv4 5T orig=192.0.2.1:1000->198.51.100.2:80 "
        "ib1=5000017a\n"
    )
    missing_new_result = analyze(missing_new, "selftest-new", 32768)
    check(
        missing_new_result.compared == 1,
        "IPv4 5T line without new= was not compared from its original tuple",
    )

    # A malformed five-tuple is skipped, not silently counted as a match.
    bad_text = "00000 UNB IPv4 5T orig=192.0.2.1->198.51.100.2 ib1=5000017a\n"
    bad_result = analyze(bad_text, "selftest-bad", 32768)
    check(bad_result.compared == 0, "malformed five-tuple was compared")
    check(bad_result.status == "NO_DATA", "no comparable rows should be NO_DATA")
    check(_exit_code(bad_result) == 1, "NO_DATA did not exit 1")

    if failures:
        for failure in failures:
            print("%s: self-test FAIL: %s" % (PROG, failure), file=sys.stderr)
        print("%s: self-test FAIL (%d checks)" % (PROG, checks))
        return EXIT_VERDICT

    print("%s: self-test PASS (%d checks)" % (PROG, checks))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
