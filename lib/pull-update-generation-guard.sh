# Shared by pull-update and its behavioral check. PROFILE is the system
# profile base path, normally /nix/var/nix/profiles/system.

latest_profile_generation_for_path() {
  wanted=$1
  latest=

  for link in "$PROFILE"-*-link; do
    [ -L "$link" ] || continue
    generation=${link#"$PROFILE"-}
    generation=${generation%-link}
    case "$generation" in
      ''|*[!0-9]*) continue ;;
    esac

    resolved=$(readlink -f "$link") || continue
    [ "$resolved" = "$wanted" ] || continue
    if [ -z "$latest" ] || [ "$generation" -gt "$latest" ]; then
      latest=$generation
    fi
  done

  printf '%s\n' "$latest"
}

is_known_generation_rollback() {
  current_path=$1
  target_path=$2

  KNOWN_CURRENT_GENERATION=$(latest_profile_generation_for_path "$current_path")
  KNOWN_TARGET_GENERATION=$(latest_profile_generation_for_path "$target_path")

  [ -n "$KNOWN_CURRENT_GENERATION" ] || return 1
  [ -n "$KNOWN_TARGET_GENERATION" ] || return 1
  [ "$KNOWN_TARGET_GENERATION" -lt "$KNOWN_CURRENT_GENERATION" ]
}
