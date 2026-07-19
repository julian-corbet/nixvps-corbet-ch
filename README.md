# nixvps

NixOS profiles for tiny (1 GB-RAM class) cloud VMs.

## The pitch

A lot of people run NixOS on free-tier or otherwise tiny cloud instances —
the 1 GB-RAM, single-vCPU class offered by most cloud providers' free
tiers. That size class hits the same walls over and over: the Nix daemon
itself can OOM the box during a rebuild, a naive systemd unit set eats the
RAM budget before the actual workload starts, and "just SSH in and run
`nixos-rebuild switch`" stops being a safe operation once a bad generation
can leave the box unreachable with no console access — and a push-based
deploy pipeline can't always even reach a box like this in the first
place.

`nixvps` collects the hard-won answers to those problems as reusable NixOS
modules, instead of every small-VPS NixOS user rediscovering them alone.

## The three real modules

- **`tiny-vm.nix`** — a conservative baseline profile for small,
  RAM-constrained cloud VMs (the ~1 vCPU / ~1 GB RAM / small-disk class):
  btrfs mount tuning, a bounded journald, a clamped `nix-daemon` (build
  parallelism, cores), automatic GC, and a capped boot-loader generation
  count. Every setting uses `lib.mkDefault`, so nothing here fights an
  override.
- **`pull-update.nix`** — autonomous, reboot-less, pull-based self-update
  for a node a central deploy pipeline can't always reach. On a timer, the
  node reads a signed pointer to the next `system.build.toplevel`,
  substitutes it (signature-verified, never built on-box), switches to it
  live, runs a local health check, and rolls back to the last-known-good
  generation on failure — no reboot involved anywhere in the cycle.
- **`deploy-target.nix`** *(just added)* — the passive-receiver
  counterpart to `pull-update`. Configures a node to trust a signed binary
  cache (`substituters` + `trusted-public-keys`, with `require-sigs`
  enforced) and to accept an inbound deploy by trusting one or more deploy
  keys in root's `authorized_keys`. No timers, no polling, no health
  checks of its own — it only establishes trust. Use it standalone for a
  push-deployed node, or alongside `pull-update` on a node that does both.

### Explicitly out of scope

Deep `zram`/`zswap`/OOM-killer tuning is **not** part of this project —
that level of memory-pressure engineering belongs to the sibling
[nixram](https://github.com/julian-corbet/nixram-corbet-ch) project.
`nixvps` assumes nixram (or an equivalent) handles the memory-pressure
layer; it focuses on the system-shape and delivery problems above that
layer.

## Status

**Pre-alpha.** Three real modules have landed:

- `nixosModules.tiny-vm` (`modules/tiny-vm.nix`)
- `nixosModules.pull-update` (`modules/pull-update.nix`)
- `nixosModules.deploy-target` (`modules/deploy-target.nix`)

All three are being extracted from a private fleet configuration where
they were developed and used for real, generalized so they carry no
site-specific defaults — but they are still new, lightly documented, and
not yet used outside that original extraction. Everything else in this
repo remains a placeholder; if you found this searching for a drop-in
NixOS distribution, most of it is not ready for that yet.

## Usage

A tiny VM usually has limited RAM (1 GB) and constrained build capacity
(1 vCPU). The three modules work independently or together.

### tiny-vm: Conservative baseline

A RAM-constrained box needs careful defaults: the btrfs root tuned for
small disks, journald capped to avoid filling a tiny partition, and the
nix daemon set to build serially (1 job, 1 core per job) so the builder
doesn't OOM the workload. Every setting uses `lib.mkDefault`, so you can
override anything without fighting the module.

```nix
{
  inputs.nixvps.url = "github:<you>/nixvps";

  outputs = { self, nixpkgs, nixvps }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        nixvps.nixosModules.tiny-vm
        {
          nixvps.tinyVm.enable = true;

          # All of these are optional; shown here are the defaults:
          # nixvps.tinyVm.rootMountOptions = [ "compress=zstd" "noatime" "space_cache=v2" ];
          # nixvps.tinyVm.journalMaxUse = "200M";      # persistent journal size cap
          # nixvps.tinyVm.journalRuntimeMaxUse = "50M"; # in-memory journal size cap
          # nixvps.tinyVm.nixMaxJobs = 1;               # parallel derivations to build
          # nixvps.tinyVm.nixCores = 1;                 # cores per derivation
          # nixvps.tinyVm.gcOlderThan = "30d";          # automatic gc age threshold
        }
      ];
    };
  };
}
```

### pull-update: Autonomous reboot-less self-update

A node a central deploy pipeline cannot reach (no stable inbound route, or
behind a NAT/firewall) can instead pull updates on a timer. The node
retrieves a DNS TXT pointer to the target system closure, substitutes it
(signature-verified) from your binary cache, switches to it *live* (no
reboot), then verifies the workload with a local health check. If the health
check fails, the node rolls back automatically — a stand-in for a push
controller's remote rollback, which only works when the controller can still
reach the node.

Enable alongside `deploy-target` for a node that both pulls *and* accepts
pushes from a controller when it is reachable.

```nix
{
  inputs.nixvps.url = "github:<you>/nixvps";

  outputs = { self, nixpkgs, nixvps }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        nixvps.nixosModules.pull-update
        {
          nixvps.pullUpdate = {
            enable = true;

            # REQUIRED: the signed binary cache to pull closures from.
            cache = "https://cache.example.com";

            # REQUIRED unless you set `pointerName` directly: the DNS zone
            # under which _deploy.<hostname>.<domain> TXT record is published
            # by your build pipeline after each build.
            domain = "example.com";

            # Optional: HTTP endpoint to check after a switch. If it does not
            # return 2xx, the switch is rolled back. (default: null / units-only)
            healthUrl = "https://example.com/health";

            # Systemd units that must all be active after a switch.
            # Replace with the units your workload depends on.
            # (default: ["sshd"] — only ensures the VM is reachable)
            healthUnits = [ "sshd" "my-app" ];

            # Delay before the first pull after boot.
            # (default: "10min")
            onBootSec = "10min";

            # Interval between pulls (OnUnitActiveSec).
            # (default: "1d" — once a day; a missed tick doesn't cause a pile-up)
            interval = "1d";
          };
        }
      ];
    };
  };
}
```

### deploy-target: Trust a signed cache, accept signed deploys

A node running a deploy-target is configured to:
1. Trust a signed binary cache (`substituters` + `trusted-public-keys`) with
   `require-sigs` enforced — so unsigned or wrongly-signed closures are never
   accepted.
2. Accept inbound SSH deploys: one or more SSH public keys are added to
   root's `authorized_keys`, allowing a controller or operator to log in and
   run `nixos-rebuild switch` or another deploy tool.

This module performs *no* deploy logic itself — no timers, no polling, no
health checks. Use it standalone for a push-deployed node, or alongside
`pull-update` for a node that also self-updates; the two modules do not
conflict.

```nix
{
  inputs.nixvps.url = "github:<you>/nixvps";

  outputs = { self, nixpkgs, nixvps }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        nixvps.nixosModules.deploy-target
        {
          nixvps.deployTarget = {
            enable = true;

            # Signed binary cache URL(s) to substitute from.
            # Added to nix.settings.substituters (does not replace nixpkgs' defaults).
            # (default: [] / empty)
            caches = [ "https://cache.example.com" ];

            # Public signing key(s) of the cache(s) above.
            # Required for anything from `caches` to actually be substituted,
            # since `require-sigs` is on by default.
            # Format: "cache-hostname-N:base64-encoded-public-key="
            # (default: [] / empty)
            trustedPublicKeys = [ "cache.example.com-1:base64-encoded-key=" ];

            # SSH public keys for the deploy identity (added to root's
            # authorized_keys additively — existing keys are preserved).
            # (default: [] / empty)
            deployAuthorizedKeys = [ "ssh-ed25519 AAAA... deploy@example" ];

            # Whether the nix daemon requires a valid signature before accepting
            # any substituted path. Leave on unless you specifically trust unsigned
            # closures.
            # (default: true)
            requireSigs = true;
          };
        }
      ];
    };
  };
}
```

## Full example

See [`examples/configuration.nix`](examples/configuration.nix) for a minimal
flake that enables all three modules together on a single host.

## Roadmap

Planned, not yet built:

- [x] RAM-class base profile (conservative daemon defaults, clamped
      `nix.settings` for `nix-daemon`) — `modules/tiny-vm.nix`
- [x] Pull-based self-update module (signed closure pointer, fetch,
      switch, local health-check rollback) — `modules/pull-update.nix`
- [x] Deploy-target module (trust a signed binary cache, accept a signed
      deploy) — `modules/deploy-target.nix`
- [ ] Disk-image baking module (`systemd-repart` / `disko` patterns for
      boot-from-image instead of install-on-first-boot)
- [ ] An example minimal configuration wiring all of the above together
- [ ] Documentation site content and a real quickstart

## Part of the corbet.ch project family

`nixvps` is one of several small, independent NixOS/infra projects
published under the same author, alongside things like a NixOS-based
distro project (`nixnas`) and a RAM/memory-tuning flake (`nixram`).
Each is scoped narrowly and can be used independently; this one owns the
tiny-cloud-VM system shape and delivery problem specifically.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
