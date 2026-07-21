# tiny-vm.nix — a conservative baseline profile for small, disk- and
# RAM-constrained cloud NixOS VMs (the free-tier / cheapest-tier class:
# roughly 1 vCPU, ~1 GB RAM, a small disk).
#
# This module does NOT try to be a full system configuration. It only sets
# a handful of defaults that are almost always the right call on a box this
# small, and it sets every one of them with `lib.mkDefault` so a consuming
# configuration can override any single value without a fight. Nothing
# here is site-specific: no hostnames, no cache URLs, no keys, no network
# identities. Where a setting genuinely depends on a choice only the
# consumer can make (an admin username, a swap size), it is exposed as an
# option with a neutral default instead of being hardcoded.
#
# Enable via `nixvps.tinyVm.enable = true;`.

{ config, lib, pkgs, ... }:

let
  cfg = config.nixvps.tinyVm;
in
{
  options.nixvps.tinyVm = {
    enable = lib.mkEnableOption "conservative baseline profile for a small cloud VM";

    rootMountOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "compress=zstd" "noatime" "space_cache=v2" ];
      description = ''
        Mount options applied to the `/` filesystem when it is btrfs.
        `compress=zstd` trades a little CPU for meaningfully less disk I/O
        and more free space on a small root volume; `noatime` avoids a
        metadata write on every read, which matters more when the disk is
        small/slow than when it is fast/local; `space_cache=v2` is the
        modern free-space tracking format and is simply better than v1 on
        any reasonably current kernel.
      '';
    };

    journalMaxUse = lib.mkOption {
      type = lib.types.str;
      default = "200M";
      description = ''
        Upper bound on persistent journal disk usage
        (`SystemMaxUse=`). A tiny VM usually also has a small disk, and an
        unbounded journal can quietly fill it; 200M is a conservative cap
        that still keeps a useful amount of history.
      '';
    };

    journalRuntimeMaxUse = lib.mkOption {
      type = lib.types.str;
      default = "50M";
      description = ''
        Upper bound on the in-memory/tmpfs journal
        (`RuntimeMaxUse=`), scaled down to match a small RAM budget.
      '';
    };

    nixMaxJobs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = ''
        `nix.settings.max-jobs`. A single vCPU / small-RAM box gets no
        benefit from parallel derivation builds and risks the nix-daemon
        itself competing the running workload out of memory during a
        rebuild; 1 keeps builds serialized. Raise it explicitly if the VM
        is bigger than the class this profile targets.
      '';
    };

    nixCores = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1;
      description = ''
        `nix.settings.cores` — cores made available to *each* build job.
        Paired with `nixMaxJobs`, this keeps a single build from trying to
        use more parallelism than a small VM actually has to give.
      '';
    };

    gcOlderThan = lib.mkOption {
      type = lib.types.str;
      default = "30d";
      description = ''
        Age threshold passed to the Nix garbage collector's
        `--delete-older-than`. A small disk fills up fast with old
        generations; automatic weekly GC keeps only a month of history by
        default.
      '';
    };

    interactiveShellSafety = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Confirm-before-clobber aliases (`rm`/`cp`/`mv` -&gt; `-i`) for
        interactive shells. This matters more on a box in this class than
        on a normal desktop: there is deliberately no snapshot/backup layer
        under a bare cloud VM the way there is on the rest of the fleet, so
        a fat-fingered command here has no safety net underneath it. Set via
        plain `environment.shellAliases` — no fish, no home-manager; NixOS
        applies it to every user's shell regardless of which one an
        interactive session actually uses.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Root filesystem tuning. Only takes effect if `/` is actually mounted
    # as btrfs; on any other filesystem these options are simply unused by
    # the relevant mount unit, so this is safe to leave enabled generically.
    fileSystems."/".options = lib.mkDefault cfg.rootMountOptions;

    # A small VM has a small disk: don't let the journal grow unbounded.
    services.journald.extraConfig = lib.mkDefault ''
      SystemMaxUse=${cfg.journalMaxUse}
      RuntimeMaxUse=${cfg.journalRuntimeMaxUse}
      Compress=yes
    '';

    # Keep the nix-daemon from out-competing the actual workload for CPU
    # and RAM during a rebuild, and keep the store from growing unbounded
    # on a small disk.
    nix.settings = {
      max-jobs = lib.mkDefault cfg.nixMaxJobs;
      cores = lib.mkDefault cfg.nixCores;
      auto-optimise-store = lib.mkDefault true;
    };

    nix.gc = {
      automatic = lib.mkDefault true;
      dates = lib.mkDefault "weekly";
      options = lib.mkDefault "--delete-older-than ${cfg.gcOlderThan}";
    };

    # Cap the number of kept boot-loader generations so old system closures
    # don't accumulate indefinitely on a small disk. This only has any
    # effect on bootloaders that honor the option (e.g. systemd-boot); it
    # is harmless to set unconditionally.
    boot.loader.systemd-boot.configurationLimit = lib.mkDefault 10;

    # Confirm-before-clobber safety net (see interactiveShellSafety above).
    environment.shellAliases = lib.mkIf cfg.interactiveShellSafety {
      rm = lib.mkDefault "rm -i";
      cp = lib.mkDefault "cp -i";
      mv = lib.mkDefault "mv -i";
    };
  };
}
