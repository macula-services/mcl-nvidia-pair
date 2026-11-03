#!/bin/sh
# Fails when this public tree tells a reader something about the lab it runs in
# (macula-services/mcl-nvidia-pair#15).
#
#   scripts/public_tree_check.sh          # the tree this script is in
#   scripts/public_tree_check.sh <dir>    # any checkout
#
# A public repository may say what the software does and how to use it. It may not say what our
# machines are called, how the private fleet repository is laid out, whose home directory it sat
# in, or what a node's identity is -- a reader can do nothing with those but point at them.
#
# The four families, one line each:
#   a lab hostname   a name under the lab's own domain suffix -- a machine inside the lab, which
#                    no public name carries
#   a home path      a real person's directory on a real machine
#   a fleet path     a path into the private fleet repository's own tree
#   a bare node id   64 lowercase hex characters, which is a node's id -- unless the token is
#                    written as a checksum or a digest, which is the same shape
#
# The hostname scan ignores case, because a hostname can be written in upper case and shouting it
# must not be a way past it. The other three stay exact: a path is lower case and a node id is
# lower-case hex.
#
# Text files only (`grep -I` skips binaries), .git is never read, and neither is build output.
# Every hit is printed, so a failure names the line to fix rather than only saying the tree is
# dirty.
#
# Tested by scripts/public_tree_check_test.sh, which lint.yml runs beside this one.
set -eu

ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
HITS=$(mktemp)
trap 'rm -f "$HITS"' EXIT
STATUS=0

# scan <label> <grep flags> <pattern>
#
# The flags are per-family on purpose: a hostname is the one thing here that can be written in
# upper case, so it is the one scan that ignores case. A path is lower case, and a node id is
# lower case hex, so those stay exact.
scan() {
    label=$1
    flags=$2
    pattern=$3

    # --exclude as well as --exclude-dir: in a worktree .git is a FILE holding the real
    # repository's path, and --exclude-dir does not touch a file. _build and _checkouts are
    # skipped because what is compiled is not the tree: they are not published, and a local
    # run after a build should give the same answer CI gives.
    grep -rnI $flags --exclude-dir=.git --exclude=.git --exclude-dir=_build \
         --exclude-dir=_checkouts -e "$pattern" "$ROOT" >"$HITS" 2>/dev/null || true

    if [ -s "$HITS" ]; then
        sed "s/^/FAIL $label: /" "$HITS"
        STATUS=1
    else
        echo "ok   no $label"
    fi
}

scan "lab hostname" "-iE" '[A-Za-z0-9_-]+\.lab([^A-Za-z0-9_-]|$)'
scan "home path"    "-E"  '/home/[A-Za-z0-9._-]+'
scan "fleet path"   "-E"  'edge/[A-Za-z0-9._-]+/'

# A node id is 64 lower-case hex characters, and a sha256 checksum or digest is exactly the same
# shape. The exclusion is on the TOKEN, not on the line: `node <id> answered, digest
# sha256:<digest>` is a line with a node id in it, and the word "sha256" appearing beside it must
# not be a way past this. So the checksum tokens are cut out and what is left is read again --
# a line survives only when a node id is still standing in it.
scan_node_id() {
    grep -rnIE --exclude-dir=.git --exclude=.git --exclude-dir=_build \
         --exclude-dir=_checkouts -e '[0-9a-f]{64}' "$ROOT" 2>/dev/null >"$HITS" || true

    awk '
        match($0, /^[^:]*:[0-9]+:/) {
            head = substr($0, 1, RLENGTH)
            rest = substr($0, RLENGTH + 1)
            # How a checksum is written: sha256:<hex>, SHA256=<hex>, sha-256=<hex>, and the
            # checksum = "<hex>" line a lock file carries. Cut those out to decide, print the
            # line as it is so the reader fixes the right thing.
            stripped = rest
            gsub(/([Ss][Hh][Aa][-_]?256[:=]|checksum[[:space:]]*=[[:space:]]*")[0-9a-f]{64}/, "", stripped)
            if (stripped ~ /(^|[^:=_A-Za-z0-9-])[0-9a-f]{64}([^0-9a-f]|$)/) print head rest
        }' "$HITS" >"$HITS.kept" || true
    mv "$HITS.kept" "$HITS"

    if [ -s "$HITS" ]; then
        sed "s/^/FAIL node id: /" "$HITS"
        STATUS=1
    else
        echo "ok   no node id"
    fi
}

scan_node_id

[ "$STATUS" -eq 0 ] || echo "public_tree_check: a public tree names something it must not"
exit "$STATUS"
