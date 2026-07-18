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

### Using `tiny-vm`

```nix
{
  inputs.nixvps.url = "github:<you>/nixvps";

  outputs = { self, nixpkgs, nixvps }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        nixvps.nixosModules.tiny-vm
        {
          nixvps.tinyVm.enable = true;
          # every default below can be overridden; see modules/tiny-vm.nix
          # nixvps.tinyVm.nixMaxJobs = 2;
        }
      ];
    };
  };
}
```

### Using `pull-update`

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
            cache = "https://cache.example.com";     # your signed binary cache
            domain = "example.com";                    # zone for the _deploy.<host> TXT pointer
            healthUnits = [ "sshd" "my-app" ];          # units that must stay active
            # healthUrl = "https://example.com/health"; # optional HTTP health check
          };
        }
      ];
    };
  };
}
```

### Using `deploy-target`

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
            caches = [ "https://cache.example.com" ];
            trustedPublicKeys = [ "cache.example.com-1:base64-encoded-key=" ];
            deployAuthorizedKeys = [ "ssh-ed25519 AAAA... deploy@example" ];
          };
        }
      ];
    };
  };
}
```

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
