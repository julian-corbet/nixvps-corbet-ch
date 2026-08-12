{ pkgs, nixpkgs, system }:
let
  healthCommand = "test -e /run/workload-healthy";
  evaluated = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      ../modules/lifeline.nix
      {
        system.stateVersion = "25.05";
        nixvps.lifeline = {
          sshLifeline.enable = false;
          watchdog = {
            enable = true;
            iface = "wt0";
            probeTargets = [ "100.64.0.1" ];
            agentUnit = "netbird.service";
            hostHealthCheck = healthCommand;
          };
        };
      }
    ];
  };
  watchdog = evaluated.config.systemd.services.lifeline-watchdog.serviceConfig.ExecStart;
in
assert evaluated.config.nixvps.lifeline.watchdog.hostHealthCheck == healthCommand;
pkgs.runCommand "nixvps-lifeline-host-health-check"
{
  nativeBuildInputs = [ pkgs.gnugrep ];
}
  ''
    grep -F 'HOST_HEALTH_CHECK=' ${watchdog}
    grep -F ${pkgs.lib.escapeShellArg healthCommand} ${watchdog}
    grep -F 'suppressing systemd-networkd restart and reboot' ${watchdog}
    grep -F 'broad_escalation_allowed' ${watchdog}
    grep -F 'timeout --kill-after=1 "$CHECK_TIMEOUT_SEC"' ${watchdog}
    touch "$out"
  ''
