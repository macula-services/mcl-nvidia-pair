#!/bin/sh
# Tests for scripts/is_image_push.sh, run by .github/workflows/lint.yml.
#
# Each case builds a throwaway repository with two commits and asks the script
# what the push between them needs. The gate's own rule is that a change it
# cannot read is a build, so the cases where "build" is the safe answer are
# here beside the ones where it is not.
set -eu

SELF=$(cd "$(dirname "$0")" && pwd)/is_image_push.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILED=0

# expect <name> <want> <path>... : one commit touching only those paths.
expect() {
    name="$1"
    want="$2"
    shift 2
    repo="$WORK/$name"
    mkdir -p "$repo"
    git init -q "$repo"
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name test
    echo base >"$repo/base.keep"
    git -C "$repo" add base.keep
    git -C "$repo" commit -qm base
    before=$(git -C "$repo" rev-parse HEAD)
    for path in "$@"; do
        dir=$(dirname "$path")
        [ "$dir" = . ] || mkdir -p "$repo/$dir"
        echo change >>"$repo/$path"
    done
    git -C "$repo" add -A
    git -C "$repo" commit -qm change
    after=$(git -C "$repo" rev-parse HEAD)

    got=$(cd "$repo" && "$SELF" "$before" "$after")
    if [ "$got" = "$want" ]; then
        echo "ok   $name: $want"
    else
        echo "FAIL $name: expected $want, got $got"
        FAILED=$((FAILED + 1))
    fi
}

# expect_run <name> <want> <before> <after> : the script called with these shas.
expect_run() {
    name="$1"
    want="$2"
    shift 2
    got=$("$SELF" "$@" 2>&1) || got="exited $?"
    if [ "$got" = "$want" ]; then
        echo "ok   $name: $want"
    else
        echo "FAIL $name: expected $want, got $got"
        FAILED=$((FAILED + 1))
    fi
}

# Documentation only: no image.
expect readme build=false README.md
expect docs_dir build=false docs/runbook.txt
expect nested_docs build=false docs/design/DOMAIN.md
expect licence build=false LICENSE
# Diagrams are documentation too: a picture in assets/ is not a build input.
expect assets_svg build=false assets/c4-context.svg
expect assets_png build=false assets/img/logo.png

# Anything else is a build.
expect source build=true apps/foo/src/foo.erl
expect containerfile build=true Containerfile
expect script build=true scripts/health.sh
expect docs_and_source build=true docs/runbook.txt apps/foo/src/foo.erl
expect assets_and_source build=true assets/c4-context.svg apps/foo/src/foo.erl

# Cases the script cannot read are a build: a manual run, an all-zero sha (a
# new branch or tag), and a range with nothing in it.
expect_run manual_run build=true "" "$(git -C "$WORK/readme" rev-parse HEAD)"
expect_run new_branch build=true 0000000000000000000000000000000000000000 \
    "$(git -C "$WORK/readme" rev-parse HEAD)"
expect_run empty_range build=true \
    "$(git -C "$WORK/readme" rev-parse HEAD)" "$(git -C "$WORK/readme" rev-parse HEAD)"

echo "---"
if [ "$FAILED" -ne 0 ]; then
    echo "$FAILED failed"
    exit 1
fi
echo "all passed"
