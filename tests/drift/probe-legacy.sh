#!/usr/bin/env bash
# Runs every legacy copy of scripts/local-ci.sh, and the shared runner, through
# the same failure scenarios and prints which ones each copy gets wrong.
#
#   tests/drift/probe-legacy.sh --clones DIR --gh-signoff FILE [--repeat N] [PROBE...]
#
#   --clones DIR       directory holding read-only clones named after each repo
#   --gh-signoff FILE  the upstream gh-signoff script (basecamp/gh-signoff)
#   --repeat N         runs for the timing-dependent probes (default 5)
#
# How it works, so the results can be trusted or challenged:
#   - Each run gets a fresh git repository with a local bare `origin`, pushed,
#     so gh-signoff's own "is it pushed / is the tree clean" logic is real.
#   - `gh` on PATH is a fake. `gh extension list` reports gh-signoff installed;
#     `gh signoff …` runs the real upstream gh-signoff script; every `gh api`
#     call is recorded and answered locally. Nothing reaches GitHub.
#   - For a legacy copy, one line is inserted before its "# ── runner" marker
#     to source a probe stage file that replaces the repo's stages (and its
#     prepare(), if any) with instrumented stubs. Everything else, the whole
#     runner core, runs unmodified. --help runs the unmodified file.
#   - The shared runner gets the same stubs through its stage file.
#   - Two stage-level probes run a repository's real stage with stub tools.
#
# It reads the clones and writes only under a temporary directory.
set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
kit_runner="$here/../../scripts/local-ci.sh"
CLONES="" GH_SIGNOFF="" REPEAT=5 ONLY=()
while [ $# -gt 0 ]; do
  case "$1" in
    --clones) CLONES="$2"; shift 2 ;;
    --gh-signoff) GH_SIGNOFF="$2"; shift 2 ;;
    --repeat) REPEAT="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ONLY+=("$1"); shift ;;
  esac
done
[ -d "$CLONES" ] && [ -f "$GH_SIGNOFF" ] || { sed -n '4,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
CLONES="$(cd "$CLONES" && pwd)"; GH_SIGNOFF="$(readlink -f "$GH_SIGNOFF")"

COPIES=(pi-android-screenshots pi-droid fantastic-pi-mobile forge-ios forge-android dotnet-crap homebrew-tap typescript-crap shared)
REAL_GIT="$(command -v git)"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=probe GIT_AUTHOR_EMAIL=probe@example.invalid
export GIT_COMMITTER_NAME=probe GIT_COMMITTER_EMAIL=probe@example.invalid
unset CDPATH

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin"

# ── fakes ────────────────────────────────────────────────────────────────────

cat > "$ROOT/bin/gh" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FAKE_GH_LOG"
case "\$1" in
  extension)
    printf 'gh signoff\tbasecamp/gh-signoff\tv0.4.1\n'
    if [ -n "\${FAKE_GH_MANY_EXTENSIONS:-}" ]; then
      for i in \$(seq 1 6000); do printf 'gh filler-%s\texample/gh-filler-%s-with-a-long-name\tv1.0.0\n' "\$i" "\$i"; done
    fi ;;
  signoff) shift; exec bash "$GH_SIGNOFF" "\$@" ;;
  api)
    case "\$*" in
      *"--method POST"*statuses/*)
        [ -z "\${FAKE_GH_POST_FAILS:-}" ] || { echo "HTTP 422: No commit found for SHA" >&2; exit 1; }
        echo '{}' ;;
      *git/blobs/*) printf '%s\n' "\${FAKE_BLOB_B64:-}" ;;
      *) echo "fake gh: no answer for: gh \$*" >&2; exit 1 ;;
    esac ;;
  *) echo "fake gh: unexpected: gh \$*" >&2; exit 64 ;;
esac
FAKE
cat > "$ROOT/bin/git" <<FAKE
#!/usr/bin/env bash
if [ -n "\${BREAK_GIT_STATUS:-}" ] && [ -e "\$BREAK_GIT_STATUS" ]; then
  for a in "\$@"; do [ "\$a" != status ] || { echo "fatal: simulated git status failure" >&2; exit 128; }; done
fi
exec "$REAL_GIT" "\$@"
FAKE
chmod +x "$ROOT/bin/gh" "$ROOT/bin/git"

cat > "$ROOT/probe-lib.sh" <<'LIB'
probe_stage() {
  pwd > "$MARK/cwd"
  touch "$MARK/ran.$1"
  case "${PROBE_ACTION:-}" in
    commit-push) git commit -q --allow-empty -m "landed mid-stage" && git push -q origin HEAD:main ;;
    dirty) echo generated > left-behind.txt ;;
    break-status) touch "$BREAK_GIT_STATUS" ;;
  esac
}
LIB
cat > "$ROOT/legacy-stages.sh" <<'STAGES'
. "$PROBE_LIB"
for __s in "${AVAILABLE_STAGES[@]}" install; do eval "stage_${__s}() { probe_stage ${__s}; }"; done
if declare -F prepare >/dev/null; then prepare() { touch "$MARK/prepare"; }; fi
STAGES

# ── fixtures ─────────────────────────────────────────────────────────────────

legacy_script() { printf '%s/%s/scripts/local-ci.sh' "$CLONES" "$1"; }

has_prepare() { [ "$1" = shared ] || grep -q '^prepare()' "$(legacy_script "$1")"; }

# make_repo COPY DIR [stub|real|original]: a pushed repository holding COPY.
make_repo() {
  local copy="$1" dir="$2" mode="${3:-stub}"
  mkdir -p "$dir/scripts"
  "$REAL_GIT" init -q -b main "$dir"
  "$REAL_GIT" -C "$dir" config user.name probe
  printf 'tracked\n' > "$dir/tracked.txt"
  if [ "$copy" = shared ]; then
    cp "$kit_runner" "$dir/scripts/local-ci.sh"
    cat > "$dir/scripts/local-ci.stages.sh" <<'STAGES'
LOCAL_CI_STAGES=(tests lint install)
LOCAL_CI_DEFAULT_STAGES=(tests lint)
. "$PROBE_LIB"
prepare()       { touch "$MARK/prepare"; }
stage_tests()   { probe_stage tests; }
stage_lint()    { probe_stage lint; }
stage_install() { probe_stage install; }
STAGES
  elif [ "$mode" = original ]; then
    cp "$(legacy_script "$copy")" "$dir/scripts/local-ci.sh"
  else
    awk -v hook="$mode" '
      /^# ── runner/ && !done {
        if (hook == "stub") print "[ -z \"${PROBE_STAGES_FILE:-}\" ] || . \"$PROBE_STAGES_FILE\"  # drift probe"
        done = 1
      }
      { print }' "$(legacy_script "$copy")" > "$dir/scripts/local-ci.sh"
  fi
  [ "$copy" = shared ] || [ ! -f "$CLONES/$copy/.gitignore" ] || cp "$CLONES/$copy/.gitignore" "$dir/.gitignore"
  chmod +x "$dir/scripts/local-ci.sh"
  "$REAL_GIT" -C "$dir" add -A
  "$REAL_GIT" -C "$dir" commit -q -m initial
  "$REAL_GIT" init -q --bare "$dir.origin.git"
  "$REAL_GIT" -C "$dir" remote add origin "$dir.origin.git"
  "$REAL_GIT" -C "$dir" push -q -u origin main
}

# run_case: runs $W/repo/scripts/local-ci.sh from $CWD with extra env and args.
run_case() {
  OUT="$(cd "${CWD:-$W/repo}" && env PATH="$ROOT/bin:$PATH" FAKE_GH_LOG="$W/gh.log" \
    MARK="$W/mark" PROBE_LIB="$ROOT/probe-lib.sh" PROBE_STAGES_FILE="$ROOT/legacy-stages.sh" \
    BREAK_GIT_STATUS="$W/break" "$@" 2>&1)"
  RC=$?
}

# Probes run inside command substitutions, so a counter would not survive;
# mktemp gives every case its own directory.
new_case() {
  W="$(mktemp -d "$ROOT/case.XXXXXX")"; mkdir -p "$W/mark"; : > "$W/gh.log"; CWD=""
}

ran_any()       { compgen -G "$W/mark/ran.*" >/dev/null; }
posted()        { grep -c -- "-f state=$1" "$W/gh.log"; }
posted_shas()   { sed -n "s#.*statuses/\([0-9a-f]\{40\}\) -f state=$1.*#\1#p" "$W/gh.log" | sort -u; }
script()        { printf '%s/repo/scripts/local-ci.sh' "$W"; }

# ── probes: each prints one short cell and sets DETAIL ───────────────────────

probe_help_prints_code() {
  new_case; make_repo "$1" "$W/repo" original
  run_case "$(script)" --help
  if grep -qE '^(set -euo pipefail|AVAILABLE_STAGES=|DEFAULT_STAGES=)' <<<"$OUT"; then
    echo "BUG"; DETAIL="$(grep -cv '^#' <<<"$OUT") non-comment line(s): $(grep -v '^#' <<<"$OUT" | grep . | head -2 | tr '\n' '|')"
  else echo "ok"; fi
}

probe_prepare_before_stage_validation() {
  has_prepare "$1" || { echo "n/a"; return; }
  new_case; make_repo "$1" "$W/repo"
  run_case "$(script)" --no-signoff no-such-stage
  if [ -e "$W/mark/prepare" ]; then echo "BUG"; DETAIL="prepare() ran before 'unknown stage' was reported"
  else echo "ok"; fi
}

probe_dirty_tree_signed_off() {
  new_case; make_repo "$1" "$W/repo"
  echo edit >> "$W/repo/tracked.txt"
  run_case "$(script)"
  if ran_any; then
    echo "BUG"; DETAIL="stages ran on a dirty tree; exit $RC; $(posted success) success status(es) posted"
  else echo "ok"; fi
}

probe_huge_dirty_tree_sigpipe() {
  local silent=0 i
  for i in $(seq 1 "$REPEAT"); do
    new_case; make_repo "$1" "$W/repo"
    ( cd "$W/repo" && for n in $(seq 1 4000); do : > "untracked-file-with-a-deliberately-long-name-$n.txt"; done )
    run_case "$(script)" --no-signoff
    grep -q "uncommitted changes" <<<"$OUT" || silent=$((silent + 1))
  done
  if [ "$silent" -gt 0 ]; then echo "BUG $silent/$REPEAT"; DETAIL="dirty tree reported as clean in $silent of $REPEAT runs (git status | grep -q under pipefail)"
  else echo "ok"; fi
}

probe_hidden_untracked_file() {
  new_case; make_repo "$1" "$W/repo"
  "$REAL_GIT" -C "$W/repo" config status.showUntrackedFiles no
  echo scratch > "$W/repo/untracked.txt"
  run_case "$(script)"
  if [ "$(posted success)" -gt 0 ]; then echo "BUG"; DETAIL="untracked file ignored; $(posted success) success status(es) posted, exit $RC"
  elif ran_any && ! grep -q "uncommitted" <<<"$OUT"; then echo "BUG"; DETAIL="untracked file ignored; stages ran, exit $RC"
  else echo "ok"; fi
}

probe_git_status_fails_before_run() {
  new_case; make_repo "$1" "$W/repo"
  : > "$W/break"
  run_case "$(script)"
  if ran_any; then echo "BUG"; DETAIL="failing git status read as clean; stages ran; exit $RC; $(posted success) success posted"
  else echo "ok"; fi
}

probe_git_status_fails_after_stage() {
  new_case; make_repo "$1" "$W/repo"
  run_case PROBE_ACTION=break-status "$(script)"
  if [ "$(posted success)" -gt 0 ]; then echo "BUG"; DETAIL="git status failed after the stage; $(posted success) success posted anyway, exit $RC"
  elif [ "$RC" -eq 0 ]; then echo "BUG"; DETAIL="git status failed after the stage; nothing posted but exit 0"
  else echo "ok"; fi
}

probe_commit_pushed_mid_stage() {
  new_case; make_repo "$1" "$W/repo"
  local before; before="$("$REAL_GIT" -C "$W/repo" rev-parse HEAD)"
  run_case PROBE_ACTION=commit-push "$(script)"
  local untested; untested="$(posted_shas success | grep -v "$before" | head -1)"
  if [ -n "$untested" ]; then echo "BUG"; DETAIL="attested ${untested:0:12}, a commit no stage tested; exit $RC"
  elif [ "$(posted success)" -gt 0 ] && [ "$RC" -eq 0 ]; then echo "BUG"; DETAIL="HEAD moved mid-run but the run reported success"
  else echo "ok"; fi
}

probe_tree_changed_mid_stage() {
  new_case; make_repo "$1" "$W/repo"
  run_case PROBE_ACTION=dirty "$(script)"
  if [ "$(posted success)" -gt 0 ]; then echo "BUG"; DETAIL="tree changed mid-stage; $(posted success) success posted"
  elif [ "$RC" -eq 0 ]; then echo "BUG"; DETAIL="tree changed mid-stage; gh-signoff refused, nothing posted, yet exit 0"
  else echo "ok"; fi
}

probe_status_post_fails() {
  new_case; make_repo "$1" "$W/repo"
  run_case FAKE_GH_POST_FAILS=1 "$(script)"
  if [ "$RC" -eq 0 ]; then echo "BUG"; DETAIL="no status could be posted, yet exit 0"
  else echo "ok"; fi
}

probe_run_from_other_repo() {
  new_case; make_repo "$1" "$W/repo"; make_repo "$1" "$W/other"
  "$REAL_GIT" -C "$W/other" commit -q --allow-empty -m other && "$REAL_GIT" -C "$W/other" push -q
  local mine other; mine="$("$REAL_GIT" -C "$W/repo" rev-parse HEAD)"; other="$("$REAL_GIT" -C "$W/other" rev-parse HEAD)"
  CWD="$W/other" run_case "$(script)"
  local cwd; cwd="$(cat "$W/mark/cwd" 2>/dev/null)"
  if posted_shas success | grep -q "$other"; then echo "BUG"; DETAIL="stages ran in the caller's repo and its HEAD ${other:0:12} was attested"
  elif [ -n "$cwd" ] && [ "$cwd" != "$(cd "$W/repo" && pwd -P)" ]; then echo "BUG"; DETAIL="stages ran in $cwd"
  else echo "ok"; fi
}

probe_stage_named_install() {
  new_case; make_repo "$1" "$W/repo"
  run_case "$(script)" install
  if grep -qE 'default_branch|rulesets|repos/:owner/:repo( |$)' "$W/gh.log" || grep -q "failed to get default branch" <<<"$OUT"; then
    echo "BUG"; DETAIL="ran 'gh signoff install' (repository ruleset command) instead of posting signoff/install; exit $RC"
  elif grep -q -- "--commit is only valid" <<<"$OUT" || { [ "$(posted success)" -eq 0 ] && grep -q "could not post" <<<"$OUT"; }; then
    echo "BUG"; DETAIL="gh-signoff refused the status (parsed as its install command); exit $RC"
  elif grep -q "context=signoff/install" "$W/gh.log"; then echo "ok"
  else echo "?"; DETAIL="exit $RC: $(tail -n 2 <<<"$OUT" | tr '\n' '|')"; fi
}

probe_long_extension_list() {
  local bad=0 i
  for i in $(seq 1 "$REPEAT"); do
    new_case; make_repo "$1" "$W/repo"
    run_case FAKE_GH_MANY_EXTENSIONS=1 "$(script)"
    grep -q "extension missing" <<<"$OUT" && bad=$((bad + 1))
  done
  if [ "$bad" -gt 0 ]; then echo "BUG $bad/$REPEAT"; DETAIL="installed gh-signoff reported missing in $bad of $REPEAT runs (fails closed)"
  else echo "ok"; fi
}

PROBES=(help_prints_code prepare_before_stage_validation dirty_tree_signed_off huge_dirty_tree_sigpipe
  hidden_untracked_file git_status_fails_before_run git_status_fails_after_stage commit_pushed_mid_stage
  tree_changed_mid_stage status_post_fails run_from_other_repo stage_named_install long_extension_list)

# ── stage-level probes (real stages, stub tools) ─────────────────────────────

stage_probe_typescript_crap_lint() {
  new_case; make_repo typescript-crap "$W/repo" real
  mkdir -p "$W/tools"
  cat > "$W/tools/cargo" <<'CARGO'
#!/usr/bin/env bash
if [ "$1" = package ]; then echo "error: failed to prepare local package for uploading" >&2; exit 101; fi
exit 0
CARGO
  chmod +x "$W/tools/cargo"
  OUT="$(cd "$W/repo" && env PATH="$W/tools:$ROOT/bin:$PATH" FAKE_GH_LOG="$W/gh.log" scripts/local-ci.sh --no-signoff lint 2>&1)"; RC=$?
  if grep -q "lint passed" <<<"$OUT"; then echo "BUG: lint passed although 'cargo package --list' exited 101 (exit $RC)"
  else echo "ok: lint failed (exit $RC)"; fi
}

stage_probe_forge_android_verify() {
  new_case; make_repo forge-android "$W/repo" real
  local b64 sum; b64="$(printf 'pretend apk bytes' | base64 -w0)"; sum="$(printf 'pretend apk bytes' | sha256sum | cut -d' ' -f1)"
  run_case FAKE_BLOB_B64="$b64" RELEASE_TAG=0.0.2 BLOB_SHA=0123456789abcdef0123456789abcdef01234567 \
    EXPECTED_SHA256="$sum" "$(script)"
  local left; left="$("$REAL_GIT" -C "$W/repo" status --porcelain | tr '\n' ' ')"
  if [ "$RC" -eq 0 ] && [ "$(posted success)" -eq 0 ]; then
    echo "BUG: verify passed, exit 0, but no signoff/verify status was posted; tree after stage: $left"
  else echo "ok: exit $RC, $(posted success) posted; tree after stage: $left"; fi
}

# ── main ─────────────────────────────────────────────────────────────────────

selected=("${PROBES[@]}")
[ ${#ONLY[@]} -eq 0 ] || selected=("${ONLY[@]}")
declare -A cell detail

for p in "${selected[@]}"; do
  case "$p" in stage_probe_*) continue ;; esac
  for c in "${COPIES[@]}"; do
    DETAIL=""
    # One subshell per probe: the cell is its first line, DETAIL follows.
    raw="$("probe_$p" "$c" > "$ROOT/cell"; printf '%s\x1f%s' "$(cat "$ROOT/cell")" "$DETAIL")"
    cell[$p,$c]="${raw%%$'\x1f'*}"; detail[$p,$c]="${raw#*$'\x1f'}"
  done
done

printf '%-36s' "probe"; for c in "${COPIES[@]}"; do printf ' %-12.12s' "$c"; done; printf '\n'
for p in "${selected[@]}"; do
  case "$p" in stage_probe_*) continue ;; esac
  printf '%-36s' "$p"; for c in "${COPIES[@]}"; do printf ' %-12s' "${cell[$p,$c]}"; done; printf '\n'
done
printf '\ndetails\n'
for p in "${selected[@]}"; do
  case "$p" in stage_probe_*) continue ;; esac
  for c in "${COPIES[@]}"; do
    [ -z "${detail[$p,$c]}" ] || printf '  %s / %s: %s\n' "$p" "$c" "${detail[$p,$c]}"
  done
done

if [ ${#ONLY[@]} -eq 0 ] || printf '%s\n' "${ONLY[@]}" | grep -q '^stage_probe_'; then
  printf '\nstage-level probes\n'
  printf '  typescript-crap stage_lint, cargo package --list fails: %s\n' "$(stage_probe_typescript_crap_lint)"
  printf '  forge-android stage_verify, signed-off run: %s\n' "$(stage_probe_forge_android_verify)"
fi
