# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- **The live test the status section reports (mcl-nvidia-pair#8, step 3).**
  `test_live/mcl_nvidia_pair_live_tests.erl` runs from a machine that is not
  the bridge's host and proves three things against a deployed bridge: a realm
  member's call returns a completion, a node with no realm membership is
  refused with macula's own `unauthorized` code, and the per-caller rate limit
  trips. It lives outside `test/` and outside CI's gate on purpose — it cannot
  pass without that deployment — and runs as
  `rebar3 as live_test eunit --dir test_live`, which is what
  `scripts/live_test_pair8.sh` sets up (the realm, the stations and the model
  come from the environment; the member key is a file the realm has admitted).
  The test mints its own membership UCAN by proving the member key to the
  realm, so a revocation is felt the same way any client feels it.
- **`scripts/deploy_test_bridge.sh`**: builds an image from a git ref on the
  box beside PAIR and runs it as a named throwaway container, outside whatever
  manages that box's units, with one command to remove it. This is how the
  live test reaches a deployed bridge before the first signed release exists.
  It derives the realm and station values from the box's own fleet unit when
  the operator's environment file is absent, and never prints a value.
- **The per-caller limit is a deployment setting**, not a source edit:
  `PAIR_MAX_PER_WINDOW` and `PAIR_WINDOW_SECONDS` are substituted into
  `sys.config.src`, shipped at 20 per 60 s in the image and overridable in
  `deploy/docker-compose.yml`. The live test is told the same value, so what it
  asserts is what the node enforces.

### Changed

- **macula is declared, at 16** (macula-codebase-checks#4, #14). The
  service called macula modules and compiled against `macula_response`
  without declaring the application: it arrived transitively through
  `mcl_om`, so a rebuild took whatever major the newest mcl_om carried.
  `macula` is now a direct dependency at `~> 16.0` and `mcl_om` is at
  `~> 1.4`, the release whose own base is macula 16. 16.0 keeps wire 1.0,
  so this service still speaks to every wire 1.0 box; what it adds is the
  revocation bound (macula#118). This service gates no overlay and issues
  no endorsement.
- **On `mcl_om` 0.28 with macula 12.2.** The service answers `mcl-nvidia-pair/info`,
  which mcl_om adds (public facts: versions, labels, health word, procedures),
  and a test sends that reply through macula's frame codec and checks it names
  this service and the mcl_om 0.28 / macula 12.2 pair. 0.28 is the release
  macula 12.2 needs: under 12.2 an older mcl_om lets a failed publish
  announcement kill the publishing process.
- On `mcl_om` 0.27. The boot claim carries `MCL_SERVICE_NAME=mcl-nvidia-pair`
  and the host's `MCL_BOX`, shown on the realm's Providers desk. 0.27 no longer
  brings barrel_docdb or rocksdb.
- The org is fixed in `config/sys.config.src`, `mcl-nvidia-pair`, instead of
  `MCL_ORG` from the deploy: it is a property of the service. The procedure is
  `mcl-nvidia-pair/chat`.
- The team image pair: builds in `macula-ci-otp` and runs on `macula-pq-runtime`
  (Debian trixie), pinned by dated tag and digest, instead of an Alpine builder
  and a floating `alpine:3.22` runtime. CI runs in the same build image.

### Added

- The first slice, ported to macula 12 and mcl_om 0.26.3 from its predecessor
  (hecate-nvidia-pair, on hecate_om and macula 10/11), on the `mcl_service`
  scaffold:
  - `<org>/chat`, offered through mcl_om's capability path, gated by
    `{realm_member_required, RealmKeyId, RequiredCan}`. The realm key id is
    derived from `MCL_REALM_KEY`, the key mcl_om already pins, so the gate and
    the trust anchor name the same realm. Nothing is announced without a realm
    key and a real org; the procedure is never served open.
  - `mcl_nvidia_pair_mesh_rpc`, the `macula_response` handler: folds a macula
    12 payload to one shape, counts the call against the wire-authenticated
    caller, forwards it, and replies with its text tagged so non-BEAM callers
    receive text, not bytes. Failure reasons cross the wire as single atoms.
  - `chat_to_pair`: forwards one chat completion to PAIR's loopback
    Ollama-compatible proxy, never a caller-supplied path; `probe/0` backs
    `/health`.
  - `throttle_pair_callers`: per-caller fixed-window rate limit.
  - `/health` is degraded when the service is not configured to serve, or PAIR
    does not answer; mcl_om adds the realm's grant for `<org>/chat`.
- Image, compose file with the named identity volume, and CI from the scaffold,
  on OTP 28.4.3 pinned by digest.

### Not yet done

No live call has reached a real PAIR cluster, no realm member has passed the
gate over the mesh, and nothing deploys this service. See the README.
