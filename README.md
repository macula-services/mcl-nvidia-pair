# mcl-nvidia-pair

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/macula-erl-full-dark.svg">
    <img src="assets/macula-erl-full-light.svg" alt="Macula" width="320">
  </picture>
</p>

<p align="center">
  <strong>A bridge between a household's own NVIDIA PAIR cluster and a Macula realm</strong>
</p>

## Status: skeleton, not yet in service

This is an early, unfinished service. Read this section before anything else.

**What exists and is tested:** the code for one narrow path (a chat request in, a
response out), a gate that lets only members of one realm call it, and a
per-caller rate limit. It compiles on Erlang/OTP 28.4.3 against macula 12, and
its unit tests pass. Those tests replace NVIDIA PAIR and the mesh with stand-ins.

**What has not happened yet:**

- It has never forwarded a live request from the mesh to a real PAIR cluster.
- No realm member has ever passed its gate over the mesh. The gate relies on
  membership tokens that macula-realm issues under macula 12; that issuance
  exists in macula-realm's code, and nobody has yet run it end to end with this
  service.
- It is not deployed anywhere.
- It does no cluster introspection, runs one bridge per cluster with no
  redundancy, and has not been measured under load.

## What it is meant to become

[NVIDIA PAIR](https://github.com/NVIDIA/Personal-AI-Router) (Personal AI Router)
turns a household's own machines into one local inference cluster: LAN-scoped,
Ollama- and OpenAI-compatible, with no changes needed to the programs that use
it. This service does not reimplement any of that. It sits next to an unmodified
PAIR install as a thin translator, so that members of a
[Macula](https://github.com/macula-io/macula) realm can use that cluster from
elsewhere, and nobody outside the realm can:

```
Macula realm  <--(macula 12 RPC, realm members only)-->  mcl-nvidia-pair  <--(loopback HTTP)-->  PAIR cluster
  (wide area, post-quantum)                                (this repo)          (unmodified, LAN only)
```

- **Realm side:** it offers one procedure, `<org>/chat`, to the realm. Macula
  admits a call only with a membership token the realm signed, carrying the
  required tier (`member/email-verified` by default). The check happens in
  macula before the call reaches this service's code.
- **PAIR side:** it forwards an accepted chat request to PAIR's own
  Ollama-compatible proxy on the same machine, over plain loopback HTTP. No change
  to PAIR, no pairing, no extra certificates. That is also why it must run on a
  machine that is already a member of the PAIR cluster.

It implements exactly one operation and builds the outbound request itself. It
never forwards a caller's path, so PAIR's own admin surface (`/api/pull`,
`/api/delete`, engine control) is not reachable from the realm.

How the design was arrived at, and what it rejected:
[`plans/DESIGN_FEASIBILITY_ASSESSMENT.md`](plans/DESIGN_FEASIBILITY_ASSESSMENT.md).

## Layout

```
apps/mcl_nvidia_pair/        The service: boots on mcl_om, offers <org>/chat, reports /health
apps/chat_to_pair/           Forwards one authorised chat request to PAIR's loopback proxy
apps/throttle_pair_callers/  Per-caller fixed-window rate limit (macula has no inbound throttle)
config/                      sys.config.src, filled from the environment at boot
deploy/                      docker-compose.yml, the service's own run contract
plans/                       The design and how it was reached
docs/                        Getting started
```

## Running it

Erlang/OTP 28.4.3 and rebar3 (see `.tool-versions`).

    rebar3 compile
    rebar3 eunit
    rebar3 lint

See [`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md) for configuration and
for trying the PAIR side against a real local install.

`/health` (port 8499) reports three things: whether the configured PAIR backend
answers, whether the service is configured to serve at all, and, from mcl_om,
whether the realm has granted this node its procedure.

## Licence

Apache-2.0.
