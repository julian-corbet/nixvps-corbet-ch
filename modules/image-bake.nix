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
#     you get a silent early-boot hang with no serial output to explain it).
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
    image.repart = {
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
          nixStorePrefix = "/@nix/store";
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
    };
  };
}
