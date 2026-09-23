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
| `MCL_ORG` | yes, to serve | The org the procedure lives in: the wire name is `<org>/chat`, and the realm's grant names this org. |
| `MCL_REALM` | yes | The realm tag: 64 hex characters, the sha256 of the realm's name. |
| `MCL_REALM_KEY` | yes | The realm's public signing key, hex. It is the trust anchor for the mesh, and the membership gate is derived from it: macula admits a caller only with a member token signed by this key. |
| `MACULA_STATION_SEEDS` | yes | Station hosts to dial, `host[:port]`, comma-separated. |
| `MACULA_STATION_NODE_IDS` | yes | The matching station node ids, index-paired with the seeds. |
| `MCL_HEALTH_PORT` | no, 8499 | The `/health` port. |

Tuning, as plain edits to `config/sys.config.src` (the code's defaults apply when
absent):

- `chat_to_pair`: `pair_base_url` (default `http://127.0.0.1:11434`),
  `pair_timeout_ms` (default 120000).
- `throttle_pair_callers`: `max_per_window` and `window_seconds` (default 20
  requests per caller per 60 s).
- `mcl_nvidia_pair`: `required_can`, the membership tier a caller's token must
  carry (default `member/email-verified`, what macula-realm grants a member).

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

`Containerfile` builds an Alpine image with OTP 28.4.3, pinned by digest.
`deploy/docker-compose.yml` is the service's own run contract. It uses host
networking, which is also what lets the container reach PAIR on the host's
loopback. CI tests every push and builds the image; nothing deploys it yet.
