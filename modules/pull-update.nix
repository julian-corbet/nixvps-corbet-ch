# pull-update.nix — autonomous, reboot-less, PULL-based self-update for a
# tiny, possibly public-only NixOS node (no stable inbound route, so a
# central push-based deploy controller cannot always reach it). This is the
# node-side half of a pull delivery model: instead of a controller reaching
# in, the node reaches OUT on a timer.
#
# OWNERSHIP STATUS: this is the repository's earlier delivery implementation
# and remains functional. Nixdeploy is now the sole delivery specialist for
# build/update triggers, signed targets, receiver scheduling, activation,
# health and rollback. Nixvps owns only the constrained guest policy. This
# note records the overlap without pretending its consumers have migrated.
#
# Every tick the node:
#   1. reads a DNS TXT pointer (published by your build/deploy pipeline after
#      each build) naming the target `system.build.toplevel` store path built
#      for THIS host;
#   2. if that differs from the running system, substitutes the signed
#      closure from your binary cache — DOWNLOAD ONLY, and `nix` verifies the
#      cache's signature (require-sigs = true) so a spoofed pointer can
#      inject nothing;
#   3. validates it (well-formed store path whose name is nixos-system-<host>-*,
#      and it carries a real switch-to-configuration) then sets the system
#      profile and runs `switch-to-configuration switch` — LIVE, NO reboot;
#   4. health-checks the units (and, optionally, a URL); on failure re-points
#      the profile at the previous good toplevel and switches back — a LOCAL
#      canary standing in for a push-based deploy tool's remote rollback,
#      which only works when the controller can still reach the node.
#
# HARD invariants:
#   * NEVER builds  — only `nix copy` (substitute) + `switch-to-configuration`.
#                     No `nixos-rebuild`, no eval, no compile. Tiny boxes
#                     can't afford to build on-box.
#   * NEVER reboots — `switch` applies all userspace live; a new kernel just
#                     installs as a queued boot entry and is LEFT queued.
#   * NEVER stops the workload beyond the unit restarts a normal `switch`
#     already performs; a bad closure is rolled back, not left broken.
#
# Reusable for any small node that can't rely on a controller pushing to it;
# enable via options.nixvps.pullUpdate.enable.

{ config, lib, pkgs, ... }:

let
  cfg = config.nixvps.pullUpdate;
  generationGuard = builtins.readFile ../lib/pull-update-generation-guard.sh;

  runtimeBin = lib.makeBinPath [
    pkgs.dnsutils # dig
    pkgs.curl
    pkgs.systemd # systemctl
    pkgs.coreutils # readlink, head, tr, sleep, printf
    pkgs.util-linux # flock
    config.nix.package # nix, nix-env
  ];

  pull-update = pkgs.writeShellScript "pull-update" ''
    #!${pkgs.runtimeShell}
    # NOTE: deliberately NO `set -e`. An `errexit` script aborts on the first
    # non-zero (e.g. `systemctl is-active` on an inactive unit inside the
    # health loop) and skips its own recovery. We handle every failure
    # explicitly and default to "do nothing, box unchanged".
    set -uo pipefail
    export PATH=${runtimeBin}:$PATH

    CACHE=${lib.escapeShellArg cfg.cache}
    POINTER=${lib.escapeShellArg cfg.pointerName}
    HOST=${lib.escapeShellArg cfg.host}
    HEALTH_URL=${lib.escapeShellArg (if cfg.healthUrl == null then "" else cfg.healthUrl)}
    UNITS=${lib.escapeShellArg (lib.concatStringsSep " " cfg.healthUnits)}
    ALLOW_KNOWN_GENERATION_ROLLBACK=${if cfg.allowKnownGenerationRollback then "1" else "0"}
    PROFILE=/nix/var/nix/profiles/system

    ${generationGuard}

    log()  { echo "pull-update: $*"; }
    # skip: nothing to apply this tick — box stays exactly as-is, exit clean.
    skip() { log "SKIP: $*"; exit 0; }
    # fail: a real error AFTER a switch was attempted (rollback already handled).
    fail() { log "FAIL: $*"; exit 1; }

    health_ok() {
      # One-shot verification hook: a marker at /run/pull-update-force-unhealthy
      # forces the NEXT health verdict to "unhealthy" and is consumed immediately,
      # so a rollback's post-revert health check then runs for real. Only ever
      # created by hand during verification; never present in normal operation.
      if [ -e /run/pull-update-force-unhealthy ]; then
        rm -f /run/pull-update-force-unhealthy
        log "health: FORCED unhealthy once (test hook)"; return 1
      fi
      local tries=0 u ok
      while [ "$tries" -lt 6 ]; do
        ok=1
        for u in $UNITS; do
          if ! systemctl is-active --quiet "$u"; then log "health: $u not active"; ok=0; fi
        done
        if [ "$ok" = 1 ]; then
          if [ -z "$HEALTH_URL" ] || curl -fsS -o /dev/null --max-time 10 "$HEALTH_URL"; then
            return 0
          fi
        fi
        tries=$((tries + 1)); sleep 10
      done
      return 1
    }

    activate() { # $1 = toplevel store path
      nix-env -p "$PROFILE" --set "$1" || return 1
      "$1/bin/switch-to-configuration" switch || return 1
    }

    # ── 0. serialise: never let two runs (or a tick that overran into the next)
    # attempt overlapping switches — they would collide on the activation lock and
    # a doomed rollback ("Could not acquire lock"). A second run just skips.
    exec 9>/run/pull-update.lock
    flock -n 9 || skip "another pull-update run holds the lock — skipping this tick"

    # ── 1. read the pointer ──────────────────────────────────────────────────
    TARGET=$(dig +short TXT "$POINTER" 2>/dev/null | head -n1 | tr -d '"' | tr -d '[:space:]')
    [ -n "$TARGET" ] || skip "no pointer TXT at $POINTER (nothing published yet)"

    # ── 2. validate: well-formed store path whose name is THIS host's system ──
    # Guards against a mis-set / spoofed pointer switching us to a foreign config.
    case "$TARGET" in
      /nix/store/*-nixos-system-"$HOST"-*) : ;;
      *) skip "pointer '$TARGET' is not a /nix/store nixos-system-$HOST-* path — refusing" ;;
    esac

    # ── 3. differs from the running system? ──────────────────────────────────
    CURRENT=$(readlink -f /run/current-system)
    [ "$TARGET" != "$CURRENT" ] || { log "already on target ($TARGET)"; exit 0; }

    # A stale but correctly signed pointer is still dangerous. If its path is
    # already recorded as an older system-profile generation, it is not an
    # update: it is a rollback request. Refuse it by default before downloading
    # or restarting anything. A previously unseen path cannot be ordered from a
    # path alone and proceeds to the normal signature + canary gates.
    if [ "$ALLOW_KNOWN_GENERATION_ROLLBACK" != 1 ] && \
       is_known_generation_rollback "$CURRENT" "$TARGET"; then
      skip "target is known system generation $KNOWN_TARGET_GENERATION, older than running generation $KNOWN_CURRENT_GENERATION — refusing stale-pointer rollback"
    fi

    # ── 4. substitute the signed closure (DOWNLOAD ONLY, sig-checked) ─────────
    # If the target is ALREADY valid in the local store (a prior tick pulled it, or
    # it was pre-staged), skip the download entirely — so a transient cache outage
    # can never block activating a closure we already hold, and we avoid a
    # pointless round-trip. `nix copy` (the miss path) enforces require-sigs, so
    # only a cache-signed closure is accepted from the cache (a spoofed pointer
    # can at worst name a legitimate older build). Anything already local got
    # there via such a checked copy (or a trusted-root push), so activating it
    # is sound.
    if nix path-info --offline "$TARGET" >/dev/null 2>&1; then
      log "target $TARGET already present locally — skipping download"
    else
      log "target $TARGET differs from current — pulling from $CACHE"
      if ! nix copy --from "$CACHE" "$TARGET" 2>&1; then
        skip "nix copy failed (cache unreachable, or path absent/unsigned) — staying on $CURRENT"
      fi
      if ! nix path-info "$TARGET" >/dev/null 2>&1; then
        skip "$TARGET not valid in local store after copy — staying on $CURRENT"
      fi
    fi
    [ -x "$TARGET/bin/switch-to-configuration" ] || \
      skip "$TARGET has no switch-to-configuration — refusing"

    # ── 5. activate live (NO reboot), remembering the good generation ─────────
    GOOD="$CURRENT"
    log "activating (reboot-less switch): $CURRENT -> $TARGET"
    if ! activate "$TARGET"; then
      log "activation failed — rolling back to $GOOD"
      activate "$GOOD" || fail "activation AND rollback both failed — MANUAL INTERVENTION on $HOST"
      fail "activation of $TARGET failed; rolled back to $GOOD"
    fi

    # ── 6. canary: verify the workload, else revert ──────────────────────────
    if health_ok; then
      log "SUCCESS: now on $TARGET; workload healthy"
      exit 0
    fi
    log "post-switch health check FAILED — rolling back to $GOOD"
    if ! activate "$GOOD"; then
      fail "ROLLBACK activation to $GOOD failed — MANUAL INTERVENTION on $HOST"
    fi
    if health_ok; then
      fail "rolled back to $GOOD; workload healthy again (bad closure $TARGET rejected)"
    fi
    fail "rolled back to $GOOD but health STILL failing — MANUAL INTERVENTION on $HOST"
  '';
in
{
  options.nixvps.pullUpdate = {
    enable = lib.mkEnableOption "autonomous reboot-less pull self-update for a small NixOS node";

    host = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Host name embedded in the accepted toplevel path (nixos-system-<host>-*).";
    };

    cache = lib.mkOption {
      type = lib.types.str;
      description = ''
        Binary cache URL to substitute the signed toplevel from. Must be a
        cache your `nix.settings.trusted-public-keys` (or equivalent) trusts,
        since `nix copy` enforces `require-sigs = true`. There is no default:
        you must point this at your own signed binary cache.
      '';
    };

    domain = lib.mkOption {
      type = lib.types.str;
      description = ''
        DNS zone under which the `_deploy.<host>` TXT pointer is published.
        Used only to build the default `pointerName`; ignored if you set
        `pointerName` directly.
      '';
    };

    pointerName = lib.mkOption {
      type = lib.types.str;
      default = "_deploy.${config.networking.hostName}.${cfg.domain}";
      description = ''
        DNS TXT record whose value is the current target toplevel store path,
        published by your build/deploy pipeline after each build.
      '';
    };

    healthUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        URL that must return 2xx for the workload to count as healthy. If
        null, only the `healthUnits` check runs (units-only health). Note
        that a unit being "active" is a shallow canary — it does not prove
        the service inside is actually serving correctly; add a real health
        endpoint here if you have one.
      '';
    };

    healthUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "sshd" ];
      description = ''
        systemd units that must all be active for a switch to be kept.
        Replace this with the units that actually matter for your workload —
        the default is only a minimal generic placeholder that keeps SSH
        reachable; it does not validate your application.
      '';
    };

    allowKnownGenerationRollback = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Permit a DNS pointer to activate a store path already present as an
        older system-profile generation. False by default: a stale but validly
        signed pointer must not silently downgrade a healthy node and restart
        its workload. Set true only for a deliberate rollback publication;
        previously unseen targets still pass through the normal signature and
        health gates because a bare store path carries no total ordering.
      '';
    };

    onBootSec = lib.mkOption {
      type = lib.types.str;
      default = "10min";
      description = "Delay after boot before the first pull.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "1d";
      description = "Interval between pulls (OnUnitActiveSec). Once a day — a box that missed one tick still converges; not a busy 30-min poll.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.pull-update = {
      description = "Pull self-update (reboot-less; never builds on-box)";
      # After the network + the workload so a boot-time tick health-checks a
      # settled system, not a half-started one.
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # CRITICAL: this service RUNS `switch-to-configuration`. If the pulled config
      # changes pull-update.service itself, activation would stop/restart THIS unit
      # mid-switch and cancel its own job ("Job for pull-update.service canceled").
      # These flags make activation leave the running instance alone; the new unit
      # definition simply takes effect on the NEXT timer tick.
      restartIfChanged = false;
      stopIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pull-update;
        # This unit must be root to activate a NixOS system, but its fetcher
        # state is service state, not root's interactive home.  Give Nix a
        # stable cache for binary-cache metadata without leaving
        # /root/.cache/nix behind after every timer tick.  HOME also contains
        # any future per-user state in this explicitly owned directory.
        StateDirectory = "pull-update";
        CacheDirectory = "pull-update";
        Environment = [
          "HOME=/var/lib/pull-update"
          "XDG_CACHE_HOME=/var/cache/pull-update"
        ];
        # The script only orchestrates: `nix copy` runs in the nix-daemon's own
        # cgroup and the switched units live in their OWN slices, so capping
        # this unit can't starve the copy or an activation restart.
        MemoryMax = "160M";
        # A slow/at-most-once run; never let two overlap.
        TimeoutStartSec = "20min";
      };
      unitConfig.StartLimitIntervalSec = 0;
    };

    systemd.timers.pull-update = {
      description = "Periodic pull self-update";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = cfg.onBootSec;
        OnUnitActiveSec = cfg.interval;
        RandomizedDelaySec = "5min";
        Persistent = true;
      };
    };
  };
}
