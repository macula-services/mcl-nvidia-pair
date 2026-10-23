<!-- Service README template: swap the service name in the badge URLs and the
     package link; everything else is shared. -->

[![CI](https://img.shields.io/github/actions/workflow/status/macula-services/mcl-nvidia-pair/lint.yml?branch=main&label=CI)](https://github.com/macula-services/mcl-nvidia-pair/actions/workflows/lint.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![ghcr.io](https://img.shields.io/badge/ghcr.io-macula--services%2Fmcl-nvidia-pair-blue.svg)](https://github.com/macula-services/mcl-nvidia-pair/pkgs/container/mcl-nvidia-pair)
[![BEAM](https://img.shields.io/badge/beam-28%2B-A90533?logo=erlang&logoColor=white)](https://www.erlang.org)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub%20Sponsors-support-ea4aaa.svg?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/rgfaber)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-ffdd00.svg?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/rlefever)

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/macula-full-dark.svg">
    <img src="assets/macula-full-light.svg" alt="Macula" width="320">
  </picture>
</p>
---
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/macula-erl-full-dark.svg">
    <img src="assets/macula-erl-full-light.svg" alt="Macula" width="320">
  </picture>
</p>

<p align="center">
  <strong>A bridge between a household's own NVIDIA PAIR cluster and a Macula realm</strong>
</p>

## Status: measured end to end, not yet released

**Measured 23 October 2026** from a second machine, against this bridge running
beside an unmodified PAIR install on its own host (CPU inference; that host's
GTX 1050 Ti driver is broken and was not part of the test).

| Claim | What the run showed |
|-------|---------------------|
| A realm member gets a completion | the member's token carried `member/email-verified`; `qwen2.5:3b-instruct-q4_K_M` answered `ready` (5 bytes) |
| A node with no realm membership is refused | `{error, {call_error, <<"unauthorized">>, undefined}}` |
| The per-caller limit trips | 20 per 60 s window; the burst was refused `rate_limited` on its 20th call, 19 completions served. The window is fixed and counted per caller node, so a burst across a rollover gets a fresh budget: the test asserts that a refusal was SEEN inside a 3-window budget, plus a per-window ceiling on completions, never a fixed call number |

One command runs all three: `scripts/live_test_pair8.sh`. The suite lives in
`test_live/` and outside CI's gate on purpose — it cannot pass without a
deployed bridge.

The unit suite in `test/` is the other half: it replaces PAIR and the mesh with
stand-ins and runs in CI on every push.

**What has not happened yet:**

- No release: no `v*` tag, no signed image, no digest pin in the fleet.
- One bridge per cluster, no cluster introspection, no redundancy, and no
  measurement beyond the three claims above.
- The rate limit is per caller NODE, not per person: one member with three
  bound nodes gets three budgets.
- The member key must be bound to its person *before* the node's first
  connect. A node the realm has already admitted in its own right cannot be
  bound afterwards (the realm answers `client_already_member`), so a key that
  has connected once has to be replaced rather than admitted.

**Revoking the test member:** `macula-cli person unbind -to <client node id>`
ends that client's membership; ending the person, which a realm admin does on
the Members desk, ends every client it has.

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

- **Realm side:** it offers one procedure, `mcl-nvidia-pair/chat`, to the realm. Macula
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
[`docs/DESIGN.md`](docs/DESIGN.md).

Like every mcl service, it also answers `mcl-nvidia-pair/info`, which mcl_om adds: its
name, version and description, its org and claim labels, node id, the macula
and mcl_om versions, uptime, the health word and the procedures it advertises.
Open to any mesh caller, public facts only.

## Layout

```
apps/mcl_nvidia_pair/        The service: boots on mcl_om, offers mcl-nvidia-pair/chat, reports /health
apps/chat_to_pair/           Forwards one authorised chat request to PAIR's loopback proxy
apps/throttle_pair_callers/  Per-caller fixed-window rate limit (macula has no inbound throttle)
config/                      sys.config.src, filled from the environment at boot
deploy/                      docker-compose.yml, the service's own run contract
docs/                        The design (and how it was reached), getting started
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
