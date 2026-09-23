# mcl-nvidia-pair: Design & Feasibility

**Status:** Design converged on an architecture (the "bridge" model). A first slice is built; the
README says exactly what it does today.
**Created:** 2026-09-08. Superseded a from-scratch-reimplementation framing the same day — see
"Superseded: the reimplementation framing" below for why that framing was replaced, not deleted.

## The design: a bridge, not a reimplementation

`mcl-nvidia-pair` is a thin Erlang/OTP service that sits **next to** an unmodified NVIDIA PAIR
installation, translating between one local PAIR cluster and the wider Macula realm. It does not
reimplement, fork, or modify PAIR's own protocol, trust model, or discovery layer.

```
Macula realm  <--(macula RPC, mcl_om capability)-->  mcl-nvidia-pair bridge  <--(loopback HTTP)-->  PAIR cluster
  (WAN, realm-scoped trust)                              (Erlang/OTP, one per cluster)      (unmodified, LAN-scoped, EAP-NOOB pairing)
```

- **Bridge → PAIR (unmodified)**: the bridge runs co-located on a machine that is already a PAIR
  cluster member, and calls PAIR's own existing Ollama-compatible (`:11434`) or OpenAI-compatible
  (`:1234`) proxy over plain loopback HTTP — the same "any agent, zero code changes" interface PAIR
  already guarantees for every other consumer. PAIR does the cross-machine routing, scheduling, and
  failover it already does today; the bridge never touches that.
- **Bridge → realm (new)**: the bridge boots `mcl_om` and advertises a capability
  (`mcl-nvidia-pair/chat`) into the realm, the same pattern every mcl-* service already uses (see
  `mcl-echo`). It validates realm membership/UCAN capability on each inbound call,
  applies quota/rate-limiting, and forwards **only** an accepted chat-completion request to PAIR's local
  proxy — nothing else. It is a purpose-built narrow translator, not a transparent proxy.

### Why this sidesteps nearly every blocker the reimplementation framing found

Because the bridge only ever calls PAIR's already-loopback-gated proxy with a chat-completion request it
constructs itself, it never inherits PAIR's internal trust or exposure model:

- **No EAP-NOOB / roster / endorsement / tombstone rework.** The bridge doesn't participate in PAIR's
  pairing protocol at all (loopback caller, not a cluster peer) — or, if it wants cluster introspection
  (see below), it participates as an ordinary member using PAIR's pairing exactly as designed. Either
  way, zero code changes to PAIR's trust layer.
- **No discovery wire-format rework.** mDNS, `noderec.DirectoryNode`, IP/IPs threading — all stays
  exactly as PAIR already has it, purely internal to one LAN cluster. The realm never sees it.
- **No new QUIC transport primitive needed.** PAIR-side traffic is plain loopback HTTP (`httpc`/`gun`,
  nothing new). Realm-side traffic is a standard macula RPC/capability call — the same primitive
  every mcl-* service already uses. The earlier "does macula
  expose a net.Conn-shaped QUIC stream" investigation (see appendix) turned out to be answering a
  question this design doesn't actually ask.
- **No O(N) full-mesh chatter concern.** PAIR's internal polling is capped at the size of one household
  cluster, completely orthogonal to how many bridges exist across the realm. Bridges don't need to know
  about each other — realm-side discovery of *which* bridge to call is ordinary macula DHT/capability
  advertisement, exactly like finding any other realm service.
- **The abuse-surface finding (any pinned peer = local admin, no route filtering) does not carry over.**
  That vulnerability is a property of PAIR's own cluster-internal mTLS ingress, which the bridge never
  exposes to the realm. The bridge is new code that implements exactly one operation
  (chat-completion-in, response-out) — there is no code path for a realm caller to reach `/api/pull`,
  `/api/delete`, `keep_alive: -1`, or engine-control, because the bridge never forwards a path, only a
  request it constructs itself.

### What's genuinely new work under this design

Smaller and more concrete than the reimplementation framing's list:

1. **The bridge itself** (Erlang/OTP, new): `mcl_om` boot + capability advertisement, realm-auth/UCAN
   check on inbound calls, quota/rate-limiting (neither PAIR nor Macula has any inbound throttle today —
   this remains genuinely unbuilt anywhere), request translation to PAIR's chat-completion shape, plain
   HTTP call to loopback, response translation back.
2. **Cluster introspection (optional, not needed for MVP)**: if the bridge should know cluster capacity/
   model availability before accepting a realm request, rather than blind-forwarding and surfacing
   whatever PAIR itself returns — two shapes, evaluated on their own merits when needed:
   - Zero new code: have the bridge machine pair into the cluster as an ordinary member (nothing in
     `nvpair-cluster-manager` requires a local engine to admit a member — the architecture's own flow is
     Start → Discover → Pair → *Prepare (engines)* → Serve, and Prepare is a separate, optional step
     after pairing). A paired bridge can then read `node-info`/`model-list` over PAIR's existing
     mTLS peer surface like any other node.
   - A small new read-only, non-admin "cluster summary" endpoint added to a PAIR fork of our own —
     exposes strictly less than `node-info` already does per-node, so it doesn't reopen the
     route-filtering problem. Generic enough to eventually propose upstream (see below); developed in
     the fork first so mcl-nvidia-pair isn't blocked on NVIDIA's own review cadence.
3. **Deployment shape**: one bridge instance per PAIR cluster (one per household/site that wants realm
   participation). A bridge machine going down makes that cluster realm-unreachable even if the rest of
   the cluster is healthy — running the bridge on more than one cluster member is a legitimate later
   refinement, not a blocker.
4. **Revocation**: a member token stays valid until it expires (4 hours by default, 30 days at most,
   as macula-realm issues them under macula 12). Whether macula-realm can withdraw a member sooner is a
   macula-realm question the bridge inherits, not something specific to this design, and not a reason
   to block on.

### Upstream vs. fork, for anything built on the PAIR side

Only the optional cluster-summary endpoint (item 2 above) touches PAIR's own code at all — the core
bridge design touches nothing in PAIR. For that endpoint specifically: build and use it in a fork of our
own while iterating (PAIR's own merge cadence is an unknown worth not blocking on — a notable community
fork adding AMD/ROCm support has sat unmerged for a while), and consider proposing it upstream once
proven, since a generic "safe, read-only, non-admin cluster summary" is a legitimate, welcome-looking
feature for PAIR's whole community, not something Macula-specific.

---

## Superseded: the reimplementation framing

The design above replaced an earlier framing that assumed this bridge would reimplement PAIR's
scheduler/discovery/proxy/trust layers directly against Macula's own transport and realm primitives —
i.e. treating PAIR as source material to port, not as a black box to sit next to. That framing is kept
below for reference: it correctly explains *why* the bridge model is the better choice (every blocker it
found is a property of reimplementing PAIR's internals, and every one of them evaporates once the design
stops doing that).

<details>
<summary>Original reimplementation-framing assessment (superseded 2026-09-08)</summary>

Two independent Claude assessments read the real cloned source at `NVIDIA/Personal-AI-Router` (not just
its docs) and converged on: **borrow the architecture, don't fork the repo** — reimplement against
Macula's own primitives from the ground up, not swap one module. Reconciled against three technical
pushbacks from Raf:

**1. "Would we need TCP tunneling? We have QUIC."** A raw QUIC stream (`macula-go`'s
`session.conn.OpenStreamSync`, unexported) is already `net.Conn`-shaped in the underlying `quic-go`
library — not "TCP tunneled over QUIC." But macula-go's *public* API (`stream.Handle`) is message-framed
CBOR, not a raw byte pipe, so a thin wrapper exposing the raw stream would need building. Moot under the
bridge design (no macula-go transport needed at all — see "why this sidesteps" above); genuinely relevant
only if some future macula-go-based project wants a raw peer-to-peer byte stream for its own reasons. On
the Erlang side specifically, this concern doesn't even apply: `macula_quic.erl` already exposes a public,
`gen_tcp`-shaped raw stream API (`open_stream/1`, `send/2`, `controlling_process/2`, `{quic, Data, ...}`
messages) — no gap to fill there at all.

**2. "Pairing of a PAIR cluster with the mesh would be at the cluster level."** Verified against
`ollama-proxy/ingress.go`: `handleClusterIngress` is a raw `httputil.ReverseProxy` with zero path
filtering by explicit design ("the mTLS pin is the sole authorization boundary"). Cluster-level pairing
reduces blast radius (fewer external principals reach fewer machines) but does not by itself add the
missing distinction between inference and administration — a naive gateway relay reproduces the identical
vulnerability one hop out. Moot under the bridge design, which never relays arbitrary paths at all.

**3. "No full-mesh polling, we'd need to define a protocol."** Not a structural requirement — the
scheduler already tolerates staleness by design (`architecture.mdx`: "eventual consistency... collisions
self-correct"), so a pubsub/DHT-based redesign fits naturally. Moot under the bridge design, which never
needs cluster-wide telemetry propagated across the realm at all.

**Trust model correction** (Fable's pass, verified independently): PAIR's trust is not simple
byte-for-byte cert pinning — `nvpair-cluster-manager`'s `endorsement.go` + `roster.go` implement a real
gossiped web of trust (transitive endorsement fan-out, signed removal tombstones with admission-epoch
fencing). This is genuinely more sophisticated engineering than first assessed, and its removal semantics
(immediate, signed, cluster-wide) are currently *better* than Macula's own revocation. Still true and
still worth knowing — it's just now a fact about PAIR's internals the bridge design never needs to touch,
rather than something to port or replace.

**What the old framing said would carry over vs. rebuild** (all superseded — none of it is reused OR
rebuilt under the bridge design, because the bridge never reimplements PAIR at all):
reuse-as-is: proxies' routing/failover, job scheduler, engine-manager, broker/TUI. Rebuild: discovery wire
format, transport layer. Drop entirely: the whole EAP-NOOB/pairing/roster/endorsement/tombstone layer.
Build from scratch: route allowlist, quotas, sender-bound workload events, telemetry trust.

</details>
