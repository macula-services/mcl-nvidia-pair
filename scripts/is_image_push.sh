#!/bin/sh
# Decides whether a push needs a new image, and prints build=true or
# build=false for $GITHUB_OUTPUT.
#
#   scripts/is_image_push.sh <before-sha> <after-sha>
#
# It builds UNLESS it can show that every changed path is documentation: Markdown,
# anything under docs/, the images under assets/, and the licence. A documentation
# push publishes an image nobody runs, so it is not worth the runner.
#
# Nobody follows :main, and :latest is not what the box runs either: the fleet pins
# a release's digest and the box runs that, so a release reaches it through a green
# v* tag and never through a push to main. But
# `paths-ignore' got the other half wrong: on the push that CREATES a branch GitHub
# has nothing to compare against and evaluates the filter on the head commit alone,
# so a first push ending in a docs commit built no image at all.
#
# So every case this script cannot read is a build: no before sha (a manual
# run), the all-zeros sha (a new branch or tag), a before sha that is not in
# the history (a force push), and an empty diff.
# Tested by scripts/is_image_push_test.sh.
set -eu

BEFORE="${1:-}"
AFTER="${2:?usage: is_image_push.sh <before-sha> <after-sha>}"

build() {
    echo "build=$1"
    exit 0
}

case "$BEFORE" in
    "" | 0000000000000000000000000000000000000000) build true ;;
esac

CHANGED=$(git diff --name-only "$BEFORE" "$AFTER" 2>/dev/null) || build true
[ -n "$CHANGED" ] || build true

# Documentation: any Markdown file, anything under docs/ or assets/, and the licence.
if printf '%s\n' "$CHANGED" | grep -qvE '(\.md$|^docs/|^assets/|^LICENSE$)'; then
    build true
fi
build false
