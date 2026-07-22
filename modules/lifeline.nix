# lifeline.nix — "never lose a headless tiny VM": four independently
# toggleable mechanisms, each answering a different way a small cloud VM
# goes dark and stays dark. None of them depend on each other and none are
# required by any other — enable exactly the subset that matches your setup.
#
#   nixvps.lifeline.watchdog    — detect overlay/agent isolation and climb
#                                 a restart-then-reboot escalation ladder.
#   nixvps.lifeline.sshLifeline — keep sshd itself from becoming the reason
#                                 the box is unreachable. ON by default.
#   nixvps.lifeline.console     — a serial "flight recorder": error-and-worse
#                                 journal output forwarded to a serial
#                                 console, so there is somewhere to look even
#                                 when the network is what's broken.
#   nixvps.lifeline.heartbeat   — a dead-man's-switch ping to an external
#                                 monitoring URL over the box's normal public
#                                 egress (never the overlay), so something
#                                 OUTSIDE the box notices when all of the
#                                 above still wasn't enough.
#
# These cover different failure modes — an overlay/agent crash, an sshd
# misconfiguration, a fully dark network with no path out at all, and "the
# box is fine but nobody knows to look" — and none of them substitutes for
# the others. Pick the subset that matches your provider's capabilities
# (serial console access, safe unattended reboot, an external monitoring
# endpoint) and your own risk tolerance.
#
# Every setting uses `lib.mkDefault` so a consuming configuration can
# override any single value without a fight, except the two ExecStart
# overrides that must genuinely win (`lib.mkForce`, each with the tradeoff
# documented at the option that turns it on).

{ config, lib, pkgs, ... }:

let
  wd = config.nixvps.lifeline.watchdog;
  ssh = config.nixvps.lifeline.sshLifeline;
  console = config.nixvps.lifeline.console;
  hb = config.nixvps.lifeline.heartbeat;

  watchdogRuntimeBin = lib.makeBinPath [
    pkgs.iputils # ping
    pkgs.coreutils # date, cat, mkdir, rm
    pkgs.systemd # systemctl
    pkgs.util-linux # flock, logger
    pkgs.gnugrep # grep
  ];

  # The watchdog is the one piece here with real state (how long has this
  # box been isolated, how many tier-1 attempts already ran), so — like
  # pull-update.nix — it is written as one explicit, lock-serialised script
  # rather than a bag of small systemd units, and reasoned about as a single
  # state machine.
  lifelineWatchdog = pkgs.writeShellScript "lifeline-watchdog" ''
    #!${pkgs.runtimeShell}
    # NOTE: deliberately NO `set -e` (see pull-update.nix for why): a single
    # failing probe or a nonzero management-check exit must fall through to
    # the escalation logic below, not abort the script before it gets there.
    set -uo pipefail
    export PATH=${watchdogRuntimeBin}:$PATH

    IFACE=${lib.escapeShellArg wd.iface}
    TARGETS=${lib.escapeShellArg (lib.concatStringsSep " " wd.probeTargets)}
    MGMT_CHECK=${lib.escapeShellArg (if wd.managementCheck == null then "" else wd.managementCheck)}
    AGENT_UNIT=${lib.escapeShellArg wd.agentUnit}
    GRACE_SEC=$(( ${toString wd.graceMinutes} * 60 ))
    ALLOW_REBOOT=${if wd.allowSelfReboot then "1" else "0"}
    REBOOT_AFTER_SEC=$(( ${toString wd.rebootAfterHours} * 3600 ))

    STATE_DIR=/var/lib/nixvps-lifeline
    FIRST_FAILURE_FILE="$STATE_DIR/watchdog-first-failure"
    TIER1_COUNT_FILE="$STATE_DIR/watchdog-tier1-count"
    mkdir -p "$STATE_DIR"

    log()  { echo "lifeline-watchdog: $*"; }
    # loud: an actual escalation, not just a status line. Logged at err level
    # via `logger` so it also reaches the serial console if
    # nixvps.lifeline.console is enabled with its default MaxLevelConsole=err
    # — the whole point of an escalation is that it must be visible from
    # OUTSIDE a network that may itself be the thing that's broken.
    loud() { logger -p daemon.err -t lifeline-watchdog "$*"; log "ESCALATION: $*"; }

    # Serialise: never let two overlapping ticks race the state files, or
    # both independently decide to escalate.
    exec 9>/run/lifeline-watchdog.lock
    flock -n 9 || { log "another run holds the lock -- skipping this tick"; exit 0; }

    # -- 1. is this box actually isolated? -----------------------------------
    probe_ok=1
    if [ -n "$TARGETS" ]; then
      probe_ok=0
      for t in $TARGETS; do
        if ping -I "$IFACE" -c 2 -W 2 "$t" >/dev/null 2>&1; then probe_ok=1; break; fi
      done
    fi

    mgmt_ok=0
    if [ -n "$MGMT_CHECK" ]; then
      if "${pkgs.runtimeShell}" -c "$MGMT_CHECK" >/dev/null 2>&1; then mgmt_ok=1; fi
    fi

    if [ "$probe_ok" = 1 ] || [ "$mgmt_ok" = 1 ]; then
      if [ -e "$FIRST_FAILURE_FILE" ]; then
        log "connectivity recovered -- clearing isolation state"
        rm -f "$FIRST_FAILURE_FILE" "$TIER1_COUNT_FILE"
      fi
      exit 0
    fi

    # -- 2. isolated: still inside the grace period? -------------------------
    now=$(date +%s)
    if [ ! -e "$FIRST_FAILURE_FILE" ]; then
      echo "$now" > "$FIRST_FAILURE_FILE"
      log "isolation observed for the first time this episode -- entering grace period"
      exit 0
    fi

    first=$(cat "$FIRST_FAILURE_FILE" 2>/dev/null || echo "$now")
    elapsed=$(( now - first ))

    if [ "$elapsed" -lt "$GRACE_SEC" ]; then
      log "isolated for ''${elapsed}s (grace is ''${GRACE_SEC}s) -- no action yet"
      exit 0
    fi

    # -- 3. escalate. Tier 3 (reboot) is judged purely on total elapsed
    # isolation time, independent of how many tier-1/tier-2 attempts already
    # ran -- a box isolated this long gets rebooted regardless of what the
    # lower tiers already tried.
    if [ "$ALLOW_REBOOT" = 1 ] && [ "$elapsed" -ge "$REBOOT_AFTER_SEC" ]; then
      loud "TIER 3: isolated for ''${elapsed}s (>= ''${REBOOT_AFTER_SEC}s) -- rebooting as a last resort"
      systemctl reboot
      exit 0
    fi

    tier1_count=$(cat "$TIER1_COUNT_FILE" 2>/dev/null || echo 0)

    if [ "$tier1_count" -ge 2 ]; then
      if systemctl list-unit-files systemd-networkd.service 2>/dev/null | grep -q '^systemd-networkd\.service'; then
        loud "TIER 2: still isolated after ''${tier1_count} tier-1 attempts -- restarting systemd-networkd"
        systemctl restart systemd-networkd.service || loud "TIER 2: systemd-networkd restart FAILED"
      else
        loud "TIER 2: still isolated after ''${tier1_count} tier-1 attempts, but systemd-networkd is not present on this system -- nothing to restart at this tier"
      fi
    else
      tier1_count=$(( tier1_count + 1 ))
      loud "TIER 1: isolated for ''${elapsed}s -- restarting $AGENT_UNIT (attempt ''${tier1_count})"
      systemctl restart "$AGENT_UNIT" || loud "TIER 1: $AGENT_UNIT restart FAILED"
    fi

    echo "$tier1_count" > "$TIER1_COUNT_FILE"
  '';

  lifelineHeartbeatCurlArgs = lib.escapeShellArgs (
    [ "-fsS" "--max-time" (toString hb.timeoutSeconds) ]
    ++ lib.optionals (hb.bindInterface != null) [ "--interface" hb.bindInterface ]
    ++ [ hb.url ]
  );
in
{
  options.nixvps.lifeline = {
    watchdog = {
      enable = lib.mkEnableOption "overlay/agent connectivity watchdog with a restart-then-reboot escalation ladder";

      iface = lib.mkOption {
        type = lib.types.str;
        example = "wt0";
        description = ''
          Overlay/agent network interface to probe connectivity through,
          e.g. "wt0". `probeTargets` are pinged with `ping -I iface`, so a
          failing probe cannot be masked by some other, unrelated route
          still working — the whole point is testing whether THIS
          interface still has a path out. Required: there is no sane
          default for a device name specific to your overlay software.
        '';
      };

      probeTargets = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "100.64.0.1" ];
        description = ''
          IP addresses (not hostnames — DNS may itself be part of what's
          broken while isolated) reachable across `iface`, pinged as a
          liveness probe. Isolation is declared only when ALL of these fail
          AND `managementCheck` (if set) also fails. At least one of
          `probeTargets` or `managementCheck` must be set for
          `watchdog.enable` to be valid — see the assertion below.
        '';
      };

      managementCheck = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "curl -fsS http://127.0.0.1:8080/status | grep -q connected";
        description = ''
          Optional shell command, run via `${pkgs.runtimeShell} -c`, that
          exits 0 when your overlay agent's own control plane considers
          this node reachable/registered — typically a status subcommand
          of your overlay's own CLI, or a local status endpoint it
          exposes. If unset, only `probeTargets` decides isolation. If you
          set neither this nor `probeTargets`, `watchdog.enable` fails an
          assertion instead of escalating on every tick with no real
          signal to act on.
        '';
      };

      agentUnit = lib.mkOption {
        type = lib.types.str;
        example = "netbird.service";
        description = ''
          systemd unit for the overlay/mesh agent, restarted at tier 1 —
          e.g. "netbird.service", "tailscaled.service",
          "wg-quick@wt0.service". Required: there is no default that fits
          every overlay tool.
        '';
      };

      graceMinutes = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 15;
        description = ''
          Minutes of continuous isolation to tolerate before taking any
          corrective action at all. The watchdog still runs every 5
          minutes during this window and records when isolation started,
          but does nothing else — this absorbs a single blip (an overlay
          hiccup, a probe target rebooting) without immediately restarting
          anything. Set to 0 to escalate on the very first failing tick.
        '';
      };

      allowSelfReboot = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether tier 3 (`systemctl reboot`) is allowed to fire at all.
          Off by default: a self-triggered reboot is the most drastic and
          least reversible of the three tiers, and on some providers a VM
          that fails to come back up cleanly needs a human anyway. Turn
          this on only once you've confirmed this box reboots cleanly
          unattended — pairing it with `nixvps.lifeline.console` gives you
          somewhere to watch it come back up.
        '';
      };

      rebootAfterHours = lib.mkOption {
        type = lib.types.ints.positive;
        default = 6;
        description = ''
          Total, continuous isolation duration — measured from when
          isolation was first observed, not from when tier 1 first ran —
          after which tier 3 fires, if `allowSelfReboot` is true.
          Independent of how many tier-1/tier-2 attempts already happened:
          a box isolated this long gets rebooted regardless of what the
          lower tiers already tried.
        '';
      };
    };

    sshLifeline = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Keep sshd reachable on every address family this box has, and
          verify at boot that it actually is listening. ON by default: for
          a headless tiny VM, SSH is very often the only door in, so this
          piece of the lifeline ships enabled unless you deliberately turn
          it off — every other `nixvps.lifeline.*` mechanism defaults to
          off and must be opted into instead.
        '';
      };

      clientAliveInterval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 60;
        description = ''
          `ClientAliveInterval` (seconds) in sshd_config. Paired with
          `clientAliveCountMax`, this makes sshd notice and drop a dead TCP
          session instead of holding it open indefinitely — useful on a
          flaky tiny-VM network path where a half-open session can
          otherwise sit unnoticed for a very long time.
        '';
      };

      clientAliveCountMax = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = ''
          `ClientAliveCountMax` in sshd_config — how many missed
          keepalives (spaced `clientAliveInterval` apart) sshd tolerates
          before dropping the session.
        '';
      };
    };

    console = {
      enable = lib.mkEnableOption "serial console flight recorder (getty + kernel console + error-and-worse journal forwarding)";

      device = lib.mkOption {
        type = lib.types.str;
        default = "ttyS0";
        example = "ttyAMA0";
        description = ''
          Serial console device to enable a kernel console and getty on —
          e.g. "ttyS0" (the common x86 cloud-VM serial port), "ttyAMA0" or
          "hvc0" on some aarch64/virtualized platforms. Check what your
          provider's serial-console feature actually exposes; a mismatched
          device means the getty runs but the provider's console viewer
          never sees it.
        '';
      };

      baud = lib.mkOption {
        type = lib.types.ints.positive;
        default = 115200;
        description = ''
          Baud rate for the kernel console parameter
          (`console=<device>,<baud>n8`) and the serial getty. 115200 is the
          near-universal default for cloud-provider serial consoles;
          change it only if your provider documents a different rate.
        '';
      };

      maxLevelConsole = lib.mkOption {
        type = lib.types.enum [ "emerg" "alert" "crit" "err" "warning" "notice" "info" "debug" ];
        default = "err";
        description = ''
          `MaxLevelConsole` in journald.conf — only journal entries at
          this severity or worse are forwarded to the console. "err" is
          the default: loud enough to surface real trouble (including the
          watchdog's own escalations, see `nixvps.lifeline.watchdog`)
          without turning a slow serial line into a firehose of routine
          "info"/"notice" chatter.
        '';
      };

      rateLimitIntervalSec = lib.mkOption {
        type = lib.types.str;
        default = "30s";
        description = ''
          `RateLimitIntervalSec` in journald.conf, paired with
          `rateLimitBurst`. journald applies this rate limit per unit to
          its overall message processing — storage AND forwarding alike —
          there is no separate throttle just for console forwarding. The
          pairing matters here because a crash-looping unit logging at
          "err" would otherwise be able to flood a slow serial line
          forever; these two options cap that, at the cost of also capping
          how many of that same unit's messages land in the regular
          journal during the burst.
        '';
      };

      rateLimitBurst = lib.mkOption {
        type = lib.types.ints.positive;
        default = 100;
        description = ''
          `RateLimitBurst` in journald.conf — messages allowed per unit
          within `rateLimitIntervalSec` before journald starts dropping
          (and counting) the rest. Deliberately tighter than upstream
          journald's own global default (10000): the concern here is
          specifically a slow serial console, not general journal storage.
        '';
      };

      serialAutologin = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Run an UNAUTHENTICATED root getty autologin on `device`, instead
          of a normal login prompt. This is the tradeoff at the heart of
          this option: it turns "the box is otherwise unreachable" into
          "log in over the serial console with zero credentials", which is
          exactly what you want when every other path in is dead — but the
          ONLY thing gating access at that point is whoever your cloud
          provider lets open a serial console session (its own IAM/RBAC,
          API keys, or web-console auth), not this box. Enable it only if
          you trust that provider-side gate as much as you'd trust a root
          SSH key; leave it off (the default) if you'd rather still
          authenticate over serial than hand root to anyone who can reach
          the provider's console feature.
        '';
      };
    };

    heartbeat = {
      enable = lib.mkEnableOption "dead-man's-switch heartbeat ping to an external monitoring URL";

      url = lib.mkOption {
        type = lib.types.str;
        example = "https://hc-ping.com/00000000-0000-0000-0000-000000000000";
        description = ''
          URL to `curl` on a timer — typically a dead-man's-switch/"push"
          monitoring endpoint (the kind that alerts when a ping does NOT
          arrive on schedule, not when it does). Required: there is no
          sane default URL to ping.
        '';
      };

      intervalMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "Minutes between heartbeat pings (`OnUnitActiveSec`).";
      };

      timeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = "`--max-time` passed to `curl` for the heartbeat request.";
      };

      bindInterface = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "eth0";
        description = ''
          Optional interface to bind the heartbeat's outbound `curl`
          request to (`curl --interface`). Defaults to null — i.e. use
          whatever the box's normal default route is. This is
          deliberately NEVER `nixvps.lifeline.watchdog.iface`: the
          heartbeat's entire purpose is proving the box's ordinary public
          egress is alive, independent of the overlay — routing it through
          the overlay would make it prove only that the overlay is up
          (which the watchdog already checks), and it would risk being
          disrupted by the watchdog's own tier-1/tier-2 restarts of that
          same overlay. Only set this if the box genuinely has more than
          one public-facing interface and you need to pick a specific one.
        '';
      };
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !wd.enable || (wd.probeTargets != [ ] || wd.managementCheck != null);
          message = ''
            nixvps.lifeline.watchdog.enable requires at least one of
            `probeTargets` or `managementCheck` to be set -- otherwise it
            has no signal to distinguish real isolation from "nothing
            configured to check", and would escalate (restart the agent,
            then the network stack, then optionally reboot) on every
            single tick.
          '';
        }
      ];
    }

    (lib.mkIf wd.enable {
      systemd.services.lifeline-watchdog = {
        description = "Overlay/agent connectivity watchdog (probe -> escalate -> recover)";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lifelineWatchdog;
        };
      };

      systemd.timers.lifeline-watchdog = {
        description = "Periodic overlay/agent connectivity check";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "5min";
          Persistent = true;
        };
      };
    })

    (lib.mkIf ssh.enable {
      services.openssh = {
        enable = lib.mkDefault true;
        # AddressFamily "any" (upstream default) plus no ListenAddress
        # pinning here means sshd binds every address family this box
        # currently has, instead of only IPv4 or only IPv6 — a box whose
        # addressing changes (a dual-stack flip, going DHCPv6-only, ...)
        # doesn't silently lose its one guaranteed way in over it.
        settings = {
          ClientAliveInterval = lib.mkDefault ssh.clientAliveInterval;
          ClientAliveCountMax = lib.mkDefault ssh.clientAliveCountMax;
        };
      };

      systemd.services.lifeline-assert-ssh-listening = {
        description = "Assert sshd is listening on :22 for both IPv4 and IPv6 (diagnostic only, never fails boot)";
        after = [ "sshd.service" ];
        requires = [ "sshd.service" ];
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.iproute2 pkgs.util-linux ];
        serviceConfig.Type = "oneshot";
        script = ''
          set -uo pipefail
          # `ss -4`/`-6` filter by the SOCKET's declared address family. A
          # single dual-stack "[::]:22" listener (AF_INET6, bound to "::")
          # commonly still serves IPv4 clients via v4-mapped addresses when
          # net.ipv6.bindv6only=0 (the Linux default) — so a missing "-4"
          # hit here is a diagnostic breadcrumb, NOT proof that IPv4 access
          # is actually broken. This check only ever logs; it never fails
          # the unit or blocks boot.
          v4=$(ss -H -tln4 '( sport = :22 )' 2>/dev/null)
          v6=$(ss -H -tln6 '( sport = :22 )' 2>/dev/null)
          if [ -z "$v4" ]; then
            logger -p daemon.err -t lifeline-ssh "no AF_INET (IPv4) listener seen for :22 -- may still be fine if a dual-stack [::]:22 socket is serving v4-mapped clients, see this unit's script comment"
          fi
          if [ -z "$v6" ]; then
            logger -p daemon.err -t lifeline-ssh "no AF_INET6 (IPv6) listener seen for :22"
          fi
          exit 0
        '';
      };
    })

    (lib.mkIf console.enable (lib.mkMerge [
      {
        # NixOS list-typed options merge by concatenation across modules;
        # if another module also adds a "console=" kernel parameter, the
        # kernel's own rule (the LAST "console=" wins as the primary
        # /dev/console) decides which one you actually see output on —
        # check your host's final `boot.kernelParams` if you need this one
        # to be primary.
        boot.kernelParams = [ "console=${console.device},${toString console.baud}n8" ];

        services.journald.extraConfig = lib.mkDefault ''
          ForwardToConsole=yes
          MaxLevelConsole=${console.maxLevelConsole}
          RateLimitIntervalSec=${console.rateLimitIntervalSec}
          RateLimitBurst=${toString console.rateLimitBurst}
        '';

        # NixOS's systemd getty-generator auto-enables `serial-getty@<tty>`
        # for any tty named in a `console=` kernel parameter, so listing
        # `device` in `boot.kernelParams` above is sufficient to get a
        # normal login prompt on it without wiring the unit by hand.
      }

      (lib.mkIf console.serialAutologin {
        systemd.services."serial-getty@${console.device}".serviceConfig.ExecStart = lib.mkForce
          "${pkgs.util-linux}/bin/agetty --autologin root --keep-baud ${console.device} ${toString console.baud},38400,9600 $TERM";
      })
    ]))

    (lib.mkIf hb.enable {
      systemd.services.lifeline-heartbeat = {
        description = "Dead-man's-switch heartbeat ping (failure is journal-only -- alerting is the receiver's job)";
        path = [ pkgs.curl pkgs.util-linux ];
        serviceConfig.Type = "oneshot";
        script = ''
          set -uo pipefail
          if ! curl ${lifelineHeartbeatCurlArgs} >/dev/null 2>&1; then
            logger -p daemon.warning -t lifeline-heartbeat "heartbeat request failed -- this failure is only logged here; noticing a MISSED heartbeat is the receiving monitor's job, not this box's"
          fi
        '';
      };

      systemd.timers.lifeline-heartbeat = {
        description = "Periodic dead-man's-switch heartbeat";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = "${toString hb.intervalMinutes}min";
          Persistent = true;
        };
      };
    })
  ];
}
