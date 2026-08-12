{ pkgs, nixpkgs, system }:

let
  config = (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      ../modules/pull-update.nix
      {
        networking.hostName = "test-vps";
        nixvps.pullUpdate = {
          enable = true;
          cache = "https://cache.example.invalid";
          domain = "example.invalid";
        };
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        system.stateVersion = "25.05";
      }
    ];
  }).config;
in
assert config.nixvps.pullUpdate.allowKnownGenerationRollback == false;
assert config.systemd.services.pull-update.restartIfChanged == false;
assert config.systemd.services.pull-update.stopIfChanged == false;
pkgs.runCommand "pull-update-module-eval-check" { } ''
  test -x ${config.systemd.services.pull-update.serviceConfig.ExecStart}
  touch "$out"
''
