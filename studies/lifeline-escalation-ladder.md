# Four independent mechanisms, not one "reliability" module

## The problem

A headless tiny cloud VM can go dark in several unrelated ways, and no
single fix covers all of them:

- The overlay/mesh agent (a NetBird/Tailscale/WireGuard-style client) can
  crash, wedge, or lose its session, cutting off the one network path an
  operator actually uses to reach the box.
- `sshd` itself can end up misconfigured — bound to the wrong address
  family, or timing out silently on a half-dead TCP session — turning the
  supposed lifeline into the actual point of failure.
- The network can go dark in a way neither of the above two catches at
  all: no overlay, no SSH, nothing — the only thing left is whatever the
  cloud provider exposes out-of-band (a serial console).
- Everything above can be working perfectly and the box can still be
  "lost" in the sense that matters operationally: nobody notices it's
  fine, because nothing is watching from outside.

Bundling these into one "reliability" module invites exactly the coupling
that makes each piece fragile: a watchdog that also manages sshd config
also wants to know about the serial console also wants to phone home. If a
consumer only needs one of these, a bundled module forces them to reason
about (and take on the failure modes of) the other three anyway.

## The solution: four options trees, zero shared state

`lifeline.nix` exposes `nixvps.lifeline.{watchdog,sshLifeline,console,heartbeat}`
as four independent option groups. Each has its own `enable`, and none
reads another's config:

- **`watchdog`** is the only one with real state (how long has this box
  been isolated, how many recovery attempts already ran). It runs a
  systemd timer every 5 minutes, probes connectivity (ping across the
  overlay interface, plus an optional caller-supplied management-plane
  check), and — only after tolerating a configurable grace period —
  climbs a three-tier escalation ladder: restart the overlay agent, then
  (if that doesn't recover it) restart `systemd-networkd`, then (only if
  explicitly opted into, and only after a much longer continuous-isolation
  threshold) reboot the box. State lives in two small files under
  `/var/lib/nixvps-lifeline` and clears unconditionally on the first
  successful check.
- **`sshLifeline`** ships ON by default the moment the module is imported —
  the only one of the four with that property, because for a headless box
  SSH is so often the sole way in that treating it as "yet another opt-in
  mechanism" felt wrong. It only pins down settings that keep sshd itself
  from becoming the failure (no address-family pinning, sane
  keepalive/timeout settings) and adds a boot-time check that logs — never
  fails the boot — if `:22` doesn't appear to be listening on both address
  families.
- **`console`** treats the serial console as a flight recorder, not a
  login path by default: kernel console + getty on the device, and
  journald forwarding capped to `err`-and-worse with its own rate limit, so
  a crash-looping unit can't turn a slow serial line into an unreadable
  firehose. An unauthenticated root-autologin getty is a separate,
  off-by-default opt-in, because it changes what actually gates access to
  root on this box (your cloud provider's serial-console IAM, not
  anything NixOS enforces).
- **`heartbeat`** is deliberately the simplest and dumbest of the four: a
  timer that curls an external dead-man's-switch URL and logs (never
  retries, never escalates) on failure. It exists to answer a question the
  other three cannot: "is anyone watching this box at all?" — and it
  answers it by being watched *from outside*, which is why it is hard-wired
  to never route through the overlay interface the watchdog also cares
  about.

## Why the watchdog's escalation ladder is time-based, not attempt-based

Tier 3 (reboot) is gated on *total continuous isolation time* since
isolation was first observed, not on "tier 1 and 2 both failed N times".
This means a box that has been cycling between tier-1 and tier-2 attempts
for six hours gets rebooted at the six-hour mark regardless of exactly how
many restarts it tried in between — the operator-facing promise
(`rebootAfterHours`) stays meaningful even if the tier-1/tier-2 internals
change later.

## Trade-offs

- **The watchdog's tiers are heuristics, not guarantees.** Restarting the
  overlay agent or `systemd-networkd` fixes a large class of real problems
  and does nothing for others (a provider-side network outage, a fully
  dead NIC). Tier 3 exists precisely because the first two tiers are not
  guaranteed to work.
- **An overlay outage is not automatically a host outage.** A provider or
  self-hosted control plane can fail while the workload and ordinary public
  egress remain healthy. `watchdog.hostHealthCheck` is the optional circuit
  breaker for that topology: tier 1 still gets two narrow agent restarts, but
  a successful non-overlay workload check suppresses networkd restarts and
  reboot until the overlay recovers. The check must not depend on the overlay
  or its control plane, or it merely restates the failing signal.
- **`ss -4`/`-6` is an imperfect dual-stack check.** A single dual-stack
  `[::]:22` listener commonly still serves IPv4 clients via v4-mapped
  addresses, so the `sshLifeline` boot check reporting "no IPv4 listener"
  is a diagnostic breadcrumb, not proof of a real problem — hence it only
  ever logs, never fails.
- **`heartbeat` cannot alert on its own.** By design, a failed heartbeat
  request is only journal-logged. Detecting the *absence* of a heartbeat
  is inherently the receiving monitoring service's job — this side can
  only try to send, not prove that nobody noticed it stopped.

## See also

- [`../modules/lifeline.nix`](../modules/lifeline.nix) — full implementation
- [`../examples/lifeline.nix`](../examples/lifeline.nix) — all four mechanisms wired together
- [`reboot-less-switch.md`](reboot-less-switch.md) — the sibling study for `pull-update.nix`'s reboot-less delivery model
