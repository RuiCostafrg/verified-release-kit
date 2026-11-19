#!/usr/bin/env bash
# Tests for scripts/local-ci.sh. Plain bash, real git, a fake `gh` on PATH.
#
#   tests/local-ci.test.sh              run everything
#   tests/local-ci.test.sh PATTERN      run tests whose name contains PATTERN
#   RUNNER=/path/to/local-ci.sh tests/local-ci.test.sh   test another copy
#
# Each test builds a throwaway repository, so nothing here touches a real one
# and nothing reaches GitHub.
set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${RUNNER:-$here/../scripts/local-ci.sh}"
RUNNER="$(readlink -f -- "$RUNNER")"
ONLY="${1:-}"
REAL_GIT="$(command -v git)"
REAL_READLINK="$(command -v readlink)"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
unset CDPATH LOCAL_CI_STAGES_FILE

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

passed=0
failed=0
failures=()
T="" OUT="" RC=0 CURRENT_OK=1

# ── fixtures ─────────────────────────────────────────────────────────────────

# new_repo [dir]: a committed repository with the runner at scripts/local-ci.sh.
# The stage file comes from stdin.
new_repo() {
  local dir="${1:-$T/repo}"
  mkdir -p "$dir/scripts"
  cp "$RUNNER" "$dir/scripts/local-ci.sh"
  chmod +x "$dir/scripts/local-ci.sh"
  cat > "$dir/scripts/local-ci.stages.sh"
  "$REAL_GIT" -C "$dir" init -q -b main
  printf 'tracked\n' > "$dir/tracked.txt"
  "$REAL_GIT" -C "$dir" add -A
  "$REAL_GIT" -C "$dir" commit -q -m initial
}

head_of() { "$REAL_GIT" -C "${1:-$T/repo}" rev-parse HEAD; }

# A fake gh that records every call. FAKE_GH_* variables choose its failures.
install_fake_gh() {
  mkdir -p "$T/bin"
  cat > "$T/bin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "$1 ${2:-}" in
  "extension list")
    [ -z "${FAKE_GH_NO_EXTENSION:-}" ] || exit 0
    printf 'gh signoff\tbasecamp/gh-signoff\tv0.4.1\n'
    if [ -n "${FAKE_GH_MANY_EXTENSIONS:-}" ]; then
      for i in $(seq 1 6000); do printf 'gh filler-%s\texample/gh-filler-%s-with-a-long-name\tv1.0.0\n' "$i" "$i"; done
    fi
    ;;
  "signoff create") [ -z "${FAKE_GH_CREATE_FAILS:-}" ] || { echo "Error: commit is not on any remote" >&2; exit 1; } ;;
  "signoff fail") [ -z "${FAKE_GH_FAIL_FAILS:-}" ] || exit 1 ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 64 ;;
esac
FAKE
  chmod +x "$T/bin/gh"
}

# A git wrapper that fails `git status` while $T/break-git-status exists.
install_breakable_git() {
  mkdir -p "$T/bin"
  cat > "$T/bin/git" <<FAKE
#!/usr/bin/env bash
if [ -e "$T/break-git-status" ]; then
  for arg in "\$@"; do
    if [ "\$arg" = status ]; then echo "fatal: simulated git status failure" >&2; exit 128; fi
  done
fi
exec "$REAL_GIT" "\$@"
FAKE
  chmod +x "$T/bin/git"
}

# run [-C dir] [VAR=value...] -- args: run the repository's runner.
run() {
  local cwd="$T/repo" script="$T/repo/scripts/local-ci.sh" envs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) cwd="$2"; shift 2 ;;
      --script) script="$2"; shift 2 ;;
      --) shift; break ;;
      *=*) envs+=("$1"); shift ;;
      *) break ;;
    esac
  done
  OUT="$(cd "$cwd" && env PATH="$T/bin:$PATH" FAKE_GH_LOG="$T/gh.log" MARK="$T/mark" \
    ${envs[@]+"${envs[@]}"} "$script" "$@" 2>&1)"
  RC=$?
}

gh_log() { [ -f "$T/gh.log" ] && cat "$T/gh.log"; }

# ── assertions ───────────────────────────────────────────────────────────────

_no() { CURRENT_OK=0; printf '    assertion failed: %s\n' "$*"; }
ok_exit()        { [ "$RC" -eq 0 ] || _no "expected exit 0, got $RC"; }
bad_exit()       { [ "$RC" -ne 0 ] || _no "expected a non-zero exit, got 0"; }
out_has()        { [[ "$OUT" == *"$1"* ]] || _no "output lacks: $1"; }
out_lacks()      { [[ "$OUT" != *"$1"* ]] || _no "output unexpectedly has: $1"; }
gh_called()      { gh_log | grep -qxF -- "$1" || _no "gh was not called with: $1"; }
gh_not_called()  { ! gh_log | grep -qF -- "$1" || _no "gh was called with: $1"; }
gh_silent()      { [ ! -s "$T/gh.log" ] || _no "gh was called: $(gh_log | tr '\n' ';')"; }
marked()         { [ -e "$T/mark/$1" ] || _no "expected marker '$1' (the code that writes it did not run)"; }
not_marked()     { [ ! -e "$T/mark/$1" ] || _no "unexpected marker '$1' (code ran that should not have)"; }

t() {
  local name="$1"
  [[ -z "$ONLY" || "$name" == *"$ONLY"* ]] || return 0
  T="$SANDBOX/$((passed + failed))"
  mkdir -p "$T/mark"
  : > "$T/gh.log"
  CURRENT_OK=1 OUT="" RC=0
  install_fake_gh
  "test_$name"
  if [ "$CURRENT_OK" = 1 ]; then
    passed=$((passed + 1)); printf 'ok    %s\n' "$name"
  else
    failed=$((failed + 1)); failures+=("$name"); printf 'FAIL  %s\n' "$name"
    printf '%s\n' "$OUT" | sed 's/^/    | /'
  fi
}

# Shared stage files. $MARK is a directory outside the repository.
one_stage() {
  cat <<'STAGES'
LOCAL_CI_STAGES=(tests)
stage_tests() { touch "$MARK/tests"; }
STAGES
}

two_stages() {
  cat <<'STAGES'
LOCAL_CI_STAGES=(tests lint)
stage_tests() { touch "$MARK/tests"; }
stage_lint()  { touch "$MARK/lint"; }
STAGES
}

# ── stage runner ─────────────────────────────────────────────────────────────

test_passing_stage_is_signed_off_on_the_tested_commit() {
  two_stages | new_repo
  run
  ok_exit
  marked tests; marked lint
  gh_called "signoff create --commit $(head_of) tests"
  gh_called "signoff create --commit $(head_of) lint"
  out_has "all done."
}

# "errexit-safe stage runner": a command failing in the middle of a stage must
# fail the stage even though later commands would succeed.
test_command_failing_mid_stage_fails_the_stage() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(tests lint)
stage_tests() { false; touch "$MARK/after-false"; }
stage_lint()  { touch "$MARK/lint"; }
STAGES
  run
  bad_exit
  out_has "stage 'tests' failed"
  not_marked after-false
  not_marked lint
  gh_called "signoff fail --commit $(head_of) tests --description tests failed locally"
  gh_not_called "signoff create"
}

test_stage_calling_fail_helper_fails_the_stage() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(tests)
stage_tests() { require definitely-not-a-real-tool "install it"; touch "$MARK/after"; }
STAGES
  run
  bad_exit
  out_has "missing 'definitely-not-a-real-tool' — install it"
  not_marked after
  gh_not_called "signoff create"
}

test_stage_cannot_leak_directory_or_variables_into_the_next() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(first second)
stage_first()  { cd /; LEAK=1; }
stage_second() { [ "$PWD" != / ] && [ -z "${LEAK:-}" ] && touch "$MARK/isolated"; }
STAGES
  run --no-signoff
  ok_exit
  marked isolated
}

# ── clean tree before the run ────────────────────────────────────────────────

# "fail fast on a dirty tree before running signed-off checks"
test_dirty_tree_refuses_a_signed_off_run_before_any_stage() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(tests)
prepare()     { touch "$MARK/prepare"; }
stage_tests() { touch "$MARK/tests"; }
STAGES
  printf 'edit\n' >> "$T/repo/tracked.txt"
  run
  bad_exit
  out_has "working tree has uncommitted changes"
  not_marked prepare
  not_marked tests
  gh_not_called "signoff create"
}

test_dirty_tree_is_allowed_without_signoff() {
  one_stage | new_repo
  printf 'edit\n' >> "$T/repo/tracked.txt"
  run --no-signoff
  ok_exit
  out_has "warning: working tree has uncommitted changes"
  out_has "no signoff statuses posted"
  marked tests
  gh_silent
}

# "dirty-tree check without SIGPIPE skip": with `git status | grep -q .` under
# pipefail, enough output kills git with SIGPIPE and the tree reads as clean.
test_very_dirty_tree_is_still_dirty() {
  one_stage | new_repo
  ( cd "$T/repo" && for i in $(seq 1 4000); do : > "untracked-file-with-a-deliberately-long-name-$i.txt"; done )
  run
  bad_exit
  out_has "working tree has uncommitted changes"
  not_marked tests
}

# "detect untracked files regardless of status.showUntrackedFiles"
test_untracked_file_counts_as_dirty_even_when_git_hides_untracked_files() {
  one_stage | new_repo
  "$REAL_GIT" -C "$T/repo" config status.showUntrackedFiles no
  : > "$T/repo/new-file.txt"
  run
  bad_exit
  out_has "working tree has uncommitted changes"
  not_marked tests
}

# "fail fast when git status itself fails instead of reading it as clean"
test_git_status_failure_before_the_run_is_not_a_clean_tree() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(tests)
prepare()     { touch "$MARK/prepare"; }
stage_tests() { touch "$MARK/tests"; }
STAGES
  install_breakable_git
  : > "$T/break-git-status"
  run
  bad_exit
  out_has "git status failed"
  not_marked prepare
  not_marked tests
  gh_not_called "signoff create"
}

# ── integrity during a stage ─────────────────────────────────────────────────

# "fail fast when the post-stage git status check itself fails"
test_git_status_failure_after_a_stage_is_not_a_clean_tree() {
  install_breakable_git
  new_repo <<STAGES
LOCAL_CI_STAGES=(tests)
stage_tests() { touch "\$MARK/tests" "$T/break-git-status"; }
STAGES
  run
  bad_exit
  marked tests
  out_has "git status failed"
  gh_not_called "signoff create"
}

# "bind signoff statuses to the commit each stage actually tests" and
# "verify HEAD unchanged before attesting"
test_commit_landing_mid_stage_is_never_attested() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(tests)
stage_tests() { git commit -q --allow-empty -m "landed mid-stage"; }
STAGES
  local before; before="$(head_of)"
  run
  bad_exit
  out_has "HEAD moved or working tree changed during stage 'tests'"
  gh_not_called "signoff create"
  gh_called "signoff fail --commit $before tests --description tests ran while HEAD moved or tree changed"
  [ "$(head_of)" != "$before" ] || _no "fixture did not move HEAD"
}

test_commit_landing_mid_stage_aborts_even_without_signoff() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(tests)
stage_tests() { git commit -q --allow-empty -m "landed mid-stage"; }
STAGES
  run --no-signoff
  bad_exit
  out_has "HEAD moved"
  gh_silent
}

# "abort a signed-off stage when the working tree changes mid-run"
test_edit_landing_mid_stage_is_never_attested() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(tests lint)
stage_tests() { echo generated > left-behind.txt; }
stage_lint()  { touch "$MARK/lint"; }
STAGES
  run
  bad_exit
  out_has "HEAD moved or working tree changed during stage 'tests'"
  not_marked lint
  gh_not_called "signoff create"
  gh_called "signoff fail --commit $(head_of) tests --description tests ran while HEAD moved or tree changed"
}

test_stage_may_leave_files_behind_without_signoff() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(tests)
stage_tests() { echo generated > left-behind.txt; }
STAGES
  run --no-signoff
  ok_exit
}

# ── posting statuses ─────────────────────────────────────────────────────────

# "fail the run when a required signoff status cannot be posted"
test_unposted_status_fails_the_run_after_all_stages_ran() {
  two_stages | new_repo
  run FAKE_GH_CREATE_FAILS=1 --
  bad_exit
  marked tests; marked lint
  out_has "could not post signoff status for tests"
  out_has "commit is not on any remote"
  out_has "one or more signoff statuses could not be posted"
  out_lacks "all done"
}

test_unposted_failure_status_still_reports_the_stage_failure() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(tests)
stage_tests() { false; }
STAGES
  run FAKE_GH_FAIL_FAILS=1 --
  bad_exit
  out_has "could not post failing status for tests"
  out_has "stage 'tests' failed"
}

# gh-signoff parses `gh signoff --commit SHA install` as its own install
# command and refuses it, so a stage with a command name needs explicit create.
test_stage_named_like_a_gh_signoff_command_is_posted_as_a_context() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(install status)
stage_install() { :; }
stage_status()  { :; }
STAGES
  run
  ok_exit
  gh_called "signoff create --commit $(head_of) install"
  gh_called "signoff create --commit $(head_of) status"
}

test_missing_extension_stops_before_any_stage() {
  one_stage | new_repo
  run FAKE_GH_NO_EXTENSION=1 --
  bad_exit
  out_has "gh-signoff extension missing"
  not_marked tests
}

# Same SIGPIPE class as the dirty-tree fix, in the extension lookup.
test_extension_is_found_in_a_long_extension_list() {
  one_stage | new_repo
  run FAKE_GH_MANY_EXTENSIONS=1 --
  ok_exit
  marked tests
}

test_no_signoff_needs_no_gh_at_all() {
  one_stage | new_repo
  rm "$T/bin/gh"
  local bare; bare="$T/bare-bin"; mkdir -p "$bare"
  for tool in bash env git readlink dirname basename uname sha256sum sed cut touch cat; do
    ln -s "$(command -v "$tool")" "$bare/$tool"
  done
  OUT="$(cd "$T/repo" && env -i PATH="$bare" MARK="$T/mark" GIT_CONFIG_GLOBAL=/dev/null \
    scripts/local-ci.sh --no-signoff 2>&1)"; RC=$?
  ok_exit
  marked tests
  OUT="$(cd "$T/repo" && env -i PATH="$bare" MARK="$T/mark" GIT_CONFIG_GLOBAL=/dev/null \
    scripts/local-ci.sh 2>&1)"; RC=$?
  bad_exit
  out_has "missing 'gh'"
}

# ── anchoring ────────────────────────────────────────────────────────────────

# "run local CI from the repo root regardless of invocation directory" and
# "anchor the runner to the repository owning the script"
test_run_from_another_repository_tests_and_attests_the_owning_one() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(tests)
stage_tests() { pwd > "$MARK/cwd"; }
STAGES
  one_stage | new_repo "$T/other"
  "$REAL_GIT" -C "$T/other" commit -q --allow-empty -m "other history"
  printf 'dirty\n' >> "$T/other/tracked.txt"
  run -C "$T/other" --script "$T/repo/scripts/local-ci.sh"
  ok_exit
  [ "$(cat "$T/mark/cwd" 2>/dev/null)" = "$(readlink -f "$T/repo")" ] || _no "stage ran in $(cat "$T/mark/cwd" 2>/dev/null)"
  gh_called "signoff create --commit $(head_of "$T/repo") tests"
  gh_not_called "$(head_of "$T/other")"
}

test_run_from_a_subdirectory_uses_the_repository_root() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(tests)
stage_tests() { pwd > "$MARK/cwd"; }
STAGES
  mkdir -p "$T/repo/scripts/nested"
  run -C "$T/repo/scripts" --script ./local-ci.sh
  ok_exit
  [ "$(cat "$T/mark/cwd" 2>/dev/null)" = "$(readlink -f "$T/repo")" ] || _no "stage ran in $(cat "$T/mark/cwd" 2>/dev/null)"
}

# "symlink/CDPATH-safe repo anchor"
test_run_through_a_symlink_with_cdpath_set_still_anchors() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(tests)
stage_tests() { pwd > "$MARK/cwd"; }
STAGES
  mkdir -p "$T/elsewhere/decoy/scripts"
  ln -s "$T/repo/scripts/local-ci.sh" "$T/elsewhere/ci"
  run -C "$T/elsewhere" --script "$T/elsewhere/ci" CDPATH="$T/elsewhere/decoy" --
  ok_exit
  [ "$(cat "$T/mark/cwd" 2>/dev/null)" = "$(readlink -f "$T/repo")" ] || _no "stage ran in $(cat "$T/mark/cwd" 2>/dev/null)"
  gh_called "signoff create --commit $(head_of) tests"
}

# "fail fast when the script path cannot be resolved"
test_unresolvable_runner_path_stops_the_run() {
  one_stage | new_repo
  mkdir -p "$T/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/readlink"
  chmod +x "$T/bin/readlink"
  run
  bad_exit
  out_has "cannot resolve runner path"
  not_marked tests
}

test_stage_file_outside_a_repository_is_refused() {
  one_stage | new_repo
  mkdir -p "$T/loose"
  one_stage > "$T/loose/local-ci.stages.sh"
  run "LOCAL_CI_STAGES_FILE=$T/loose/local-ci.stages.sh" --
  bad_exit
  out_has "stage file is not inside a git work tree"
}

# A wrapper (submodule or downloaded runner) names the stage file; the stage
# file's repository is the one that is tested and attested.
test_named_stage_file_anchors_to_its_own_repository() {
  one_stage | new_repo
  new_repo "$T/consumer" <<'STAGES'
LOCAL_CI_STAGES=(consumer)
stage_consumer() { pwd > "$MARK/cwd"; }
STAGES
  "$REAL_GIT" -C "$T/consumer" commit -q --allow-empty -m "consumer history"
  run "LOCAL_CI_STAGES_FILE=$T/consumer/scripts/local-ci.stages.sh" --
  ok_exit
  [ "$(cat "$T/mark/cwd" 2>/dev/null)" = "$(readlink -f "$T/consumer")" ] || _no "stage ran in $(cat "$T/mark/cwd" 2>/dev/null)"
  gh_called "signoff create --commit $(head_of "$T/consumer") consumer"
}

# ── arguments and stage file ─────────────────────────────────────────────────

# "validate stages before prepare"
test_unknown_stage_stops_before_prepare_and_before_any_stage() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(tests)
prepare()     { touch "$MARK/prepare"; }
stage_tests() { touch "$MARK/tests"; }
STAGES
  run tests typo
  bad_exit
  out_has "unknown stage 'typo' (stages: tests)"
  not_marked prepare
  not_marked tests
  gh_silent
}

test_selected_stages_run_in_the_order_given() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(a b c)
LOCAL_CI_DEFAULT_STAGES=(a b)
stage_a() { echo a >> "$MARK/order"; }
stage_b() { echo b >> "$MARK/order"; }
stage_c() { echo c >> "$MARK/order"; }
STAGES
  run --no-signoff
  ok_exit
  [ "$(tr -d '\n' < "$T/mark/order")" = ab ] || _no "default run order was $(tr -d '\n' < "$T/mark/order")"
  rm "$T/mark/order"
  run --no-signoff c a
  ok_exit
  [ "$(tr -d '\n' < "$T/mark/order")" = ca ] || _no "selected run order was $(tr -d '\n' < "$T/mark/order")"
}

# "--help prints exactly the header comment": six copies printed code lines.
test_help_describes_the_stages_and_prints_no_code() {
  new_repo <<'STAGES'
LOCAL_CI_NAME="sample"
LOCAL_CI_DESCRIPTION="Mirrors the ubuntu-latest test job."
LOCAL_CI_STAGES=(tests lint slow)
LOCAL_CI_DEFAULT_STAGES=(tests lint)
stage_tests() { :; }
stage_lint()  { :; }
stage_slow()  { :; }
STAGES
  run --help
  ok_exit
  out_has "sample local CI"
  out_has "Mirrors the ubuntu-latest test job."
  out_has "Stages:  tests lint slow"
  out_has "Default: tests lint"
  out_has "--no-signoff"
  out_lacks "set -euo pipefail"
  out_lacks "LOCAL_CI_STAGES="
  gh_silent
  run --list
  ok_exit
  out_has "stages: tests lint slow"
}

test_unknown_option_is_rejected() {
  one_stage | new_repo
  run --nope
  bad_exit
  out_has "unknown option: --nope"
  not_marked tests
}

test_stage_file_may_define_its_own_option() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(verify)
LOCAL_CI_OPTIONS_HELP="  --publish     upload after verifying"
PUBLISH=0
local_ci_option() { case "$1" in --publish) PUBLISH=1 ;; *) return 1 ;; esac; }
stage_verify() { [ "$PUBLISH" = 1 ] && touch "$MARK/published"; touch "$MARK/verified"; }
STAGES
  run --no-signoff
  ok_exit; marked verified; not_marked published
  run --no-signoff --publish
  ok_exit; marked published
  run --no-signoff --other
  bad_exit; out_has "unknown option: --other"
  run --help
  out_has "--publish     upload after verifying"
}

test_stage_file_mistakes_are_reported() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(tests missing)
stage_tests() { :; }
STAGES
  run --no-signoff
  bad_exit; out_has "stage 'missing' is listed but stage_missing is not defined"

  new_repo "$T/r2" <<'STAGES'
LOCAL_CI_STAGES=(tests)
LOCAL_CI_DEFAULT_STAGES=(lint)
stage_tests() { :; }
STAGES
  run -C "$T/r2" --script "$T/r2/scripts/local-ci.sh" --no-signoff
  bad_exit; out_has "default stage 'lint' is not in LOCAL_CI_STAGES"

  new_repo "$T/r3" <<'STAGES'
LOCAL_CI_STAGES=("bad name")
STAGES
  run -C "$T/r3" --script "$T/r3/scripts/local-ci.sh" --no-signoff
  bad_exit; out_has "invalid stage name 'bad name'"

  new_repo "$T/r4" <<'STAGES'
stage_tests() { :; }
STAGES
  run -C "$T/r4" --script "$T/r4/scripts/local-ci.sh" --no-signoff
  bad_exit; out_has "LOCAL_CI_STAGES is empty"
}

test_unlisted_stage_function_cannot_be_selected() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(tests)
stage_tests()  { :; }
stage_hidden() { touch "$MARK/hidden"; }
STAGES
  run --no-signoff hidden
  bad_exit
  out_has "unknown stage 'hidden'"
  not_marked hidden
}

# ── prepare ──────────────────────────────────────────────────────────────────

test_prepare_runs_once_before_the_stages_and_can_export() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(a b)
prepare() { echo prepare >> "$MARK/order"; export FROM_PREPARE=yes; }
stage_a() { echo "a:$FROM_PREPARE" >> "$MARK/order"; }
stage_b() { echo "b:$FROM_PREPARE" >> "$MARK/order"; }
STAGES
  run --no-signoff
  ok_exit
  [ "$(tr '\n' ' ' < "$T/mark/order")" = "prepare a:yes b:yes " ] || _no "order was: $(tr '\n' ' ' < "$T/mark/order")"
}

test_failing_prepare_stops_the_run() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(tests)
prepare()     { false; touch "$MARK/after-false"; }
stage_tests() { touch "$MARK/tests"; }
STAGES
  run
  bad_exit
  not_marked after-false
  not_marked tests
  gh_not_called "signoff create"
}

test_prepare_that_dirties_the_tree_is_refused() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(tests)
prepare()     { echo lockfile-rewrite >> tracked.txt; }
stage_tests() { touch "$MARK/tests"; }
STAGES
  run
  bad_exit
  out_has "prepare left uncommitted changes"
  not_marked tests
}

test_prepare_that_moves_head_is_refused() {
  new_repo <<'STAGES'
LOCAL_CI_STAGES=(tests)
prepare()     { git commit --quiet --allow-empty -m prepare; }
stage_tests() { touch "$MARK/tests"; }
STAGES
  run
  bad_exit
  out_has "HEAD moved before stage 'tests'"
  not_marked tests
  gh_not_called "signoff create"
}

# ── vendored copies ──────────────────────────────────────────────────────────

test_edited_vendored_runner_is_refused() {
  one_stage | new_repo
  ( cd "$T/repo/scripts" && sha256sum local-ci.sh > local-ci.sha256 )
  "$REAL_GIT" -C "$T/repo" add -A; "$REAL_GIT" -C "$T/repo" commit -q -m "vendor checksum"
  run --no-signoff
  ok_exit
  printf '\n# a fix applied in place\n' >> "$T/repo/scripts/local-ci.sh"
  run --no-signoff
  bad_exit
  out_has "does not match local-ci.sha256"
}


# ── main ─────────────────────────────────────────────────────────────────────

for name in $(declare -F | sed -n 's/^declare -f test_//p'); do
  t "$name"
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  printf 'failed: %s\n' "${failures[*]}"
  exit 1
fi
[ "$passed" -gt 0 ] || { echo "no tests matched '$ONLY'" >&2; exit 1; }
