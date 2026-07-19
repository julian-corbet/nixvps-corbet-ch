# nano.nix — a STRUCTURAL survival profile for the extreme low end: NixOS
# on a ~256 MB-RAM VPS, one tier below tiny-vm's ~1 GB class. This is the
# identity of nixvps at its edge: sub-1 GB down to 256 MB.
#
# IMPORTANT — read this before enabling it:
#
#   A 256 MB box can only run NixOS as a RECEIVER, never a builder. This
#   module makes the structural cuts that make that survivable: it trims
#   memory-hungry defaults a box this small cannot afford, and it forces
#   the nix-daemon into substitute-only mode so a stray `nixos-rebuild
#   switch` cannot try to build something on-box and OOM the whole
#   machine. It pairs with `nixvps.deploy-target` / `nixvps.pull-update`
#   to actually deliver pre-built closures from elsewhere.
#
#   This module does NOT do RAM-pressure *tuning*. There is no zram
#   percentage/algorithm choice here, no zswap, no oomd policy, no memory
#   ladder. That work belongs to the sibling nixram project
#   (https://github.com/julian-corbet/nixram-corbet-ch) — nixram decides
#   HOW MUCH memory pressure relief to apply and how aggressively;
#   `nano.nix` only makes sure the box has the *structural* room for that
#   tuning to matter in the first place. The one exception is
#   `enableZramSwap`, which flips on zram swap as a bare structural
#   safety net (a 256 MB box with zero swap has no cushion at all) — but
#   even that toggle does not choose a size, algorithm, or swappiness;
#   those remain nixram's decisions to make on top of this.
#
# The three-project split, restated: nixvps/nano.nix = structural
# survival (this file). nixram = RAM-pressure tuning. pull-update /
# deploy-target = delivery of pre-built closures. All three compose; none
# of them substitute for the others.
#
# Every setting below uses `lib.mkDefault`, so nothing here fights an
# override from a consuming configuration.
#
# Enable via `nixvps.nano.enable = true;`.

{ config, lib, pkgs, ... }:

let
  cfg = config.nixvps.nano;
in
{
  options.nixvps.nano = {
    enable = lib.mkEnableOption "extreme low-end (~256MB) NixOS VPS survival profile";

    enableZramSwap = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Turn on `zramSwap.enable` as a bare structural safety net — a
        256 MB box with no swap at all has no cushion before the OOM
        killer starts picking victims. This toggle only flips zram swap
        ON; it does not pick a size, a compression algorithm, or a
        swappiness value. Sizing and tuning that is nixram's job, not
        this module's — set nixram's options on top of this if you want
        anything other than its stock defaults.
      '';
    };

    enableManPages = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Opt-in escape hatch for `documentation.man.enable`. Man pages
        cost real closure size and a little RAM in page cache for
        something a 256 MB box almost never needs interactively; this
        profile disables documentation hard by default and only this
        one option exists to bring man pages back selectively, without
        reintroducing the rest of `documentation.nixos`/info/doc output.
      '';
    };

    nixDaemonMemoryMax = lib.mkOption {
      type = lib.types.str;
      default = "128M";
      description = ''
        `systemd.services.nix-daemon.serviceConfig.MemoryMax`. Even with
        `max-jobs = 0` forcing substitute-only operation, the daemon
        itself (and an operator who overrides max-jobs back up) can
        still be pointed at a build; this caps what the daemon's cgroup
        is allowed to consume so a stray build attempt gets OOM-killed
        by systemd instead of taking the rest of the 256 MB box down
        with it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # --- Documentation: a 256MB box cannot afford to keep any of this in
    # the closure or the page cache. Disable the lot by default, with
    # `enableManPages` as the one selective opt-in.
    documentation.enable = lib.mkDefault cfg.enableManPages;
    documentation.man.enable = lib.mkDefault cfg.enableManPages;
    documentation.nixos.enable = lib.mkDefault false;
    documentation.info.enable = lib.mkDefault false;
    documentation.doc.enable = lib.mkDefault false;
    documentation.dev.enable = lib.mkDefault false;

    # `command-not-found` ships (and periodically refreshes) a database
    # just to print a suggestion on a typo — pure overhead on a box this
    # small.
    programs.command-not-found.enable = lib.mkDefault false;
    #
    # NOTE: upstream nixpkgs used to offer `environment.noXlibs` for a
    # similar "trim X11-adjacent libs out of the closure" cut, but the
    # option was removed upstream (it caused surprising breakage for
    # general users) with no direct replacement. There is nothing
    # equivalent left to set structurally here; if X11 libraries are
    # genuinely unused on a given box, that has to be trimmed via package
    # overrides/overlays in the consuming configuration, not this module.

    # nscd was investigated as a cut and deliberately left alone: on
    # current nixpkgs its default implementation is already `nsncd`, a
    # small non-caching NSS proxy rather than the heavy glibc daemon the
    # name suggests, so there is little RAM to reclaim by disabling it.
    # More importantly, systemd's own NSS module is only loadable when
    # `services.nscd.enable` is true — turning it off trips a hard
    # upstream assertion unless `system.nssModules` is also force-cleared,
    # which would silently break NSS lookups for systemd-managed dynamic
    # users. Not a safe structural cut on this profile; left at its
    # upstream default.

    # udisks2 exists to support desktop disk management (auto-mounting,
    # polkit-gated device actions) — irrelevant on a headless VPS and one
    # more permanently-resident D-Bus service a 256 MB box doesn't need.
    services.udisks2.enable = lib.mkDefault false;

    # Deliberately NOT touched here: `systemd.oomd`. Whether to run an
    # OOM daemon, and how aggressively, is a RAM-pressure *policy*
    # decision — that belongs to nixram, not to this structural profile.
    # This module only removes services; it does not add memory-pressure
    # machinery of its own.

    # --- nix-daemon discipline for a box that CANNOT build.
    #
    # `max-jobs = 0` forces Nix into substitute-only mode: it will never
    # attempt to build a derivation locally, only fetch pre-built output
    # from a binary cache. This REQUIRES pairing with a binary cache
    # (see `nixvps.deploy-target` for the substituter/trusted-key side of
    # that) — with no cache reachable, or with a store path the cache
    # doesn't have, any operation that would otherwise build something
    # will simply FAIL instead of trying to build in 256 MB of RAM. That
    # failure is intentional: it is a far better outcome than the box
    # locking up or getting OOM-killed mid-build.
    nix.settings.max-jobs = lib.mkDefault 0;
    nix.settings.cores = lib.mkDefault 1;
    nix.settings.keep-outputs = lib.mkDefault false;
    nix.settings.keep-derivations = lib.mkDefault false;

    # Belt-and-suspenders: even with substitute-only enforced above, cap
    # what the nix-daemon's own cgroup may consume, so an operator who
    # overrides max-jobs back up (or a code path that bypasses it) can't
    # take the whole box down when it tries to build something anyway.
    systemd.services.nix-daemon.serviceConfig.MemoryMax = lib.mkDefault cfg.nixDaemonMemoryMax;

    # --- Swap: structural safety only, not tuning.
    #
    # This only flips zram swap on; it does not choose a size,
    # compression algorithm, or swappiness — those are nixram's
    # decisions, layered on top of this module, not this module's own.
    zramSwap.enable = lib.mkDefault cfg.enableZramSwap;

    # --- Boot: deliberately minimal, deliberately unopinionated.
    #
    # Keep only what is generically true of "small disk, no console
    # hardcoded here": a small VPS image is typically built/baked once
    # (see this repo's image-baking tooling) and booted headless with a
    # serial console for out-of-band access when something goes wrong —
    # but which console device, and how it's wired up, is a per-provider
    # detail this module intentionally does not guess at. Set
    # `boot.kernelParams`/console settings in the consuming configuration
    # or the image-bake step, not here.
    boot.loader.systemd-boot.configurationLimit = lib.mkDefault 3;
  };
}
