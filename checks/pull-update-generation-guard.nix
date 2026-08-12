{ pkgs }:

pkgs.runCommand "pull-update-generation-guard-check" { } ''
  set -eu
  . ${../lib/pull-update-generation-guard.sh}

  PROFILE="$TMPDIR/profiles/system"
  mkdir -p "$TMPDIR/profiles"

  current=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-test-current
  older=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nixos-system-test-older
  newer=/nix/store/cccccccccccccccccccccccccccccccc-nixos-system-test-newer
  unknown=/nix/store/dddddddddddddddddddddddddddddddd-nixos-system-test-unknown

  # The same closure can occur more than once after a rollback. The newest
  # generation for each path is the only ordering that reflects profile state.
  ln -s "$current" "$PROFILE-3-link"
  ln -s "$older" "$PROFILE-4-link"
  ln -s "$current" "$PROFILE-5-link"
  ln -s "$newer" "$PROFILE-6-link"

  is_known_generation_rollback "$current" "$older"
  test "$KNOWN_CURRENT_GENERATION" = 5
  test "$KNOWN_TARGET_GENERATION" = 4

  if is_known_generation_rollback "$current" "$newer"; then
    echo "newer generation was misclassified as a rollback" >&2
    exit 1
  fi

  if is_known_generation_rollback "$current" "$unknown"; then
    echo "previously unseen target was misclassified as a rollback" >&2
    exit 1
  fi

  touch "$out"
''
