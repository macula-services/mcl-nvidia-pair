# Getting started

## Prerequisites

- Erlang/OTP 28.4.3 and rebar3 (`.tool-versions`), plus a Rust toolchain:
  macula builds native code from source.
- A local [NVIDIA PAIR](https://github.com/NVIDIA/Personal-AI-Router) install on
  the **same machine**, if you want to reach a real cluster. PAIR's loopback proxy
  refuses callers from other machines by design, so the bridge and a PAIR cluster
  member must share a host. Without PAIR you can still build and run the tests;
  see "Without a PAIR install" below.
- A Macula realm, its public signing key, and a station to dial, if you want the
  mesh side. Without them the service boots, announces nothing, and reports
  itself degraded on `/health`.

## Build and test

```bash
rebar3 compile
rebar3 eunit
rebar3 lint
```

The first compile builds native dependencies (rocksdb, macula's NIFs) and takes
several minutes; later compiles are fast.

The tests cover the chat handler's translation in both directions, the gate's
configuration, the PAIR client (request building, response parsing, errors) and
the rate limiter. PAIR's HTTP calls and the mesh are stand-ins in every test.

## Configuration

Everything that differs between deployments comes from the environment,
substituted into `config/sys.config.src` when the release boots.

| Variable | Required | What it is |
|---|---|---|
| `MCL_REALM` | yes | The realm tag: 64 hex characters, the sha256 of the realm's name. |
| `MCL_REALM_KEY` | yes | The realm's public signing key, hex. It is the trust anchor for the mesh, and the membership gate is derived from it: macula admits a caller only with a member token signed by this key. |
| `MACULA_STATION_SEEDS` | yes | Station hosts to dial, `host[:port]`, comma-separated. |
| `MACULA_STATION_NODE_IDS` | yes | The matching station node ids, index-paired with the seeds. |
| `MCL_HEALTH_PORT` | no, 8499 | The `/health` port. |
| `MCL_SERVICE_NAME` | no, `mcl-nvidia-pair` in compose | Label on the boot claim the realm's operator sees on the Providers desk. |
| `MCL_BOX` | no | Label naming the host, also on the boot claim. Set it where you deploy. |
| `PAIR_BASE_URL` | yes in the image (11435) | Where PAIR's own Ollama-compatible facade listens on this host. 11435 when PAIR adopted an Ollama that already holds 11434, which is the lab box's shape; 11434 on a box with no local Ollama. Point it at PAIR, never at the engine behind it. |
| `PAIR_MAX_PER_WINDOW` | no, 20 | The per-caller rate limit: calls one caller may make in one window. Set it to the box's hardware budget, not to a number you like. |
| `PAIR_WINDOW_SECONDS` | no, 60 | The length of that window. |

The org is fixed, `mcl-nvidia-pair`, in `config/sys.config.src`: the wire name
is `mcl-nvidia-pair/chat`, and the realm's grant names that org.

The rate limit is read from the environment because it belongs to the
deployment: `sys.config.src` substitutes both variables, so a deploy that wants
others passes them and never rebuilds. Everything else is tuned as plain edits
to `config/sys.config.src` (the code's defaults apply when absent):

- `chat_to_pair`: `pair_base_url` (the `PAIR_BASE_URL` above),
  `pair_timeout_ms` (default 120000).
- `mcl_nvidia_pair`: `required_can`, the membership tier a caller's token must
  carry (default `member/email-verified`, what macula-realm grants a member
  whose person confirmed the node on the web join).

## Without a PAIR install

Every test stands in for PAIR, so the whole suite runs without one. To try the
PAIR side against a real install, start a shell and call the client directly:

```erlang
rebar3 shell
1> chat_to_pair:chat(<<"llama3">>, [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]).
```

That talks to `pair_base_url`. A real answer back, not merely "it did not
crash", is what shows the forwarding works.

## Health

`/health` answers 200 when the service is configured to serve, PAIR answers on
`/v1/models`, and the realm has granted this node its procedure; otherwise 503,
with the reason. The grant appears under `provider_grants`.

## Image and deployment

`Containerfile` builds the release on `ghcr.io/macula-io/macula-ci-otp` (OTP
28.4.3) and runs it on `macula-pq-runtime`, both pinned by dated tag and digest.
`deploy/docker-compose.yml` is the service's own run contract. It uses host
networking, which is also what lets the container reach PAIR on the host's
loopback. CI tests every push and builds the image on `main` and on `v*` tags.

A board that runs the fleet reconciles it from its own GitOps repository, with
the image pinned by digest; that entry is the deployment's, not this
repository's.

## A live test before the first release exists

Before a signed release there is no image, so the box that holds PAIR builds one
from a git ref and runs it as a throwaway container — outside whatever manages
the box's own units, with a name the script owns and one command to remove it.
`scripts/deploy_test_bridge.sh` does that, and only that:

    PAIR8_REF=<branch|tag|sha> ./scripts/deploy_test_bridge.sh start
    ./scripts/deploy_test_bridge.sh status
    ./scripts/deploy_test_bridge.sh stop

It reads the realm and the stations from an environment file outside git
(`PAIR8_ENV_FILE`, default `~/.macula/secrets/mcl-nvidia-pair.env`), deriving it
on a box that already carries a fleet unit for another service when the file is
absent, and it never prints a value. Then the service claims, and the realm's
operator admits the claim on the Providers desk; `/health` reports 503 with the
missing grant until that happens, which is the truthful state rather than a
fault.

## The live test

`test_live/mcl_nvidia_pair_live_tests.erl` is the measurement the README's
status section reports. It runs from a machine that is NOT the bridge's host and
proves three things against the deployed bridge, a real realm and a real PAIR
cluster:

1. a realm member's call returns a completion;
2. a node with no realm membership is refused, with macula's own `unauthorized`
   code rather than a resolve miss or a timeout;
3. the per-caller rate limit trips. Asserted as a `rate_limited` refusal SEEN
   inside a 3-window budget, plus a ceiling of `PAIR_MAX_PER_WINDOW`
   completions per window the burst spanned — never as a fixed call number,
   because the window is fixed and counted per caller node: a burst that
   starts late in a window gets the next window's budget too.

    PAIR8_ENV_FILE=~/.macula/secrets/mcl-nvidia-pair.env \
    PAIR_MAX_PER_WINDOW=20 \
    ./scripts/live_test_pair8.sh

Environment: the same realm and station variables the service takes (same file),
`PAIR_MAX_PER_WINDOW` set to what the deployed bridge was given, a **member**
node key at `PAIR8_MEMBER_KEY`, and `PAIR8_TEST_MODEL` naming a model the
cluster serves. The stranger key is generated on first run and is admitted
nowhere, which is the point.

The test never mints a membership: it asks the realm for a membership UCAN with
a proof signed by the member key, which is what every macula client does, so a
node the realm has not admitted fails with `not_admitted` and a node it has
stopped admitting is refused within the token's hour.

Admitting the member is the realm's act, not this repository's, and it is two
commands plus one human confirmation (macula-cli, released clients only):

    macula-cli person init                     # a person key, outside the repository
    macula-cli person join -realm <name>       # prints a join URL; confirm it in a browser, signed in
    macula-cli person bind -to <node id>       # that node becomes the person's client

A node bound to a person carries `member/email-verified`, which is the tier this
bridge requires by default; a node admitted only by its own key carries
`member/device-verified` and this gate refuses it, deliberately.

The node id `person bind` takes is the member key's, and the test prints it on
its first run (`connected as <64 hex>`) before it can succeed. To end the test
member afterwards: `macula-cli person unbind -to <node id>` ends that client's
membership, and a realm admin revoking the member on the Members desk ends the
person's — the client goes with it.
