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
      # fleet configuration. No NixOS modules or profiles have landed yet.
      # `nixosModules` / `lib` will gain real content as the roadmap items
      # in README.md are extracted and generalized. Kept as a real (empty)
      # attribute set rather than omitted, so downstream flakes can already
      # depend on this output shape without breaking later.
      nixosModules = { };

      lib = { };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
