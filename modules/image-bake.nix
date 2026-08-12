# image-bake.nix — bake a bootable NixOS disk image with `systemd-repart`
# (nixpkgs' `image.repart` module), so a tiny cloud VM can be started FROM a
# prebuilt image instead of installed on first boot. This matters whenever
# you cannot build (or even run an installer) on the box itself: the image is
# built once, elsewhere, and the provider just boots it.
#
# `systemd-repart` builds the image without KVM/QEMU — it assembles a GPT
# disk image directly on the build machine (populate partitions, write a
# filesystem, done). That is what makes this usable on a build host that has
# no virtualization available, and it is why this is the mechanism to reach
# for instead of a `disko` + real-VM-install pipeline when you can't build
# on-box.
#
# Layout produced (GPT, two partitions):
#   - an ESP (`vfat`) carrying `systemd-boot` with a single type-1 (BLS) boot
#     entry — NOT a Unified Kernel Image; kernel and initrd are installed as
#     separate files under `/EFI/nixos`, exactly like a normal systemd-boot
#     install would leave them;
#   - a root partition (`btrfs`) with `/@root` `/@nix` `/@log` subvolumes and
#     the toplevel's closure copied straight in under `/@nix` (`nixStorePrefix
#     = "/@nix/store"` — do NOT change the trailing segment to anything other
#     than `store`, or `init=` in the kernel command line stops resolving and
#     you get a silent early-boot hang with no serial output to explain it),
#     PLUS Nix's own state under `/@nix/var/nix`: the store database and
#     generation 1 of the `system` profile. See "Nix state" below — an image
#     without those two is bootable and undeployable.
#
# The root partition is tagged with systemd-repart's `Type = "linux-generic"`,
# which sets the GPT "grow this filesystem" attribute (bit 59). On first boot,
# systemd's own generic generators expand the filesystem to fill whatever the
# real disk turns out to be — so the image only needs to be big enough to
# HOLD its own closure at bake time; it does not need to match the target
# disk size, and no cloud-init `growpart` step is required for this part.
#
# ============================================================================
# HONESTY NOTE — read this before using this on a real provider
# ============================================================================
# This module gives you the generic repart bake: ESP + systemd-boot + btrfs
# root, parameterized. It is a STARTING POINT, not a turnkey per-provider
# image. Every real cloud provider (GCE, Hetzner, Vultr, Oracle, AWS, ...)
# needs a handful of small, provider-specific tweaks on top of this that this
# module deliberately does NOT bake in, because they vary and because baking
# one provider's answer in here would make this module wrong for everyone
# else:
#
#   - Serial console: some providers only expose serial (no framebuffer/VNC)
#     and need a kernel console on e.g. ttyS0 to show you anything during
#     boot. This repo's own `nixvps.lifeline.console` module sets
#     `boot.kernelParams` for you:
#       nixvps.lifeline.console = { enable = true; device = "ttyS0"; baud = 115200; };
#     wire it into the SAME host config that enables imageBake. Setting it
#     by hand instead is just:
#       boot.kernelParams = [ "console=ttyS0,115200n8" "console=tty0" ];
#
#   - Disk growth / cloud-init: the root FILESYSTEM auto-grows via the GPT
#     attribute described above, but the underlying PARTITION TABLE only
#     grows to fill the disk if something re-partitions at boot (`growpart`,
#     `cloud-init`'s `growpart` module, or an equivalent). If your provider's
#     disk is bigger than the baked image and you want that space usable,
#     you need that step — this module does not assume cloud-init exists,
#     because plenty of tiny/cheap VMs boot from a custom image with none.
#
#   - Upload / import mechanics: how the built `.raw`(`.zst`) file actually
#     becomes a bootable disk on your provider — a custom-image API upload, a
#     snapshot-import pipeline, or a raw `dd` onto a rescue-mode disk — is
#     entirely provider-specific and outside this module's scope.
#
#   - Sector size / disk backend quirks: `sectorSize = 512` below is the safe
#     default for UEFI/OVMF boot across virtually every hypervisor. A handful
#     of disk backends care about this; if your image doesn't boot and you've
#     ruled out everything else, this is worth a second look.
#
# In short: this module answers "how do I get systemd-repart to produce a
# bootable image at all", not "how do I ship that image to provider X". The
# per-provider glue is the consumer's job.
#
# OWNERSHIP STATUS: the direct ESP/systemd-boot construction below predates
# nixboot's extracted boot-artifact contract. It is still the implementation
# this option evaluates today. The target boundary is for nixvps to describe
# the constrained provider guest and disk payload, nixboot to own the primary
# boot artifact, and nixdeploy to own upload, registration and reimage. This
# note does not claim that source migration is already complete.
# ============================================================================

{ config, lib, pkgs, modulesPath, ... }:

let
  cfg = config.nixvps.imageBake;

  toplevel = config.system.build.toplevel;
  sdcfg = config.boot.loader.systemd-boot;
  efiArch = pkgs.stdenv.hostPlatform.efiArch;
  systemd = pkgs.systemd;

  timeout =
    if config.boot.loader.timeout == null then "menu-force"
    else toString config.boot.loader.timeout;

  # Two views of one directory. `/nix` is where Nix looks at RUNTIME; `/@nix` is
  # where the same contents have to be WRITTEN while the image is assembled,
  # because that subvolume is what gets mounted at /nix once the box boots. Both
  # image-side paths hang off the one subvolume constant rather than repeating
  # the prefix at each use — they have to agree, and getting the store one wrong
  # is the silent early-boot hang documented in the module header.
  runtimeNixStateDir = "/nix/var/nix";
  nixSubvolume = "/@nix";
  nixStorePrefix = "${nixSubvolume}/store";
  imageNixStateDir = "${nixSubvolume}/var/nix";

  # The same closure `image.repart` copies into the partition. Calling
  # `closureInfo` with identical arguments yields the identical derivation, so
  # this is the same build the partition already pays for, not a second one.
  closure = pkgs.closureInfo { rootPaths = [ toplevel ]; };

  # ---------------------------------------------------------------------------
  # Nix state: the store DATABASE and the `system` profile
  # ---------------------------------------------------------------------------
  # `image.repart` copies a closure into the image as plain files and knows
  # nothing about Nix. Nix's own view of what it owns lives in /nix/var/nix —
  # an sqlite database of valid paths, and the `system` profile naming the
  # current generation. Ship the store without them and the box boots perfectly
  # (every binary is on disk, `init=` resolves, PID 1 runs) while Nix believes
  # it owns NOTHING. Three consequences, worst first:
  #
  #   1. Nothing can be deployed to the box again. An incremental deploy asks
  #      the node what it already has; the answer is empty, so a one-line change
  #      measures as the entire closure, blows whatever in-place delivery
  #      ceiling the node enforces, and gets routed to a reimage — which lays
  #      down the same empty database. A closed loop.
  #   2. There is no rollback. `nixos-rebuild --rollback` and deploy-rs'
  #      autoRollback/magicRollback both need a PREVIOUS generation in the
  #      `system` profile. Without the profile the safety net is configured and
  #      absent at the same time, which is the worst of the two states.
  #   3. Garbage collection is a loaded gun. Nix treats store entries missing
  #      from the database as garbage, so a scheduled `nix-collect-garbage` can
  #      delete the running system out from under a live workload.
  #
  # This is done at BUILD time, in this derivation, and not by a first-boot
  # unit that runs `nix-store --load-db < /nix/store/nix-path-registration`.
  # Upstream's installer images (iso-image.nix, netboot.nix) do use that
  # first-boot unit, but they have to: their store is on read-only media under
  # a tmpfs overlay, so there is nowhere to put a database until the box is
  # running. Here the root filesystem is a real writable btrfs being assembled
  # offline, so the database can simply be IN it — which means the image is
  # either correct before it is ever uploaded, or it fails to build. A first-boot
  # unit converts a build error into a runtime one on a box whose only recovery
  # path is the very reimage that produced it.
  nixState = pkgs.runCommand "${cfg.imageName}-nix-state"
    {
      # `config.nix.package` on purpose, not `pkgs.nix`: the database is written
      # by the exact Nix that will later read it, so its schema version cannot
      # disagree with the running system's.
      nativeBuildInputs = [ config.nix.package pkgs.sqlite ];
    }
    ''
      set -euo pipefail

      # NIX_STATE_DIR redirects only Nix's BOOKKEEPING into the build directory.
      # The store directory is left alone at /nix/store, so the paths recorded
      # in the database are the paths the booted system will actually see. The
      # closure is present in the sandbox (closureInfo's output references every
      # path in it), so this registers metadata for files that really are there
      # rather than inventing entries.
      export HOME="$TMPDIR"
      export NIX_STATE_DIR="$TMPDIR/state"
      install -d -m 0755 "$NIX_STATE_DIR"
      nix-store --load-db < ${closure}/registration

      # `--load-db` stamps registrationTime from the wall clock, which would
      # make two bakes of one identical closure produce different image bytes.
      # Flatten it to SOURCE_DATE_EPOCH. The checkpoint then folds the
      # write-ahead log back into the database file, so the single file copied
      # out below really is the whole database and not most of it.
      sqlite3 "$NIX_STATE_DIR/db/db.sqlite" \
        "UPDATE ValidPaths SET registrationTime = $SOURCE_DATE_EPOCH; PRAGMA wal_checkpoint(TRUNCATE);"

      # 0444 is not a preference, it is what these files WILL be: Nix strips
      # every write bit when it seals an output, so writing 0644 here would only
      # misdescribe the result. It is also not the mode that reaches the image.
      # systemd-repart copies a source's mode along with its contents, but
      # nixpkgs runs it under `fakeroot`, whose chmod wrapper ORs the owner-write
      # bit back in — so a 0444 source lands as 0644 and a 0555 directory as
      # 0755, which is exactly what a normal NixOS install carries. Measured on
      # the built artifact, not assumed; if that ever stops holding, the database
      # is still root-owned and the Nix daemon is root, so it stays writable.
      install -D -m 0444 "$NIX_STATE_DIR/db/db.sqlite" "$out/db/db.sqlite"
      install -D -m 0444 "$NIX_STATE_DIR/db/schema" "$out/db/schema"

      # Generation 1 of the system profile, in the shape `nix-env --set` leaves
      # behind: an absolute link into the store per generation, and a RELATIVE
      # `system` link naming the current one. `nix-env`'s own generation
      # bookkeeping is nothing but this naming convention, so writing the links
      # directly gives a profile the next `--set` extends and `--rollback`
      # returns to. Everything under /nix/var/nix/profiles is also a GC root in
      # its own right, which is what stops consequence 3 above.
      install -d -m 0755 "$out/profiles"
      ln -s ${toplevel} "$out/profiles/system-1-link"
      ln -s system-1-link "$out/profiles/system"
    '';

  kernelSrc = "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}";
  initrdSrc = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
  kernelEfiName = "${baseNameOf config.system.build.kernel}-${config.system.boot.loader.kernelFile}.efi";
  initrdEfiName = "${baseNameOf config.system.build.initialRamdisk}-${config.system.boot.loader.initrdFile}.efi";
  kernelParams = lib.concatStringsSep " " ([ "init=${toplevel}/init" ] ++ config.boot.kernelParams);

  # A single type-1 (BLS) boot entry naming "generation 1" — the image is a
  # fresh bake, so there is exactly one generation to boot into. Subsequent
  # generations/updates are the consumer's own update mechanism's problem
  # (e.g. nixvps' own `pull-update.nix`, or plain `nixos-rebuild switch`),
  # not this module's.
  bootEntry = ''
    title ${config.system.nixos.distroName}
    sort-key nixos
    version Generation 1 ${config.system.nixos.distroName} ${config.system.nixos.label} (Linux ${config.boot.kernelPackages.kernel.version})
    linux /EFI/nixos/${kernelEfiName}
    initrd /EFI/nixos/${initrdEfiName}
    options ${kernelParams}
  '';

  loaderConf = ''
    timeout ${timeout}
    default nixos-generation-1.conf
    ${lib.optionalString (!sdcfg.editor) "editor 0"}
    console-mode ${sdcfg.consoleMode}
  '';

  # The ESP's full file tree, built once as its own derivation and then
  # copied into the partition wholesale by `image.repart`. Installs
  # systemd-boot at both its normal path and the fallback `/EFI/BOOT/BOOT*.EFI`
  # path (so the image boots even on firmware that ignores NVRAM boot entries
  # and just runs the fallback loader — the common case for a freshly
  # attached cloud disk with no boot entry registered yet).
  espTree = pkgs.runCommand "${cfg.imageName}-esp-tree" { } ''
    set -euo pipefail
    esp="$out"
    install -Dm0444 ${systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi "$esp/EFI/systemd/systemd-boot${efiArch}.efi"
    install -Dm0444 ${systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi "$esp/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI"
    install -Dm0444 ${pkgs.writeText "loader.conf" loaderConf} "$esp/loader/loader.conf"
    install -Dm0444 ${pkgs.writeText "nixos-generation-1.conf" bootEntry} "$esp/loader/entries/nixos-generation-1.conf"
    # systemd-boot expects a `type1` marker so it treats /loader/entries as BLS.
    printf 'type1\n' > "$esp/loader/entries.srel"
    install -Dm0444 ${kernelSrc} "$esp/EFI/nixos/${kernelEfiName}"
    install -Dm0444 ${initrdSrc} "$esp/EFI/nixos/${initrdEfiName}"
  '';
in
{
  imports = [ (modulesPath + "/image/repart.nix") ];

  options.nixvps.imageBake = {
    enable = lib.mkEnableOption "baking a bootable disk image for this system with systemd-repart";

    imageName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = ''
        Base name of the built image file (`<imageName>.raw` or
        `<imageName>.raw.zst`, per `format`). Purely a filename; carries no
        other meaning.
      '';
    };

    format = lib.mkOption {
      type = lib.types.enum [ "raw" "raw.zst" ];
      default = "raw";
      description = ''
        Output format of the built image.

        `"raw"` is the uncompressed disk image, byte-for-byte what a real
        disk should contain — the right choice when you `dd` it directly
        onto a target disk, or your provider's upload path accepts raw disk
        images directly.

        `"raw.zst"` is the same image compressed with zstd as a separate
        build output — worth it when the transfer/upload path is the
        bottleneck (a NixOS closure compresses well) and something on the
        receiving end decompresses it (or accepts a compressed custom-image
        upload directly). It is still a raw disk image once decompressed —
        this is transport compression, not a different disk format.
      '';
    };

    compressionAlgorithm = lib.mkOption {
      type = lib.types.enum [ "zstd" "xz" "zstd-seekable" ];
      default = "zstd";
      description = ''
        Compression algorithm used when `format = "raw.zst"`. Ignored
        otherwise. `zstd` is the fastest to both produce and later
        decompress; `xz` compresses smaller at the cost of more CPU time on
        both ends; `zstd-seekable` trades a little ratio for being seekable
        (useful if something needs to read the compressed image back
        partition-by-partition rather than as one decompress-then-use blob).
      '';
    };

    sectorSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 512;
      example = 4096;
      description = ''
        Sector size of the produced disk image, in bytes (must be a power of
        two between 512 and 4096). 512 is the safe default for UEFI/OVMF boot
        across virtually every hypervisor and cloud disk backend; raise it
        only if your specific provider's disk backend requires 4096 and you
        have confirmed the image still boots that way.
      '';
    };

    imageSize = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "^([0-9]+[KMGTP]?|auto)$");
      default = null;
      example = "10G";
      description = ''
        Total size of the produced disk image, passed straight through to
        `image.repart.imageSize` (a `systemd-repart` size string: bytes with
        an optional K/M/G/T suffix, or `"auto"`).

        Left `null` (the default) leaves `image.repart.imageSize` at ITS OWN
        default, `"auto"` -- systemd-repart sizes the image to the minimum
        needed to hold the declared partitions, and the root filesystem then
        grows to fill whatever real disk it lands on at first boot (see the
        module header).

        Set this explicitly when the image must come out at a FIXED size up
        front instead -- e.g. because it is `dd`'d byte-for-byte onto a
        target disk of that exact size and nothing at boot performs a
        partition-table grow, so the baked image size IS the final disk
        layout.
      '';
    };

    espSize = lib.mkOption {
      type = lib.types.str;
      default = "512M";
      example = "256M";
      description = ''
        Fixed size of the ESP (`systemd-repart` size string: bytes with an
        optional K/M/G/T suffix). Used as both the minimum and maximum size —
        the ESP does not grow at runtime, so make it generously bigger than
        the systemd-boot binary + one kernel/initrd pair if you expect to
        keep multiple kernel generations on it later.
      '';
    };

    rootSize = lib.mkOption {
      type = lib.types.str;
      default = "2G";
      example = "4G";
      description = ''
        Minimum size of the root partition at bake time (`SizeMinBytes`,
        `systemd-repart` size string). This is a FLOOR, not a cap: if the
        toplevel's actual closure needs more room than this, `systemd-repart`
        makes the partition bigger regardless. It is also not the final size
        on real hardware — the root filesystem auto-grows to fill the real
        disk on first boot (see the module header); this only needs to be
        big enough to hold the baked closure.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    image.repart = lib.mkMerge [
      {
        name = cfg.imageName;
        sectorSize = cfg.sectorSize;

        compression = {
          enable = cfg.format == "raw.zst";
          algorithm = cfg.compressionAlgorithm;
        };

        partitions = {
          "10-esp" = {
            contents."/".source = espTree;
            repartConfig = {
              Type = "esp";
              Format = "vfat";
              Label = "disk-root-ESP";
              SizeMinBytes = cfg.espSize;
              SizeMaxBytes = cfg.espSize;
            };
          };

          "20-root" = {
            storePaths = [ toplevel ];
            # @nix is mounted at /nix at runtime, so the store must live in the
            # @nix subvolume at `store/` (-> /nix/store). nixStorePrefix
            # REPLACES the default `/nix/store`, so it must be `/@nix/store` —
            # NOT `/@nix/nix/store` (which would put the store at
            # /nix/nix/store and make `init=` above unresolvable: a silent
            # early-boot hang with no serial output to explain it).
            inherit nixStorePrefix;

            # Nix's state next to the store it describes — see "Nix state" in
            # the let block above for why an image without this is bootable and
            # undeployable.
            #
            # The two database files are listed individually rather than as one
            # `<subvolume>/var/nix/db` directory copy, because systemd-repart creates
            # the PARENT of a copied file with mode 0755 while a copied
            # DIRECTORY inherits its source's mode — and a source in the Nix
            # store is 0555 by construction. Listing the files gets
            # /nix/var/nix/db right for free.
            #
            # The profile, in contrast, MUST be copied as a directory:
            # systemd-repart resolves a `contents` source through symlinks, so
            # naming `profiles/system` directly would resolve to the toplevel
            # and copy the entire system closure a second time, as a directory,
            # where a symlink belongs. Copying the enclosing directory keeps
            # both links as links.
            contents = {
              "${imageNixStateDir}/db/db.sqlite".source = "${nixState}/db/db.sqlite";
              "${imageNixStateDir}/db/schema".source = "${nixState}/db/schema";
              "${imageNixStateDir}/profiles".source = "${nixState}/profiles";
            };
            repartConfig = {
              # `Type = "linux-generic"` sets the root-<arch> partition type
              # GUID plus the GPT "grow this filesystem" attribute (bit 59) —
              # this is what makes the root filesystem auto-expand to the real
              # disk's size on first boot. It does not affect how partitions
              # are found at runtime (that happens by partition LABEL).
              Type = "linux-generic";
              Format = "btrfs";
              Label = "disk-root-root";
              Subvolumes = [ "/@root" "/@nix" "/@log" ];
              MakeDirectories = [ "/@root" "/@nix" "/@log" ];
              DefaultSubvolume = "/@root";
              SizeMinBytes = cfg.rootSize;
            };
          };
        };
      }
      (lib.optionalAttrs (cfg.imageSize != null) {
        imageSize = cfg.imageSize;
      })
    ];

    # The defect this module's Nix-state section exists to prevent was invisible
    # for weeks: an unregistered store looks like a perfectly healthy box until
    # the day you try to deploy to it or the collector runs. Prove the invariant
    # on every boot instead of assuming it, and fail visibly when it does not
    # hold — a running system its own package manager cannot account for is not
    # a healthy system, whatever else is green.
    #
    # This is a check, never a repair: silently re-registering here would turn a
    # broken image into a working box and let the broken image survive.
    systemd.services.nixvps-store-registration = {
      description = "Prove the Nix store database and system profile describe this system";
      wantedBy = [ "multi-user.target" ];
      # Ordering only, deliberately not `requires`: /nix rides on the root
      # filesystem the initrd already mounted, so a local-fs.target failure
      # elsewhere must not be reported as a store-registration failure. This
      # unit has exactly one meaning and should never acquire a second one.
      after = [ "local-fs.target" ];
      unitConfig.ConditionPathExists = "/run/current-system";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ config.nix.package ];
      # `--check-validity` is the load-bearing choice here, and the reason is the
      # exact shape the original defect wore. On a system with an empty database
      # `nix-store --query --requisites <path>` prints NOTHING and exits 0: it
      # answers "that closure contains no paths" where the truth is "I have never
      # heard of that path". Every check built on `--requisites` therefore PASSES
      # on a broken box — which is how this went unnoticed until a deploy
      # measured a 3 KiB change as five gigabytes. `--check-validity` asks the
      # question directly and fails when the answer is no.
      #
      # What this proves: a generation exists, and both it and the running system
      # are paths Nix accounts for. What it deliberately does NOT attempt: an
      # audit of the whole closure. A database truncated part-way through has no
      # runtime tell — Nix computes `--requisites` FROM the database, so a
      # database that has forgotten half the closure reports a small closure, not
      # an error, and the only way to call that wrong is to compare against an
      # expected path count. The bake cannot supply one that stays true: the
      # image's own generation is exactly what `nix-collect-garbage
      # --delete-older-than` is supposed to remove later, so a baked-in
      # expectation would turn into a permanent false alarm on a healthy node.
      # Better a check with an honest boundary than one that cries wolf.
      script = ''
        fail() {
          echo "nixvps: $*" >&2
          echo "nixvps: this system's Nix store is not registered with Nix. Deploys will" >&2
          echo "nixvps: re-send the whole closure instead of a delta, rollback has no" >&2
          echo "nixvps: generation to return to, and garbage collection considers the" >&2
          echo "nixvps: running system garbage." >&2
          exit 1
        }

        profile=${runtimeNixStateDir}/profiles/system
        [ -L "$profile" ] || fail "$profile is not a symlink — there are no generations"

        profileTarget=$(readlink -f "$profile") \
          || fail "$profile does not resolve"
        nix-store --check-validity "$profileTarget" \
          || fail "the system profile names $profileTarget, which Nix does not know"

        system=$(readlink -f /run/current-system) \
          || fail "/run/current-system does not resolve"
        nix-store --check-validity "$system" \
          || fail "the running system is $system, which Nix does not know"
      '';
    };
  };
}
