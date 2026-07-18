# nixvps

NixOS profiles for tiny (1 GB-RAM class) cloud VMs.

## The pitch

A lot of people run NixOS on free-tier or otherwise tiny cloud instances —
the 1 GB-RAM, single-vCPU class offered by most cloud providers' free
tiers. That size class hits the same walls over and over: the Nix daemon
itself can OOM the box during a rebuild, a naive systemd unit set eats the
RAM budget before the actual workload starts, and "just SSH in and run
`nixos-rebuild switch`" stops being a safe operation once a bad generation
can leave the box unreachable with no console access.

`nixvps` collects the hard-won answers to those problems as reusable NixOS
profiles, instead of every small-VPS NixOS user rediscovering them alone.

## Scope

- **RAM-class system defaults** — conservative service defaults and a
  clamped `nix-daemon` (build parallelism, cores, memory ceilings) tuned
  for boxes in the ~1 GB class, so a routine rebuild doesn't compete the
  box's own workload out of memory.
- **Disk-image baking patterns** — building a prebuilt disk image (via
  `systemd-repart` / `disko`-style partitioning) so a VM *boots* from a
  ready image instead of running a full NixOS install step on first boot.
- **Pull-based self-update** — a pattern for boxes a central deploy
  pipeline can't always reach (intermittent connectivity, no inbound
  access, ephemeral IP): the node itself fetches a signed pointer to the
  next closure, switches to it, and rolls back to the last-known-good
  generation on a failed local health check.

### Explicitly out of scope

Deep `zram`/`zswap`/OOM-killer tuning is **not** part of this project —
that level of memory-pressure engineering belongs to the sibling
[nixram](https://github.com/julian-corbet/nixram-corbet-ch) project.
`nixvps` assumes nixram (or an equivalent) handles the memory-pressure
layer; it focuses on the system-shape and delivery problems above that
layer.

## Status

**Pre-alpha.** Two real modules have landed: `nixosModules.pull-update`
(`modules/pull-update.nix`), a reboot-less pull-based self-update mechanism
with signature-checked substitution and local health-check rollback; and
`nixosModules.tiny-vm` (`modules/tiny-vm.nix`), a conservative baseline
profile (btrfs mount tuning, bounded journald, a clamped nix-daemon) for
small/slow/low-RAM cloud VMs. Both are being extracted from a private fleet
configuration where they were developed and used for real, generalized so
they carry no site-specific defaults — but they are still new, lightly
documented, and not yet used outside that original extraction. Everything
else in this repo remains a placeholder; if you found this searching for a
drop-in NixOS distribution, most of it is not ready for that yet.

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

## Roadmap

Planned, not yet built:

- [x] RAM-class base profile (conservative daemon defaults, clamped
      `nix.settings` for `nix-daemon`) — `modules/tiny-vm.nix`
- [ ] Disk-image baking module (`systemd-repart` / `disko` patterns for
      boot-from-image instead of install-on-first-boot)
- [x] Pull-based self-update module (signed closure pointer, fetch,
      switch, local health-check rollback) — `modules/pull-update.nix`
- [ ] An example minimal configuration wiring the above together
- [ ] Documentation site content and a real quickstart

## Part of the corbet.ch project family

`nixvps` is one of several small, independent NixOS/infra projects
published under the same author, alongside things like a NixOS-based
distro project (`nixnas`) and a RAM/memory-tuning flake (`nixram`).
Each is scoped narrowly and can be used independently; this one owns the
tiny-cloud-VM system shape and delivery problem specifically.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
