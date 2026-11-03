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
#   a bare node id   64 lowercase hex characters, which is a node's id -- unless the line is
#                    about a checksum or a digest, which look the same
#
# Text files only (`grep -I` skips binaries) and .git is never read. Every hit is printed, so a
# failure names the line to fix rather than only saying the tree is dirty.
#
# Tested by scripts/public_tree_check_test.sh, which lint.yml runs beside this one.
set -eu

ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
HITS=$(mktemp)
trap 'rm -f "$HITS"' EXIT
STATUS=0

scan() {
    label=$1
    pattern=$2
    exclude=$3

    # --exclude as well as --exclude-dir: in a worktree .git is a FILE holding the real
    # repository's path, and --exclude-dir does not touch a file.
    grep -rnIE --exclude-dir=.git --exclude=.git -e "$pattern" "$ROOT" >"$HITS" 2>/dev/null || true
    if [ -n "$exclude" ] && [ -s "$HITS" ]; then
        grep -viE -e "$exclude" "$HITS" >"$HITS.kept" || true
        mv "$HITS.kept" "$HITS"
    fi

    if [ -s "$HITS" ]; then
        sed "s/^/FAIL $label: /" "$HITS"
        STATUS=1
    else
        echo "ok   no $label"
    fi
}

scan "lab hostname" '[A-Za-z0-9_-]+\.lab([^A-Za-z0-9_-]|$)' ''
scan "home path"    '/home/[A-Za-z0-9._-]+' ''
scan "fleet path"   'edge/[A-Za-z0-9._-]+/' ''
scan "node id"      '[0-9a-f]{64}' 'sha[-_]?256'

[ "$STATUS" -eq 0 ] || echo "public_tree_check: a public tree names something it must not"
exit "$STATUS"
