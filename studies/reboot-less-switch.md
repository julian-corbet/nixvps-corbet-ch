# Reboot-less switching for tiny VMs

## The problem

A tiny cloud VM (1 GB RAM, 1 vCPU) cannot build locally. Running `nixos-rebuild switch` forks derivation builders as separate processes that all compete for the same small RAM pool; builds frequently OOM and leave the box unreachable. Even with a pre-built binary cache, a naive deployment reboots on kernel changes—risky without console access. A push-based deploy controller requires stable inbound network access, which is unreliable for VMs behind NAT or in high-latency regions.

## The solution: pull-based, live-switch, local health checks

The `pull-update` module works differently:

1. **Pre-build centrally** and publish a DNS TXT pointer (`_deploy.<hostname>.<domain>`) to the signed store path.

2. **Pull on a timer** (outbound DNS only; no inbound access needed): A systemd timer runs `pull-update` daily. The script:
   - Reads the DNS pointer and validates it matches `nixos-system-<hostname>-*`.
   - Fetches the closure via `nix copy --from <cache>` with `require-sigs` enforced (signature-verified, never built on-box).
   - Applies `switch-to-configuration switch` **live**—all userspace changes apply immediately. New kernels are installed but *queued* as boot entries; no reboot occurs.
   - Runs local health checks (configured systemd units + optional HTTP endpoint). If checks pass, the switch is kept.
   - On failure, **automatically rolls back** to the previous good generation via another live switch.

3. **Convergence without reboot**: If a tick is missed (network flaky, cache unreachable), the next tick retries. The timer is persistent across reboots.

## Why this works

- **No on-box build**: Every closure is pre-built and signature-verified. The nix daemon never forks builders; RAM is freed immediately after substitution.

- **No reboot**: Live switching lets configuration changes take effect instantly. Kernel upgrades queue silently; the operator reboots when ready—or not at all if not needed immediately.

- **Local rollback, no remote control**: Health checks run on the box. If a switch fails, it reverts within seconds—no SSH session needed, no remote orchestrator required. This works even if the box is unreachable from outside.

## Trade-offs

- **Eventual consistency**: Changes adopt on the *next* timer tick, not immediately. Reduce the interval (default 1d) for faster convergence if needed.

- **Shallow health checks**: Unit activity is a weak canary; add real health endpoints to your workload for better coverage.

- **Kernel changes need eventual reboots**: Queueing isn't permanent. Systems requiring immediate kernel updates need to script a post-switch health-check-then-reboot.

## See also

- [`pull-update.nix`](../modules/pull-update.nix) — full implementation
- [`deploy-target.nix`](../modules/deploy-target.nix) — the push-side counterpart (optional; can run alongside pull-update)
- [`examples/configuration.nix`](../examples/configuration.nix) — minimal working example wiring all modules
