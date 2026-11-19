# Shared local CI runner

`scripts/local-ci.sh` runs a repository's check stages on your own Linux machine
and records each result as a `signoff/<stage>` commit status using
[basecamp/gh-signoff](https://github.com/basecamp/gh-signoff). A repository
supplies only its stages. The runner is identical everywhere.

## The stage file

Put `scripts/local-ci.stages.sh` next to the runner. The runner sources it from
the repository root as trusted Bash. Keep its top level to configuration and
function definitions.

```bash
# scripts/local-ci.stages.sh
LOCAL_CI_NAME="pi-droid"                                     # optional, defaults to the repo dir name
LOCAL_CI_DESCRIPTION="Mirrors .github/workflows/ci.yml (ubuntu-latest test job)."  # optional
LOCAL_CI_STAGES=(lint build tests)                           # required: every stage, in run order
LOCAL_CI_DEFAULT_STAGES=(lint build tests)                   # optional, defaults to LOCAL_CI_STAGES

prepare() { node_min 22; require npm ""; npm ci; }           # optional, runs once before the stages

stage_lint()  { npm run lint; }
stage_build() { npm run build; }
stage_tests() { npm run test:ci -- --no-file-parallelism; }
```

Rules the runner enforces at start-up, before anything slow runs:

- Every name in `LOCAL_CI_STAGES` has a `stage_<name>` function. Names match
  `[A-Za-z0-9][A-Za-z0-9._-]*`, because each becomes the status context
  `signoff/<name>`.
- Every default stage is listed. Only listed stages can be selected. A
  helper called `stage_whatever` that is not listed cannot be run by accident.
- Selected stages are validated before `prepare` runs.

Available inside stages and `prepare`: `_fail`, `_log`, `_ok`, `_warn`,
`require <cmd> [hint]`, `node_min <major>`. Each stage runs in a subshell with
`errexit`. A failing command anywhere in it fails the stage, and a `cd` or a
variable set in one stage does not leak into the next. `prepare` runs in the
runner's own shell, so it can `export` environment for the stages.

### Extra options

A repository that needs its own flags, as forge-android needs `--publish`,
defines `local_ci_option`. It returns 0 for a flag it handled and non-zero for
anything else:

```bash
LOCAL_CI_OPTIONS_HELP="  --publish     upload the verified asset (trusted machine only)"
PUBLISH=0
local_ci_option() { case "$1" in --publish) PUBLISH=1 ;; *) return 1 ;; esac; }
```

## What the runner guarantees

Each guarantee below was a review fix applied repository by repository in
November 2026 (see [DRIFT.md](DRIFT.md)). Each has a test in
`tests/local-ci.test.sh`, and `tests/mutants.sh` checks that reverting the fix
makes that test fail.

| Guarantee | Test |
|---|---|
| A command failing mid-stage fails the stage (errexit is never suppressed by an `if`) | `command_failing_mid_stage_fails_the_stage` |
| A signed-off run refuses a dirty tree before any stage runs | `dirty_tree_refuses_a_signed_off_run_before_any_stage` |
| The dirty check cannot be skipped by SIGPIPE (no `git status \| grep -q`) | `very_dirty_tree_is_still_dirty` |
| Untracked files count even with `status.showUntrackedFiles=no` | `untracked_file_counts_as_dirty_even_when_git_hides_untracked_files` |
| A failing `git status` stops the run, before and after every stage | `git_status_failure_before_the_run_is_not_a_clean_tree`, `…_after_a_stage_…` |
| Every status is bound with `--commit` to the commit the run started on | `passing_stage_is_signed_off_on_the_tested_commit` |
| HEAD moving during a stage is never attested, with or without signoff | `commit_landing_mid_stage_is_never_attested` |
| The tree changing during a signed-off stage is never attested | `edit_landing_mid_stage_is_never_attested` |
| A status that cannot be posted fails the run | `unposted_status_fails_the_run_after_all_stages_ran` |
| The runner anchors to its own repository, from any directory, symlink or `CDPATH` | `run_from_another_repository_…`, `run_through_a_symlink_…` |
| An unresolvable runner path stops the run | `unresolvable_runner_path_stops_the_run` |
| A stage named like a gh-signoff command (`install`, `status`, …) is posted as a context, not run as that command | `stage_named_like_a_gh_signoff_command_is_posted_as_a_context` |
| HEAD must also stay fixed during preparation | `prepare_that_moves_head_is_refused` |
| `prepare` may not dirty the tree of a signed-off run | `prepare_that_dirties_the_tree_is_refused` |
| `--help` is generated, so it cannot print code | `help_describes_the_stages_and_prints_no_code` |
| A vendored copy that was edited in place refuses to run | `edited_vendored_runner_is_refused` |

## Running the tests

```bash
tests/local-ci.test.sh            # 39 tests, no network
tests/mutants.sh                  # reverts each fix in turn; every mutant must be killed
RUNNER=/path/to/other/local-ci.sh tests/local-ci.test.sh   # point the suite at another copy
```

The suite uses real git repositories in a temporary directory and a fake `gh`
on `PATH`. It never contacts GitHub.

## Usage in a repository

```bash
scripts/local-ci.sh                 # default stages, post signoff/<stage> for each
scripts/local-ci.sh tests lint      # selected stages, in that order
scripts/local-ci.sh --no-signoff    # checks only; a dirty tree is allowed, with a warning
scripts/local-ci.sh --list | --help | --version
```

Install or upgrade gh-signoff (tested with v0.4.1) and push first. The runner posts with `gh signoff create --commit <sha>`, and
gh-signoff refuses a commit that is on no remote.

Integrity checks sample HEAD and Git status at run and stage boundaries. Run
signoff from a checkout that other processes are leaving alone, ideally a
dedicated worktree. A transient edit that is reverted between samples will
leave no evidence in Git status.
