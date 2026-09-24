# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

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
