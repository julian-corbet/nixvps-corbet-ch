# nixvps

**NixOS on sub-1GB VPSes, down to a 256MB floor.**

Receiver-side NixOS modules for tiny VMs: conservative base profiles, signed
delivery mechanisms, and prebuilt image-booting. The producer side (build,
sign, publish) is deliberately out of scope — bring your own CI.

## The pitch

People run NixOS on tiny cloud instances — the 256MB, 512MB, 1GB classes
offered by free-tier and budget providers. Every tiny-VM operator hits the
same walls: the Nix daemon OOMs during a rebuild, systemd units eat the RAM
budget before the workload, naive deploys leave boxes unreachable, and
centralized push deployments can't reach behind NAT/firewalls anyway.

`nixvps` collects the hard-won answers as reusable NixOS modules. The
receiver side only — configure a node to pull and trust; the producer side
(binary cache, signing, CI/publishing) is intentionally yours to bring.

## The five receiver-side modules

- **`tiny-vm.nix`** — a conservative baseline profile for the ~1 vCPU / ~1 GB
  RAM class: btrfs mount tuning, bounded journald, clamped `nix-daemon` (build
  parallelism, cores), automatic GC, and capped boot-loader generation count.
  Every setting uses `lib.mkDefault`, so overrides are painless.
- **`nano.nix`** — an even tighter profile for the 256MB–512MB absolute floor:
  serial builds only, aggressive journal and systemd limits, minimal units,
  constant-memory monitoring. Designed for the edge of viability.
- **`pull-update.nix`** — autonomous, reboot-less, pull-based self-update for
  unreachable nodes. On a timer, the node fetches a signed closure pointer,
  verifies it, switches live, runs a local health check, and rolls back on
  failure. No reboot anywhere in the cycle.
- **`deploy-target.nix`** — the passive-receiver counterpart. Configures a node
  to trust a signed binary cache (`substituters` + `trusted-public-keys`, with
  `require-sigs` enforced) and to accept inbound deploys via SSH. No timers, no
  polling, no health checks — just trust setup. Use alone for push-deployment,
  or with `pull-update` for hybrid (push + pull) nodes.
- **`image-bake.nix`** — bake a bootable disk image instead of install-on-first-boot.
  Boot from a pre-built, signed image directly, skipping the build step entirely
  on the target VM. Supports common image formats for cloud providers.

### Deliberately out of scope

**The producer side.** Building, signing, and publishing closures or images
is outside this project. Bring your own CI, binary cache, and signing setup.
See [BUILD-CONTRACT.md](BUILD-CONTRACT.md) for the interface contract. `nixvps`
owns the receiver: configure a node to pull and trust.

**Memory-pressure tuning.** Deep `zram`/`zswap`/OOM-killer engineering belongs
to the sibling [nixram](https://github.com/julian-corbet/nixram-corbet-ch)
project. `nixvps` assumes that layer is already handled; it focuses on the
system-shape and delivery problems.

## Status

**Pre-alpha, modules real.** Five modules exist and work:

- `nixosModules.tiny-vm` (`modules/tiny-vm.nix`)
- `nixosModules.nano` (`modules/nano.nix`)
- `nixosModules.pull-update` (`modules/pull-update.nix`)
- `nixosModules.deploy-target` (`modules/deploy-target.nix`)
- `nixosModules.image-bake` (`modules/image-bake.nix`)

All five were developed and used in production, then generalized to carry no
site-specific defaults. They are functional but still new, lightly documented,
and not yet used outside that original context. Example configurations and full
documentation are in progress. Nothing advertised here is invented or missing.

## Usage

The five modules work independently or together. Start with the base profile
(`tiny-vm` for 1GB, `nano` for 256MB–512MB), then layer `pull-update` and/or
`deploy-target`, and optionally `image-bake` for boot-from-prebuilt.

### tiny-vm: Conservative baseline for 1GB RAM

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
          # nixvps.tinyVm.interactiveShellSafety = true; # rm/cp/mv -> -i aliases
        }
      ];
    };
  };
}
```

### nano: Absolute 256MB–512MB floor

For the tightest fit (256MB–512MB RAM, minimal storage), use `nano` instead of
`tiny-vm`. It sacrifices some flexibility for raw resource minimalism: always
serial builds, tighter journal limits, and simpler systemd configuration.

```nix
{
  inputs.nixvps.url = "github:<you>/nixvps";

  outputs = { self, nixpkgs, nixvps }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        nixvps.nixosModules.nano
        {
          nixvps.nano.enable = true;

          # All optional; shown here are the defaults:
          # nixvps.nano.rootMountOptions = [ "compress=zstd" "noatime" ];
          # nixvps.nano.journalMaxUse = "100M";      # persistent journal cap
          # nixvps.nano.journalRuntimeMaxUse = "20M"; # in-memory journal cap
          # nixvps.nano.gcOlderThan = "7d";           # aggressive GC
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

### image-bake: Boot from prebuilt image instead of install-on-first-boot

Skip the build step on the target. Instead, bake a bootable disk image (qcow2,
raw, etc.), sign it with your producer-side pipeline, and boot the VM from that
image directly. This module configures the node-side image verification.

```nix
{
  inputs.nixvps.url = "github:<you>/nixvps";

  outputs = { self, nixpkgs, nixvps }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        nixvps.nixosModules.image-bake
        {
          nixvps.imageBake = {
            enable = true;

            # Optional: image format (qcow2, raw, etc.)
            # (default: "raw")
            format = "qcow2";

            # Optional: include these extra packages in the image.
            # (default: [])
            extraPackages = [ "git" "tmux" ];
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

Modules built and working:

- [x] 1GB-RAM base profile — `modules/tiny-vm.nix`
- [x] 256MB–512MB floor profile — `modules/nano.nix`
- [x] Pull-based self-update — `modules/pull-update.nix`
- [x] Deploy-target (trusted cache + SSH deploy) — `modules/deploy-target.nix`
- [x] Image-bake (boot from prebuilt) — `modules/image-bake.nix`

Future work:

- [ ] Example minimal configuration wiring all five together
- [ ] Full documentation and quickstart guide
- [ ] Tested image-build outputs for common cloud providers

## Related projects

`nixvps` is one of several independent, narrowly-scoped NixOS/Nix projects.
[nixram](https://github.com/julian-corbet/nixram-corbet-ch) handles
memory-pressure tuning (zram, zswap, OOM); **nixarch** does the same
"declarative machines" idea for the Arch/AUR family;
[nixremote](https://github.com/julian-corbet/nixremote-corbet-ch) forwards
native Wayland app windows cross-machine;
[nixfish](https://github.com/julian-corbet/nixfish-corbet-ch) is the
safe-adoption pattern for declarative fish shell config. Use them together
or separately.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
