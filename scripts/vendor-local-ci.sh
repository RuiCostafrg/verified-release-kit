#!/usr/bin/env bash
# Copy the shared local CI runner into a repository, or check that the copies
# in a set of repositories still match this one.
#
#   scripts/vendor-local-ci.sh install <repo>      write <repo>/scripts/local-ci.sh
#                                                  and <repo>/scripts/local-ci.sha256
#   scripts/vendor-local-ci.sh check <repo>...     exit non-zero if any copy differs
#
# Neither command commits, pushes or contacts GitHub. `install` only writes the
# two files; review and commit them in the target repository yourself.
set -euo pipefail

here="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"
source_runner="$here/local-ci.sh"

usage() { sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

[ $# -ge 2 ] || { usage >&2; exit 2; }
command="$1"; shift

source_sum="$(sha256sum "$source_runner" | cut -d' ' -f1)"
source_version="$(sed -n 's/^LOCAL_CI_RUNNER_VERSION=//p' "$source_runner")"
checksum_line="$source_sum  local-ci.sh"

case "$command" in
  install)
    [ $# -eq 1 ] || { usage >&2; exit 2; }
    target="$1/scripts"
    [ -d "$1/.git" ] || [ -f "$1/.git" ] || { echo "not a git work tree: $1" >&2; exit 1; }
    mkdir -p "$target"
    cp "$source_runner" "$target/local-ci.sh"
    chmod +x "$target/local-ci.sh"
    printf '%s\n' "$checksum_line" > "$target/local-ci.sha256"
    echo "installed runner $source_version ($source_sum) into $target"
    [ -f "$target/local-ci.stages.sh" ] || echo "next: write $target/local-ci.stages.sh (see docs/local-ci.md)"
    ;;
  check)
    status=0
    for repo in "$@"; do
      copy="$repo/scripts/local-ci.sh"
      checksum="$repo/scripts/local-ci.sha256"
      if [ ! -f "$copy" ]; then
        printf 'MISSING  %s\n' "$repo"; status=1
      elif cmp -s "$source_runner" "$copy" && [ -x "$copy" ] \
           && [ -f "$checksum" ] && [ "$(cat "$checksum")" = "$checksum_line" ]; then
        printf 'in sync  %s (runner %s)\n' "$repo" "$source_version"
      else
        printf 'DIFFERS  %s (has runner %s, kit has %s)\n' "$repo" \
          "$(sed -n 's/^LOCAL_CI_RUNNER_VERSION=//p' "$copy" | head -n1 | grep . || echo 'no version: not the shared runner')" \
          "$source_version"
        status=1
      fi
    done
    exit "$status"
    ;;
  *) usage >&2; exit 2 ;;
esac
