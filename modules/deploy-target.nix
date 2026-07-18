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
  };

  config = lib.mkIf cfg.enable {
    nix.settings = {
      substituters = lib.mkAfter cfg.caches;
      trusted-public-keys = lib.mkAfter cfg.trustedPublicKeys;
      require-sigs = cfg.requireSigs;
    };

    users.users.root.openssh.authorizedKeys.keys = lib.mkAfter cfg.deployAuthorizedKeys;

    services.openssh.enable = lib.mkDefault true;
  };
}
