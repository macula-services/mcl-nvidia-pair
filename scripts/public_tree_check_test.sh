#!/bin/sh
# Tests for scripts/public_tree_check.sh, run by .github/workflows/lint.yml.
#
# Each case builds a throwaway tree holding one line and asks the check what it
# makes of it: a hit for each family it exists to catch, and nothing for the
# things that only look like one -- a signed digest, a checksum variable, a
# person's own secrets directory.
#
# The fixture text is assembled at run time on purpose. Spelled out here it
# would be a hit in THIS file, and the check would fail the tree it protects.
set -eu

SELF=$(cd "$(dirname "$0")" && pwd)/public_tree_check.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILED=0

DOT=.
LABSUFFIX="lab"
HEX64=$(printf '%064d' 0)
# a different 64 hex characters, so "the digest was stripped" and "the node id went with it"
# cannot look the same in the failure output
DIGEST64=$(printf 'a%063d' 0)

# expect <name> <want-exit> <line> : a tree whose README holds this one line.
expect() {
    name=$1
    want=$2
    line=$3
    tree="$WORK/$name"
    rm -rf "$tree"
    mkdir -p "$tree"
    printf '# notes\n\n%s\n' "$line" >"$tree/README.md"

    got=0
    out=$("$SELF" "$tree" 2>&1) || got=$?
    if [ "$got" -eq "$want" ]; then
        echo "ok   $name: exit $got"
    else
        echo "FAIL $name: expected exit $want, got $got"
        printf '%s\n' "$out" | sed 's/^/       /'
        FAILED=$((FAILED + 1))
    fi
}

# assemble a machine name without this file containing one
machine=$(printf 'msi%s%s%s' 00 "$DOT" "$LABSUFFIX")
fleetpath=$(printf '%s%s%s' "edge" "/gitops/" "release-targets")
homepath=$(printf '%s%s%s' "/home" "/rl" "/work")

upper=$(printf 'BEAM%s%s%s' 02 "$DOT" "$LABSUFFIX")

expect "a clean line"                 0 "Run the bridge on port 8499."
expect "a lab machine name"           1 "see $machine for the unit"
expect "a lab machine, mid-line"      1 "pinned in $machine:41 by hand"
expect "a lab machine in upper case"  1 "pin it at $upper:41"
expect "a home directory"             1 "the key sits in $homepath/key"
expect "a fleet path"                 1 "the pin lives in $fleetpath"
expect "a bare node id"               1 "node $HEX64 is admitted"
expect "an unsigned digest"           0 "digest sha256:$DIGEST64 is what shipped"
expect "a checksum variable"          0 "GO_SHA256=$DIGEST64 is checked after download"
expect "a lock file checksum"         0 "checksum = \"$DIGEST64\""
expect "a person's own secrets dir"   0 "put the key in ~/.macula/secrets/bridge.env"

# A node id on a line that ALSO carries a digest, the other way round: the digest is a checksum
# and is fine, the node id beside it is not, and one must not excuse the other.
expect "a node id beside a digest"    1 "node $HEX64 sent digest sha256:$DIGEST64"

# Build output is not the tree. A local run after rebar3 compile must agree with CI.
tree="$WORK/builddir"
mkdir -p "$tree/_build/default/lib"
printf 'node %s\n' "$HEX64" >"$tree/_build/default/lib/compiled.txt"
got=0
out=$("$SELF" "$tree" 2>&1) || got=$?
if [ "$got" -eq 0 ]; then
    echo "ok   build output is skipped: exit 0"
else
    echo "FAIL build output is skipped: expected exit 0, got $got"
    printf '%s\n' "$out" | sed 's/^/       /'
    FAILED=$((FAILED + 1))
fi

# The whole family at once, so a fix for one does not quietly drop another.
tree="$WORK/all"
mkdir -p "$tree"
{
    printf '%s\n' "a $machine"
    printf '%s\n' "b $homepath"
    printf '%s\n' "c $fleetpath"
    printf '%s\n' "d $HEX64"
} >"$tree/NOTES.md"
got=0
out=$("$SELF" "$tree" 2>&1) || got=$?
hits=$(printf '%s\n' "$out" | grep -c '^FAIL' || true)
if [ "$got" -eq 1 ] && [ "$hits" -eq 4 ]; then
    echo "ok   four families in one tree: four hits"
else
    echo "FAIL four families in one tree: expected exit 1 and 4 hits, got exit $got and $hits"
    printf '%s\n' "$out" | sed 's/^/       /'
    FAILED=$((FAILED + 1))
fi

if [ "$FAILED" -eq 0 ]; then
    echo "public_tree_check_test: every case holds"
else
    echo "public_tree_check_test: $FAILED failure(s)"
    exit 1
fi
