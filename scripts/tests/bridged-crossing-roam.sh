#!/bin/sh
# bridged-crossing-roam.sh - print the bridge ports the kernel flow-offload
# guard sees, for the two shapes it has to tell apart:
#
#   roam   one connection, one bridge crossing per direction, whose ingress
#          port changes while it runs: a station roaming between two access
#          points of the same bridge. This must not look like a second
#          crossing.
#   double one connection routed by a router behind the bridge: it crosses
#          the bridge twice per direction. This must look like one.
#
# The running kernel need not carry the 675-05/675-06 patches: this script
# only replays the hook inputs. iptables `physdev` reads nf_bridge->physinif
# and nf_bridge->physoutdev, the same two values the patches record, so the
# per-rule counters below are a faithful trace of (ingress, egress) per
# direction.
#
# Output, one line per observed port pair:
#   EVENT <scenario> <dir> <iif>:<oif> <packets>
# dir is "orig" for the direction the flow started in, "rev" for the replies.
#
# Needs root or a user namespace; it re-execs itself under `unshare -Urnm`.
# Nothing outside its own network and mount namespace is touched.
set -u

[ "${BRX_NS:-0}" = 1 ] || { case "$0" in */*) self=$0 ;; *) self=./$0 ;; esac; exec env BRX_NS=1 unshare -Urnm "$self" "$@"; }

mount -t tmpfs none /run || exit 1
mkdir -p /run/netns
NSES="bnet A A2 R B"
cleanup() { for n in $NSES; do ip netns del "$n" 2>/dev/null; done; }
trap cleanup EXIT
cleanup

# RULE order is the counter order: <dir>:<iif>:<oif>
RULES=""

rules() {
	RULES=$*
	for pair in $RULES; do
		rest=${pair#*:}
		ip netns exec bnet iptables-legacy -A FORWARD \
			-m physdev --physdev-in "${rest%:*}" \
			--physdev-out "${rest#*:}" -j ACCEPT
	done
}

zap() { ip netns exec bnet iptables-legacy -Z FORWARD; }

emit() { # emit <scenario>: one EVENT line per rule that saw traffic
	scen=$1
	n=0
	for pair in $RULES; do
		n=$((n + 1))
		pkts=$(ip netns exec bnet iptables-legacy -L FORWARD -v -n -x |
			awk -v want="$n" 'NR > 2 && ++row == want { print $1 }')
		[ "${pkts:-0}" -gt 0 ] 2>/dev/null || continue
		echo "EVENT $scen ${pair%%:*} ${pair#*:} $pkts"
	done
}

echoer() { # echoer <netns> <addr> <port> <count>
	ip netns exec "$1" python3 - "$2" "$3" "$4" <<'PY' &
import socket, sys
addr, port, want = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((addr, port)); s.settimeout(3)
got = 0
try:
	while got < want:
		data, peer = s.recvfrom(64)
		s.sendto(data, peer)
		got += 1
except Exception:
	pass
PY
}

sender() { # sender <netns> <addr> <sport> <dst> <dport> <count>
	ip netns exec "$1" python3 - "$2" "$3" "$4" "$5" "$6" <<'PY'
import socket, sys, time
addr, sport, dst, dport, want = (sys.argv[1], int(sys.argv[2]), sys.argv[3],
				 int(sys.argv[4]), int(sys.argv[5]))
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((addr, sport))
for _ in range(want):
	s.sendto(b"x" * 40, (dst, dport)); time.sleep(0.05)
time.sleep(1)  # stay bound so the echoes land instead of an ICMP error
PY
}

#
# scenario roam: station A and its roaming twin A2 share 10.99.0.2, each
# behind its own bridge port, same 5-tuple before and after the move.
#
ip netns add bnet; ip netns add A; ip netns add A2; ip netns add B
ip -n bnet link add a1 type veth peer name a0
ip -n bnet link add a2 type veth peer name a3
ip -n bnet link add b1 type veth peer name b0
ip -n bnet link set a0 netns A
ip -n bnet link set a3 netns A2
ip -n bnet link set b0 netns B
ip -n bnet link add br0 type bridge
for d in a1 a2 b1; do
	ip -n bnet link set "$d" master br0
	ip -n bnet link set "$d" up
done
ip -n bnet link set br0 up
ip -n A link set a0 up; ip -n A addr add 10.99.0.2/24 dev a0
ip -n A2 link set a3 down; ip -n A2 addr add 10.99.0.2/24 dev a3
ip -n B link set b0 up; ip -n B addr add 10.99.0.3/24 dev b0
ip netns exec bnet sysctl -qw net.bridge.bridge-nf-call-iptables=1
rules orig:a1:b1 rev:b1:a1 orig:a2:b1 rev:b1:a2

echoer B 10.99.0.3 5000 4
sleep 1
zap
sender A 10.99.0.2 41234 10.99.0.3 5000 4
sleep 1
wait
emit roam
# the station moves: same address, new bridge port, same 5-tuple
ip -n A link set a0 down
ip -n A2 link set a3 up
ip -n B neigh flush all
sleep 1
echoer B 10.99.0.3 5000 4
sleep 1
zap
sender A2 10.99.0.2 41234 10.99.0.3 5000 4
sleep 1
wait
emit roam
cleanup

#
# scenario double: a connection routed by R, reached through the bridge. It
# leaves through r1 towards R and comes back in through s1 on its way to B.
#
ip netns add bnet; ip netns add A; ip netns add R; ip netns add B
ip -n bnet link add a1 type veth peer name a0
ip -n bnet link add r1 type veth peer name r0
ip -n bnet link add s1 type veth peer name s0
ip -n bnet link add b1 type veth peer name b0
ip -n bnet link set a0 netns A
ip -n bnet link set r0 netns R; ip -n bnet link set s0 netns R
ip -n bnet link set b0 netns B
ip -n bnet link add br0 type bridge
for d in a1 r1 s1 b1; do
	ip -n bnet link set "$d" master br0
	ip -n bnet link set "$d" up
done
ip -n bnet link set br0 up
ip -n A link set a0 up; ip -n A addr add 10.99.0.2/24 dev a0
ip -n R link set r0 up; ip -n R link set s0 up
ip -n R addr add 10.99.0.3/24 dev r0; ip -n R addr add 10.99.1.9/24 dev s0
ip -n B link set b0 up; ip -n B addr add 10.99.1.5/24 dev b0
ip netns exec R sysctl -qw net.ipv4.ip_forward=1
ip -n A route add 10.99.1.5/32 via 10.99.0.3
ip -n B route add 10.99.0.2/32 via 10.99.1.9
ip netns exec bnet sysctl -qw net.bridge.bridge-nf-call-iptables=1
rules orig:a1:r1 orig:s1:b1 rev:b1:s1 rev:r1:a1

echoer B 10.99.1.5 5000 4
sleep 1
zap
sender A 10.99.0.2 41234 10.99.1.5 5000 4
sleep 1
wait
emit double
