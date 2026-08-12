{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "nixvps-lifeline-host-health-vm";

  nodes.machine = { ... }: {
    imports = [ ../modules/lifeline.nix ];

    nixvps.lifeline = {
      sshLifeline.enable = false;
      watchdog = {
        enable = true;
        iface = "eth0";
        probeTargets = [ "192.0.2.1" ];
        agentUnit = "test-overlay-agent.service";
        graceMinutes = 0;
        allowSelfReboot = true;
        rebootAfterHours = 1;
        hostHealthCheck = "test -e /run/workload-healthy";
      };
    };

    systemd.services.test-overlay-agent = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/touch /run/test-overlay-agent-active";
      };
    };

    system.stateVersion = "25.05";
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("touch /run/workload-healthy")

    # First observation arms the episode. The next two runs exercise the
    # narrow agent restart; the fourth reaches the broad-escalation branch.
    for _ in range(4):
        machine.succeed("systemctl restart lifeline-watchdog.service")

    machine.succeed("grep -Fx 2 /var/lib/nixvps-lifeline/watchdog-tier1-count")
    machine.succeed("journalctl -u lifeline-watchdog.service --no-pager | grep -F 'hostHealthCheck passes -- suppressing systemd-networkd restart and reboot'")
    machine.fail("journalctl -u lifeline-watchdog.service --no-pager | grep -F 'TIER 2:'")
    machine.fail("test -e /var/lib/nixvps-lifeline/watchdog-tier3-last")
    machine.succeed("systemctl is-active --quiet test-overlay-agent.service")

    # The circuit breaker must fail open to the original recovery ladder:
    # once the independent host check fails, the next tick reaches tier 2.
    machine.succeed("rm /run/workload-healthy")
    machine.succeed("systemctl restart lifeline-watchdog.service")
    machine.succeed("journalctl -u lifeline-watchdog.service --no-pager | grep -F 'TIER 2:'")
  '';
}
