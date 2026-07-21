# Minimal example: all three nixvps modules enabled and wired together.
#
# This is a complete flake.nix that pulls nixvps and shows how to enable
# tiny-vm, pull-update, and deploy-target on a single host. All settings
# are generic, no site-specific values — swap in your own domain, cache URL,
# and deploy keys where indicated.

{
  description = "Example: nixvps all three modules in one config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixvps.url = "github:julian-corbet/nixvps";
  };

  outputs = { self, nixpkgs, nixvps }: {
    nixosConfigurations.example-vm = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        # Enable all three nixvps modules
        nixvps.nixosModules.tiny-vm
        nixvps.nixosModules.pull-update
        nixvps.nixosModules.deploy-target

        # Configuration for this host
        {
          networking.hostName = "example-vm";

          # ─── tiny-vm: conservative baseline for small cloud VMs ───────────
          nixvps.tinyVm.enable = true;
          # Defaults: compress=zstd, noatime, space_cache=v2 on btrfs root;
          # journald capped at 200M persistent / 50M in-memory; nix max-jobs=1
          # cores=1; auto-gc weekly older than 30d; bootloader limited to 10 generations;
          # rm/cp/mv aliased to their -i (confirm-before-clobber) forms.
          # Override any:
          # nixvps.tinyVm.journalMaxUse = "100M";
          # nixvps.tinyVm.nixCores = 2;
          # nixvps.tinyVm.gcOlderThan = "7d";

          # ─── pull-update: autonomous reboot-less self-update ──────────────
          nixvps.pullUpdate.enable = true;
          nixvps.pullUpdate = {
            # REQUIRED: your binary cache serving signed closures
            cache = "https://cache.example.com";

            # REQUIRED (unless you set pointerName directly): DNS zone under
            # which _deploy.<hostname>.<domain> TXT record is published
            domain = "example.com";

            # Optional: check this endpoint for workload health after switch
            # (default: null, units-only health)
            healthUrl = "https://example.com/health";

            # Health check: these systemd units must all be active after switch.
            # Replace with units your workload actually depends on.
            # (default: ["sshd"] — only guarantees the VM is reachable)
            healthUnits = [ "sshd" "my-app-service" ];

            # Delay before first pull after boot (default: "10min")
            onBootSec = "10min";

            # Interval between pulls (default: "1d")
            # Once a day keeps latency between change and adoption reasonable,
            # but a missed tick doesn't cause a pile-up.
            interval = "1d";
          };

          # ─── deploy-target: trust a signed cache, accept signed deploys ────
          nixvps.deployTarget.enable = true;
          nixvps.deployTarget = {
            # Add to nix.settings.substituters. Empty by default (no-op).
            # Usually the same cache as pull-update uses.
            caches = [ "https://cache.example.com" ];

            # Public keys of the cache(s) above. Required if you want
            # substitution to actually work; require-sigs is on by default.
            # Format: "cache-hostname-N:base64-encoded-key="
            # This is a PLACEHOLDER — replace with your actual key.
            trustedPublicKeys = [
              "cache.example.com-1:YourActualBase64EncodedPublicKeyHere="
            ];

            # SSH public keys that may log in as root and run
            # `nixos-rebuild switch` or other deploy tools.
            # This is a PLACEHOLDER ed25519 key — replace with your actual key.
            deployAuthorizedKeys = [
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholder0000000000000000000000 deploy@example"
            ];

            # Whether the nix daemon requires a signature on substituted paths.
            # true by default; only disable if you're testing unsigned caches.
            requireSigs = true;
          };

          # Minimal system setup (replace with your actual config)
          users.users.root.initialPassword = "changeme";
          services.openssh.enable = true;
          system.stateVersion = "24.11";
        }
      ];
    };
  };
}
