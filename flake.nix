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
      # fleet configuration. The pull-based self-update module is the first
      # real module to land; the remaining roadmap items in README.md are
      # still being extracted and generalized.
      nixosModules = {
        pull-update = ./modules/pull-update.nix;
      };

      lib = { };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
