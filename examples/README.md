# examples

Minimal, working, option-accurate example configurations showing how to use
the three nixvps modules in a real NixOS flake.

## Minimal example with all three modules

**`configuration.nix`** — a complete flake demonstrating:

- `nixvps.tinyVm` enabled with defaults (btrfs tuning, clamped journald,
  nix build parallelism capped to 1/1, weekly GC at 30d)
- `nixvps.pullUpdate` enabled and wired to pull from a signed binary cache
  on a daily timer, with health checks on `sshd` and a placeholder workload
  unit
- `nixvps.deployTarget` enabled to trust the same cache and accept SSH
  deploys from a placeholder key

All values are generic (cache.example.com, example.com, placeholder keys);
swap in your own domain, cache URL, signing keys, and workload units before
deploying.

To check parsing: `nix-instantiate --parse configuration.nix`.

## lifeline: all four mechanisms

**`lifeline.nix`** — a complete flake demonstrating `nixvps.lifeline.watchdog`,
`.sshLifeline`, `.console`, and `.heartbeat` enabled together on one host,
with generic values (overlay interface, probe IPs, agent unit, serial
device, monitoring URL) throughout.

To check parsing: `nix-instantiate --parse lifeline.nix`.

## Per-module quickstart

See the main [README](../README.md) for copy-pasteable per-module snippets
under "Usage".
