{
  description = "nixvps - NixOS profiles for tiny (1 GB-class) cloud VMs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
    in
    {
      # Extraction in progress: this repo is being pulled out of a private
      # fleet configuration. The pull-based self-update module was the
      # first real module to land; the tiny-vm baseline profile is the
      # second. The remaining roadmap items in README.md are still being
      # extracted and generalized.
      nixosModules = {
        pull-update = ./modules/pull-update.nix;
        tiny-vm = ./modules/tiny-vm.nix;
        deploy-target = ./modules/deploy-target.nix;
        nano = ./modules/nano.nix;
        # Generic systemd-repart cloud image bake (ESP + systemd-boot + btrfs
        # root, parameterized). See modules/image-bake.nix for the honest
        # scope note: this is a starting point, not a turnkey per-provider
        # image. Enable via `nixvps.imageBake.enable = true;`, then build the
        # image itself with:
        #   nix build .#nixosConfigurations.<name>.config.system.build.image
        image-bake = ./modules/image-bake.nix;
        # Four independently toggleable "never lose a headless tiny VM"
        # mechanisms (connectivity watchdog, sshd lifeline, serial console
        # flight recorder, external heartbeat). See modules/lifeline.nix.
        # Enable via `nixvps.lifeline.<mechanism>.enable = true;`.
        lifeline = ./modules/lifeline.nix;
      };

      lib = { };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
