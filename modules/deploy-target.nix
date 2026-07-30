# deploy-target.nix — the passive-receiver counterpart to the pull-update
# module: it configures a node to TRUST a signed binary cache and to accept
# a signed deploy identity, but performs no update logic itself.
#
# The model this pairs with: a central builder produces and signs system
# closures, then publishes them to a binary cache. A node running this
# module is prepared to:
#   1. SUBSTITUTE those signed closures from the configured cache(s) —
#      never build them on-box. `nix.settings.require-sigs = true` means
#      the daemon only accepts store paths whose signature matches one of
#      `trustedPublicKeys`; an unsigned or wrongly-signed path is refused
#      even if the cache offering it is reachable.
#   2. ACCEPT an inbound deploy over SSH, by trusting one or more deploy
#      keys in root's `authorized_keys`. This is the "push" half: some
#      external deploy tool (or a human) connects in and switches the
#      node to a new signed closure it already trusted per (1).
#
# This module intentionally does nothing else: no timers, no polling, no
# health checks, no rollback. Use it standalone for a push-deployed node,
# or alongside pull-update.nix (options.nixvps.pullUpdate) for a node that
# also self-updates on a timer — the two do not conflict, since pull-update
# only needs the SAME substituter trust this module establishes.
#
# Enable via options.nixvps.deployTarget.enable; every setting defaults to
# empty/neutral so enabling with no other options changes nothing except
# turning SSH on and honoring require-sigs (both already sane defaults for
# a deploy-receiving node).

{ config, lib, ... }:

let
  cfg = config.nixvps.deployTarget;
in
{
  options.nixvps.deployTarget = {
    enable = lib.mkEnableOption "trust a signed binary cache and accept signed deploys (passive deploy-target)";

    caches = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Signed binary cache URLs to substitute closures from, e.g.
        "https://cache.example.com". Added to `nix.settings.substituters`
        alongside whatever is already configured; does not replace nixpkgs'
        own defaults.
      '';
    };

    trustedPublicKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        The cache's signing public key(s), e.g.
        "cache.example.com-1:base64-encoded-key=". REQUIRED for anything
        from `caches` to actually be substituted: `require-sigs` is on by
        default, so an unsigned or unrecognized-key closure is refused even
        though the cache itself is reachable.
      '';
    };

    deployAuthorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        SSH public keys for the deploy identity, added to root's
        `authorized_keys` (additively — existing keys set elsewhere are
        preserved, never clobbered). Whatever holds the matching private
        key can log in as root to switch this node to a new closure.
      '';
    };

    requireSigs = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the nix daemon requires a valid signature (from
        `trustedPublicKeys` or another trusted key) before accepting any
        substituted path. Leave this on unless you have a specific reason
        to trust unsigned closures.
      '';
    };

    httpConnections = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = ''
        `nix.settings.http-connections` — bounds the daemon's parallel HTTP
        connections while substituting a signed closure from `caches`.
        `null` (the default) leaves nix's own default untouched. Set this on
        a RAM-constrained receiver so a large closure's substitution can't
        wall the box into the OOM killer purely from download parallelism —
        every byte in flight at once is a byte of RAM this receiver does not
        get to spend on its actual workload.
      '';
    };

    downloadBufferSize = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = ''
        `nix.settings.download-buffer-size`, in bytes — the in-RAM buffer the
        nix daemon holds per in-flight substitution. `null` (the default)
        leaves nix's own default untouched. Paired with `httpConnections` for
        the same RAM-constrained-receiver reasoning.
      '';
    };

    maxInplaceDeltaBytes = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = ''
        Pure DATA — not a `nix.settings` knob this module renders itself.
        The largest download delta (NAR bytes of new store paths this node
        would actually have to fetch, versus what it already has) that an
        EXTERNAL deploy controller may activate here in place. `null` (the
        default) means unbounded: a controller reading this value is
        expected to treat `null` as "no ceiling, always safe to deploy in
        place". Set it on a receiver small enough that an unbounded in-place
        swap — a nixpkgs world-rebuild refetches ~every store path — risks
        OOM-rebooting the box mid-activation; the external controller is
        expected to route an over-ceiling delta to a prebuilt-image path
        instead of activating the fat swap here. This module never reads its
        own value: it exists so the receiver states the fact once, in the
        same place as the rest of its substitution/trust configuration,
        instead of every external controller keeping its own per-node table.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    nix.settings = {
      substituters = lib.mkAfter cfg.caches;
      trusted-public-keys = lib.mkAfter cfg.trustedPublicKeys;
      require-sigs = cfg.requireSigs;
    };

    # Substitution RAM-safety clamp. http-connections needs mkForce: nixpkgs'
    # own nix.settings rendering already assigns it a plain (non-mkDefault)
    # value, so a plain assignment here would lose that priority fight;
    # download-buffer-size carries no such competing default, so a plain
    # assignment wins cleanly. Both are `mkIf`-gated so leaving the option at
    # its `null` default emits nothing at all (parity with never having set
    # it), never a competing default of nix's own.
    nix.settings.http-connections = lib.mkIf (cfg.httpConnections != null) (lib.mkForce cfg.httpConnections);
    nix.settings.download-buffer-size = lib.mkIf (cfg.downloadBufferSize != null) cfg.downloadBufferSize;

    users.users.root.openssh.authorizedKeys.keys = lib.mkAfter cfg.deployAuthorizedKeys;

    services.openssh.enable = lib.mkDefault true;
  };
}
