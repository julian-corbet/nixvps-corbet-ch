# Minimal example: all four nixvps.lifeline mechanisms enabled on one host.
#
# This is a complete flake.nix showing nixvps.lifeline.watchdog,
# .sshLifeline, .console, and .heartbeat wired together. All values are
# generic — swap in your own overlay interface/unit, probe IPs, serial
# device, and monitoring URL where indicated.

{
  description = "Example: nixvps lifeline module, all four mechanisms";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixvps.url = "github:julian-corbet/nixvps";
  };

  outputs = { self, nixpkgs, nixvps }: {
    nixosConfigurations.example-vm = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixvps.nixosModules.lifeline

        {
          networking.hostName = "example-vm";

          # ─── watchdog: detect overlay/agent isolation, escalate to recover ─
          nixvps.lifeline.watchdog = {
            enable = true;

            # REQUIRED: the overlay/mesh interface to probe through.
            iface = "wt0";

            # At least one of probeTargets / managementCheck is REQUIRED
            # (enforced by an assertion) — otherwise the watchdog has no
            # signal and would escalate on every tick.
            probeTargets = [ "100.64.0.1" "100.64.0.2" ];

            # Optional: exits 0 when your overlay agent's own control plane
            # considers this node reachable. Replace with your overlay's
            # real status check.
            managementCheck = "curl -fsS http://127.0.0.1:8080/status | grep -q connected";

            # Optional: prove the host's public/non-overlay workload is still
            # healthy. After two agent restarts, success suppresses the broad
            # networkd/reboot tiers so an external overlay-control-plane outage
            # cannot turn into an outage of this host too.
            hostHealthCheck = "curl -fsS --max-time 10 https://service.example.com/health";
            checkTimeoutSeconds = 10; # default; bounds both custom checks

            # REQUIRED: the overlay/mesh agent's systemd unit, restarted at
            # tier 1. e.g. netbird.service, tailscaled.service,
            # wg-quick@wt0.service — whatever your overlay tool actually is.
            agentUnit = "netbird.service";

            # Tolerate 15 minutes of continuous isolation before tier 1
            # (restart agentUnit) fires at all. (default: 15)
            graceMinutes = 15;

            # Tier 3 (systemctl reboot) is off unless you opt in — it is the
            # most drastic, least reversible tier. (default: false)
            allowSelfReboot = false;

            # If allowSelfReboot were true, tier 3 would fire after this many
            # hours of CONTINUOUS isolation. (default: 6)
            rebootAfterHours = 6;
          };

          # ─── sshLifeline: keep sshd itself from being the failure ─────────
          # ON by default just from importing the module — shown explicitly
          # here for clarity. Turn off with `enable = false;` if you manage
          # sshd entirely yourself.
          nixvps.lifeline.sshLifeline = {
            enable = true;
            clientAliveInterval = 60; # default
            clientAliveCountMax = 5; # default
          };

          # ─── console: serial flight recorder ───────────────────────────────
          nixvps.lifeline.console = {
            enable = true;

            # Match whatever your provider's serial console actually exposes.
            device = "ttyS0"; # default
            baud = 115200; # default

            # Only forward "err" and worse to the serial console. (default)
            maxLevelConsole = "err";

            # UNAUTHENTICATED root getty on the serial device — read the
            # option's description before enabling; it trades authentication
            # for guaranteed recoverability and is only as safe as your
            # provider's serial-console IAM. Left off here.
            serialAutologin = false;
          };

          # ─── heartbeat: external dead-man's-switch ping ────────────────────
          nixvps.lifeline.heartbeat = {
            enable = true;

            # REQUIRED: your monitoring provider's push/dead-man's-switch URL.
            url = "https://hc-ping.com/00000000-0000-0000-0000-000000000000";

            intervalMinutes = 5; # default
            timeoutSeconds = 10; # default

            # Never defaults to watchdog.iface — see the option description
            # for why. Only set this if the box has more than one public
            # egress interface.
            # bindInterface = "eth0";
          };

          # Minimal system setup (replace with your actual config).
          # sshd itself is already handled above by nixvps.lifeline.sshLifeline.
          system.stateVersion = "24.11";
        }
      ];
    };
  };
}
