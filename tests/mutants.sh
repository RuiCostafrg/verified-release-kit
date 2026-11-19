#!/usr/bin/env bash
# Proves the tests have teeth: each mutant below reverts one fix in a copy of
# scripts/local-ci.sh to the form the drifted copies had, and the named test
# must then FAIL. A mutant that survives means the fix is no longer guarded.
#
#   tests/mutants.sh            run all mutants
#   tests/mutants.sh PATTERN    run mutants whose name contains PATTERN
set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
runner="$here/../scripts/local-ci.sh"
only="${1:-}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

original="$(cat "$runner"; printf x)"; original="${original%x}"
killed=0
problems=()

# mutant NAME TEST FROM TO: replace FROM (which must occur exactly once) with TO.
mutant() {
  local name="$1" test="$2" from="$3" to="$4" rest mutated
  [[ -z "$only" || "$name" == *"$only"* ]] || return 0
  rest="${original#*"$from"}"
  if [ "$rest" = "$original" ] || [ "${rest#*"$from"}" != "$rest" ]; then
    problems+=("$name: the text to mutate does not occur exactly once — update tests/mutants.sh")
    printf 'STALE     %s\n' "$name"
    return 0
  fi
  mutated="${original/"$from"/"$to"}"
  printf '%s' "$mutated" > "$work/local-ci.sh"
  chmod +x "$work/local-ci.sh"
  if ! bash -n "$work/local-ci.sh" 2>/dev/null; then
    problems+=("$name: mutant is not valid bash")
    printf 'INVALID   %s\n' "$name"
  elif RUNNER="$work/local-ci.sh" "$here/local-ci.test.sh" "$test" >/dev/null 2>&1; then
    problems+=("$name: survived — test '$test' still passes without the fix")
    printf 'SURVIVED  %s\n' "$name"
  else
    killed=$((killed + 1))
    printf 'killed    %s  (by %s)\n' "$name" "$test"
  fi
}

mutant errexit-suppressed-by-if command_failing_mid_stage_fails_the_stage \
'  set +e
  ( set -e; "stage_$s" )
  rc=$?
  set -e' \
'  if ( set -e; "stage_$s" ); then rc=0; else rc=1; fi'

mutant dirty-tree-only-warns dirty_tree_refuses_a_signed_off_run_before_any_stage \
'    _fail "working tree has uncommitted changes — commit or stash them, or pass --no-signoff"' \
'    :'

mutant dirty-check-through-grep-pipe very_dirty_tree_is_still_dirty \
'worktree_status="$(_worktree_status)" \
  || _fail "git status failed — cannot verify tree cleanliness"
if [ -n "$worktree_status" ]; then' \
'if git status --porcelain --untracked-files=normal | grep -q .; then'

mutant untracked-files-follow-git-config untracked_file_counts_as_dirty_even_when_git_hides_untracked_files \
'_worktree_status() { git status --porcelain --untracked-files=normal; }' \
'_worktree_status() { git status --porcelain; }'

mutant pre-run-status-failure-reads-clean git_status_failure_before_the_run_is_not_a_clean_tree \
'worktree_status="$(_worktree_status)" \
  || _fail "git status failed — cannot verify tree cleanliness"
if [ -n "$worktree_status" ]; then' \
'if [ -n "$(_worktree_status)" ]; then'

mutant post-stage-status-failure-reads-clean git_status_failure_after_a_stage_is_not_a_clean_tree \
'  post_status="$(_worktree_status)" \
    || _fail "git status failed — cannot verify tree cleanliness"' \
'  post_status="$(_worktree_status || true)"'

mutant status-not-bound-to-commit passing_stage_is_signed_off_on_the_tested_commit \
'gh signoff create --commit "$sha" "$stage"' \
'gh signoff create "$stage"'

mutant moved-head-not-checked commit_landing_mid_stage_is_never_attested \
'  if [ "$post_sha" != "$head_sha" ] \' \
'  if false \'

mutant changed-tree-not-checked edit_landing_mid_stage_is_never_attested \
'     || { [ "$NO_SIGNOFF" = 0 ] && [ -n "$post_status" ]; }; then' \
'     || false; then'

mutant unposted-status-only-warns unposted_status_fails_the_run_after_all_stages_ran \
'    signoff_failed=1' \
'    :'

mutant runs-in-callers-directory run_from_another_repository_tests_and_attests_the_owning_one \
'CDPATH='"''"' cd -- "$repo_root" || _fail "cannot enter repository root: $repo_root"' \
':'

mutant symlink-not-resolved run_through_a_symlink_with_cdpath_set_still_anchors \
'runner="$(readlink -f -- "${BASH_SOURCE[0]}")" || _fail "cannot resolve runner path"' \
'runner="${BASH_SOURCE[0]}"'

mutant unresolved-path-ignored unresolvable_runner_path_stops_the_run \
'|| _fail "cannot resolve runner path"' \
'|| true'

mutant stages-validated-too-late unknown_stage_stops_before_prepare_and_before_any_stage \
'  _is_listed "$s" || _fail "unknown stage '"'"'$s'"'"' (stages: ${LOCAL_CI_STAGES[*]})"' \
'  :'

mutant implicit-create-command stage_named_like_a_gh_signoff_command_is_posted_as_a_context \
'gh signoff create --commit "$sha" "$stage"' \
'gh signoff --commit "$sha" "$stage"'

mutant extension-lookup-through-grep-pipe extension_is_found_in_a_long_extension_list \
'  extensions="$(gh extension list 2>/dev/null)" || extensions=""' \
'  extensions=""; gh extension list 2>/dev/null | grep -qi "gh-signoff" && extensions=gh-signoff'

mutant missing-extension-ignored missing_extension_stops_before_any_stage \
'    *) _fail "gh-signoff extension missing' \
'    *) : "gh-signoff extension missing'

mutant prepare-may-dirty-the-tree prepare_that_dirties_the_tree_is_refused \
'    _fail "prepare left uncommitted changes in the working tree — refusing to attest"' \
'    :'

mutant vendored-checksum-not-checked edited_vendored_runner_is_refused \
'sha256sum --check --status local-ci.sha256 )' \
'true )'

mutant unlisted-stages-selectable unlisted_stage_function_cannot_be_selected \
'  _is_listed "$s" || _fail "unknown stage '"'"'$s'"'"' (stages: ${LOCAL_CI_STAGES[*]})"' \
'  declare -F "stage_$s" >/dev/null || _fail "unknown stage"'

printf '\n%d killed, %d problems\n' "$killed" "${#problems[@]}"
if [ "${#problems[@]}" -ne 0 ]; then
  printf '  %s\n' "${problems[@]}"
  exit 1
fi
[ "$killed" -gt 0 ] || { echo "no mutants matched '$only'" >&2; exit 1; }
