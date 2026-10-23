#!/usr/bin/env bash
# The live test for mcl-nvidia-pair#8, from a machine that is NOT the bridge's
# host: a realm member gets a completion through the deployed bridge, a node
# with no realm membership is refused, and the rate limit trips.
#
#   ./scripts/live_test_pair8.sh
#
# WHAT IT NEEDS, and where each comes from:
#
#   MCL_REALM, MCL_REALM_KEY, MACULA_STATION_SEEDS, MACULA_STATION_NODE_IDS
#       The realm and the stations every mcl service dials. Same names, same
#       file shape as the bridge's own environment file; read from
#       PAIR8_ENV_FILE (default ~/.macula/secrets/mcl-nvidia-pair.env). Public
#       material, but a lab's own, so it never lives in this repository.
#
#   PAIR_MAX_PER_WINDOW
#       The per-caller limit the DEPLOYED bridge was configured with. The test
#       asserts against this number, so set it to the bridge's value; the
#       service's shipped default is 20.
#
#   A member key at PAIR8_MEMBER_KEY (default ~/.macula/secrets/pair8-member.key)
#       A node key the realm has ADMITTED. This script does not create or admit
#       one: the realm admits people, and a node gets its membership from its
#       person (macula-cli's `person init` / `person join` / `person bind`).
#       The test asks the realm for a membership UCAN with a proof signed by
#       this key, so a key the realm does not know fails with `not_admitted`
#       rather than a misleading mesh error.
#
#   A stranger key at PAIR8_STRANGER_KEY (default ~/.macula/secrets/pair8-stranger.key)
#       Generated on first run. Never admitted anywhere; that is the point.
#
#   PAIR8_TEST_MODEL (optional)
#       A model the PAIR cluster serves. Default qwen2.5:3b-instruct-q4_K_M.
set -euo pipefail

ENV_FILE=${PAIR8_ENV_FILE:-$HOME/.macula/secrets/mcl-nvidia-pair.env}
HERE=$(cd "$(dirname "$0")/.." && pwd)

say() { printf '\n== %s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "no environment file at $ENV_FILE (set PAIR8_ENV_FILE)"

say "load the realm and the stations (names only; values are not printed)"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
for name in MCL_REALM MCL_REALM_KEY MACULA_STATION_SEEDS MACULA_STATION_NODE_IDS; do
    [ -n "${!name:-}" ] || die "$ENV_FILE does not set $name"
done

MEMBER_KEY=${PAIR8_MEMBER_KEY:-$HOME/.macula/secrets/pair8-member.key}
[ -f "$MEMBER_KEY" ] || die "no member key at $MEMBER_KEY: the realm has to admit this node first (see the header)"
export MCL_PAIR8_MEMBER_KEY="$MEMBER_KEY"
export MCL_PAIR8_STRANGER_KEY="${PAIR8_STRANGER_KEY:-$HOME/.macula/secrets/pair8-stranger.key}"
export PAIR_MAX_PER_WINDOW="${PAIR_MAX_PER_WINDOW:-20}"

say "toolchain"
erl -noshell -eval 'io:format("OTP ~s~n",[erlang:system_info(otp_release)]),halt().'
rebar3 version

say "run the live test (member, stranger, rate limit)"
cd "$HERE"
exec rebar3 as live_test eunit --dir test_live --module=mcl_nvidia_pair_live_tests
