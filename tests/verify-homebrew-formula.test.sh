#!/usr/bin/env bash
# Tests for scripts/verify-homebrew-formula.sh. Plain bash, real git repositories
# for the tap and the source, and a fake `gh` on PATH. Nothing reaches GitHub.
#
#   tests/verify-homebrew-formula.test.sh            run everything
#   tests/verify-homebrew-formula.test.sh PATTERN    run tests whose name contains PATTERN
#   SCRIPT=/path/to/verify-homebrew-formula.sh tests/verify-homebrew-formula.test.sh
#
# The fake `gh` answers read-only API calls from the fixtures under $T and
# refuses anything else, including every write. The fake attestation check
# compares the arguments it receives with what was "attested", so a wrong
# identity, ref, commit or file digest is rejected the way the real verifier
# rejects it. If `ruby` is not installed a stub stands in for `ruby -c`.
set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT:-$here/../scripts/verify-homebrew-formula.sh}"
SCRIPT="$(readlink -f -- "$SCRIPT")"
ONLY="${1:-}"
REAL_GIT="$(command -v git)"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
unset CDPATH

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

HAVE_RUBY=0
command -v ruby >/dev/null 2>&1 && HAVE_RUBY=1

passed=0
failed=0
failures=()
T="" OUT="" RC=0 CURRENT_OK=1

SRC=RuiCostafrg/typescript-crap
TAP=RuiCostafrg/homebrew-tap
FORMULA=ts-crap
WORKFLOW=.github/workflows/release.yml

# ── fixtures ─────────────────────────────────────────────────────────────────

formula_text() { # formula_text VERSION
  printf 'class TsCrap < Formula\n  desc "Test"\n  version "%s"\n  url "https://example.invalid/x.tgz"\nend\n' "$1"
}

# The tap: a real repository with Formula/$FORMULA.rb at version $1 (none if empty).
new_tap() {
  mkdir -p "$T/tap/Formula"
  "$REAL_GIT" -C "$T/tap" init -q -b main
  echo readme > "$T/tap/README.md"
  [ -z "${1:-}" ] || formula_text "$1" > "$T/tap/Formula/$FORMULA.rb"
  "$REAL_GIT" -C "$T/tap" add -A
  "$REAL_GIT" -C "$T/tap" commit -q -m tap
}

# The source repository with a stable release v$1 (a lightweight tag unless $2 is annotated).
new_source() {
  mkdir -p "$T/src"
  "$REAL_GIT" -C "$T/src" init -q -b main
  echo code > "$T/src/code.txt"
  "$REAL_GIT" -C "$T/src" add -A
  "$REAL_GIT" -C "$T/src" commit -q -m release
  if [ "${2:-}" = annotated ]; then
    "$REAL_GIT" -C "$T/src" tag -a "v$1" -m "release v$1"
  else
    "$REAL_GIT" -C "$T/src" tag "v$1"
  fi
  formula_text "$1" > "$T/asset.rb"
  write_release "v$1" false false "$FORMULA.rb"
}

# write_release TAG DRAFT PRERELEASE ASSET...
write_release() {
  local tag="$1" draft="$2" pre="$3"; shift 3
  local assets
  assets="$(printf '%s\n' "$@" | jq -R '{name: .}' | jq -s .)"
  jq -n --arg tag "$tag" --argjson draft "$draft" --argjson pre "$pre" --argjson assets "$assets" \
    '{tag_name: $tag, draft: $draft, prerelease: $pre, assets: $assets}' > "$T/release.json"
}

commit_of() { "$REAL_GIT" -C "$T/src" rev-parse "refs/tags/$1^{commit}"; }
tap_head()  { "$REAL_GIT" -C "$T/tap" rev-parse main; }
asset_sha() { sha256sum "$T/asset.rb" | cut -d' ' -f1; }

# What the (fake) attestation covers. Defaults follow the release; a test
# overrides one field to model a wrong identity, ref, commit or digest.
attest() { printf '%s' "$2" > "$T/attest.$1"; } # identity|ref|digest|sha256

default_world() { # default_world CURRENT_FORMULA_VERSION RELEASE_VERSION
  new_tap "$1"
  new_source "$2"
}

install_fakes() {
  mkdir -p "$T/bin"
  cat > "$T/bin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
fail() { echo "$1" >&2; exit "${2:-1}"; }
not_found() { fail "gh: Not Found (HTTP 404)"; }
emit() { # emit JSON: print it, or apply the --jq expression like gh does
  if [ -n "${JQ:-}" ]; then printf '%s' "$1" | jq -r "$JQ"; else printf '%s\n' "$1"; fi
}
case "${1:-} ${2:-}" in
  "api "*)
    path="$2"; shift 2; JQ=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --jq) JQ="$2"; shift 2 ;;
        -H) shift 2 ;;
        *) fail "fake gh: refused (not a read-only GET): api $path $*" 64 ;;
      esac
    done
    case "$path" in
      "repos/$FAKE_SRC")
        [ ! -e "$FAKE_T/src_missing" ] || not_found
        emit "{\"full_name\":\"$FAKE_SRC\"}" ;;
      "repos/$FAKE_SRC/releases/latest")
        [ ! -s "$FAKE_T/release_error" ] || fail "$(cat "$FAKE_T/release_error")"
        [ -f "$FAKE_T/release.json" ] || not_found
        emit "$(cat "$FAKE_T/release.json")" ;;
      "repos/$FAKE_TAP/commits/"*)
        sha="$(git -C "$FAKE_T/tap" rev-parse --verify -q "refs/heads/${path#repos/$FAKE_TAP/commits/}")" || not_found
        emit "{\"sha\":\"$sha\"}" ;;
      "repos/$FAKE_TAP/contents/Formula/"*"?ref="*)
        name="${path#repos/$FAKE_TAP/contents/Formula/}"; sha="${name#*?ref=}"; name="${name%%\?*}"
        git -C "$FAKE_T/tap" show "$sha:Formula/$name" 2>/dev/null || not_found ;;
      "repos/$FAKE_SRC/git/ref/tags/"*)
        tag="${path#repos/$FAKE_SRC/git/ref/tags/}"
        git -C "$FAKE_T/src" rev-parse --verify -q "refs/tags/$tag" >/dev/null || not_found
        emit "{\"ref\":\"refs/tags/$tag\",\"object\":{\"type\":\"$(git -C "$FAKE_T/src" cat-file -t "refs/tags/$tag")\",\"sha\":\"$(git -C "$FAKE_T/src" rev-parse "refs/tags/$tag")\"}}" ;;
      "repos/$FAKE_SRC/git/tags/"*)
        sha="${path#repos/$FAKE_SRC/git/tags/}"
        target="$(git -C "$FAKE_T/src" cat-file -p "$sha" | sed -n 's/^object //p')"
        type="$(git -C "$FAKE_T/src" cat-file -p "$sha" | sed -n 's/^type //p')"
        emit "{\"object\":{\"type\":\"$type\",\"sha\":\"$target\"}}" ;;
      *) fail "fake gh: unexpected api call: $path" 64 ;;
    esac ;;
  "pr list")
    shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) [ "$2" = "$FAKE_TAP" ] || fail "fake gh: wrong repo $2" 64; shift 2 ;;
        --head|--base|--state|--json|--jq) shift 2 ;;
        *) fail "fake gh: unexpected pr list arg $1" 64 ;;
      esac
    done
    cat "$FAKE_T/pr_count" 2>/dev/null || echo 0 ;;
  "release download")
    shift 2; tag="$1"; shift; pattern="" dir=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) [ "$2" = "$FAKE_SRC" ] || fail "fake gh: wrong repo $2" 64; shift 2 ;;
        --pattern) pattern="$2"; shift 2 ;;
        --dir) dir="$2"; shift 2 ;;
        *) fail "fake gh: unexpected download arg $1" 64 ;;
      esac
    done
    [ -n "$pattern" ] && [ -n "$dir" ] || fail "fake gh: download needs --pattern and --dir" 64
    cp "$FAKE_T/asset.rb" "$dir/$pattern" ;;
  "attestation verify")
    shift 2; file="$1"; shift
    identity="" ref="" digest="" predicate="" selfhosted=0 repo=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) repo="$2"; shift 2 ;;
        --cert-identity) identity="$2"; shift 2 ;;
        --source-ref) ref="$2"; shift 2 ;;
        --source-digest) digest="$2"; shift 2 ;;
        --predicate-type) predicate="$2"; shift 2 ;;
        --deny-self-hosted-runners) selfhosted=1; shift ;;
        *) fail "fake gh: unexpected verify arg $1" 64 ;;
      esac
    done
    tag="$(jq -r .tag_name "$FAKE_T/release.json")"
    want() { if [ -s "$FAKE_T/attest.$1" ]; then cat "$FAKE_T/attest.$1"; else printf '%s' "$2"; fi; }
    [ "$repo" = "$FAKE_SRC" ] || fail "verification failed: repository mismatch"
    [ "$predicate" = "https://slsa.dev/provenance/v1" ] || fail "verification failed: predicate type"
    [ "$selfhosted" = 1 ] || fail "verification failed: self-hosted runners were not denied"
    [ "$identity" = "$(want identity "https://github.com/$FAKE_SRC/$FAKE_WORKFLOW@refs/tags/$tag")" ] || fail "verification failed: certificate identity mismatch"
    [ "$ref" = "$(want ref "refs/tags/$tag")" ] || fail "verification failed: source ref mismatch"
    [ "$digest" = "$(want digest "$(git -C "$FAKE_T/src" rev-parse "refs/tags/$tag^{commit}")")" ] || fail "verification failed: source digest mismatch"
    [ "$(sha256sum "$file" | cut -d' ' -f1)" = "$(want sha256 "$(sha256sum "$FAKE_T/asset.rb" | cut -d' ' -f1)")" ] || fail "verification failed: no attestation for this artifact digest"
    echo "Loaded 1 attestation" ;;
  *) fail "fake gh: unexpected call: $*" 64 ;;
esac
FAKE
  chmod +x "$T/bin/gh"
  if [ "$HAVE_RUBY" = 0 ]; then
    # Stand-in for `ruby -c` when ruby is not installed: it rejects the one
    # construct the "malformed" fixture contains.
    cat > "$T/bin/ruby" <<'FAKE'
#!/usr/bin/env bash
printf 'ruby %s\n' "$*" >> "$FAKE_LOG"
[ "${1:-}" = -c ] && [ -f "${2:-}" ] || { echo "fake ruby: only 'ruby -c FILE' is supported" >&2; exit 64; }
if grep -q 'def broken(' "$2"; then echo "$2:3: syntax error, unexpected end-of-input" >&2; exit 1; fi
echo "Syntax OK"
FAKE
    chmod +x "$T/bin/ruby"
  fi
}

# run_verify [VAR=value...]: run the script with a valid configuration; later
# VAR=value pairs override it.
run_verify() {
  OUT="$(env -i HOME="$T" PATH="$T/bin:$PATH" TMPDIR="$T" \
    FAKE_T="$T" FAKE_LOG="$T/gh.log" FAKE_SRC="$SRC" FAKE_TAP="$TAP" FAKE_WORKFLOW="$WORKFLOW" \
    GH_TOKEN=fake-token GITHUB_REPOSITORY="$TAP" \
    GITHUB_OUTPUT="$T/github-output" GITHUB_STEP_SUMMARY="$T/summary.md" RUNNER_TEMP="$T/runner" \
    SOURCE_REPOSITORY="$SRC" WORKFLOW_PATH="$WORKFLOW" FORMULA="$FORMULA" ALLOW_BOOTSTRAP=false BASE_BRANCH=main \
    "$@" bash "$SCRIPT" 2>&1)"
  RC=$?
}

gh_log() { cat "$T/gh.log"; }

# ── assertions ───────────────────────────────────────────────────────────────

_no() { CURRENT_OK=0; printf '    assertion failed: %s\n' "$*"; }
ok_exit()       { [ "$RC" -eq 0 ] || _no "expected exit 0, got $RC"; }
bad_exit()      { [ "$RC" -ne 0 ] || _no "expected a non-zero exit, got 0"; }
out_has()       { [[ "$OUT" == *"$1"* ]] || _no "output lacks: $1"; }
output_is()     { grep -qxF -- "$1=$2" "$T/github-output" 2>/dev/null || _no "GITHUB_OUTPUT lacks $1=$2 (has: $(tr '\n' ' ' < "$T/github-output" 2>/dev/null))"; }
no_candidate()  { output_is candidate false; ! grep -q '^candidate=true' "$T/github-output" 2>/dev/null || _no "candidate=true was emitted"; }
gh_called()     { gh_log | grep -qxF -- "$1" || _no "gh was not called with: $1"; }
# verify_called TAG: the attestation check ran on the downloaded asset with exactly
# the strict arguments, against the given source commit.
verify_called() {
  gh_log | grep -qF -- "/download/$FORMULA.rb --repo $SRC --cert-identity https://github.com/$SRC/$WORKFLOW@refs/tags/$1 --source-ref refs/tags/$1 --source-digest $2 --predicate-type https://slsa.dev/provenance/v1 --deny-self-hosted-runners" \
    || _no "attestation verify was not called with the strict arguments for $1 at $2"
}
gh_not_called() { ! gh_log | grep -qF -- "$1" || _no "gh was called with: $1"; }
gh_silent()     { [ ! -s "$T/gh.log" ] || _no "gh was called: $(gh_log | tr '\n' ';')"; }
no_writes()     { ! gh_log | grep -Eq -- '(^| )(-X|--method|-f|-F|--input)( |$)|workflow run|pr create' || _no "gh made a write call"; }
no_leftovers()  { [ -z "$(find "$T/runner" -mindepth 1 2>/dev/null | head -1)" ] || _no "scratch files left behind: $(find "$T/runner" -mindepth 1 | head -3 | tr '\n' ' ')"; }

t() {
  local name="$1"
  [[ -z "$ONLY" || "$name" == *"$ONLY"* ]] || return 0
  T="$SANDBOX/$((passed + failed))"
  mkdir -p "$T/runner"
  : > "$T/gh.log"
  CURRENT_OK=1 OUT="" RC=0
  install_fakes
  "test_$name"
  if [ "$CURRENT_OK" = 1 ]; then
    passed=$((passed + 1)); printf 'ok    %s\n' "$name"
  else
    failed=$((failed + 1)); failures+=("$name"); printf 'FAIL  %s\n' "$name"
    printf '%s\n' "$OUT" | sed 's/^/    | /'
  fi
}

# ── a valid candidate ────────────────────────────────────────────────────────

test_valid_newer_release_is_a_candidate() {
  default_world 1.2.2 1.2.3
  run_verify
  ok_exit; no_writes
  output_is candidate true
  output_is tag v1.2.3
  output_is source-sha "$(commit_of v1.2.3)"
  output_is formula-sha256 "$(asset_sha)"
  output_is artifact-name "verified-formula-$FORMULA"
  path="$(sed -n 's/^formula-path=//p' "$T/github-output")"
  cmp -s "$path" "$T/asset.rb" || _no "formula-path does not hold the verified formula"
  verify_called v1.2.3 "$(commit_of v1.2.3)"
  gh_called "pr list --repo $TAP --head releases/$FORMULA-v1.2.3 --base main --state open --json number --jq length"
  grep -q "$(asset_sha)" "$T/summary.md" || _no "summary lacks the formula digest"
  grep -q "$(tap_head)" "$T/summary.md" || _no "summary lacks the tap base commit"
}

test_annotated_tag_resolves_to_its_commit() {
  default_world 1.2.2 1.2.3
  rm -rf "$T/src" "$T/release.json"
  new_source 1.2.3 annotated
  tag_obj="$("$REAL_GIT" -C "$T/src" rev-parse refs/tags/v1.2.3)"
  [ "$tag_obj" != "$(commit_of v1.2.3)" ] || _no "fixture tag is not annotated"
  run_verify
  ok_exit; no_writes
  output_is candidate true
  output_is source-sha "$(commit_of v1.2.3)"
  gh_called "api repos/$SRC/git/tags/$tag_obj --jq [.object.type, .object.sha] | @tsv"
  # The attestation is checked against the commit, never the tag object.
  verify_called v1.2.3 "$(commit_of v1.2.3)"
}

# ── the verifier rejects what is not provably the release workflow ───────────

test_wrong_workflow_identity_is_rejected() {
  default_world 1.2.2 1.2.3
  attest identity "https://github.com/$SRC/.github/workflows/other.yml@refs/tags/v1.2.3"
  run_verify
  bad_exit; no_candidate; no_leftovers
  out_has "attestation verification failed"
}

test_wrong_workflow_repository_in_identity_is_rejected() {
  default_world 1.2.2 1.2.3
  attest identity "https://github.com/someone/else/$WORKFLOW@refs/tags/v1.2.3"
  run_verify
  bad_exit; no_candidate
  out_has "attestation verification failed"
}

test_wrong_source_ref_is_rejected() {
  default_world 1.2.2 1.2.3
  attest ref refs/heads/main
  run_verify
  bad_exit; no_candidate
  out_has "attestation verification failed"
}

test_wrong_source_commit_is_rejected() {
  default_world 1.2.2 1.2.3
  attest digest "$(printf 'b%.0s' $(seq 40))"
  run_verify
  bad_exit; no_candidate
  out_has "attestation verification failed"
}

test_altered_asset_digest_is_rejected() {
  default_world 1.2.2 1.2.3
  attest sha256 "$(asset_sha)"
  printf '# tampered after attestation\n' >> "$T/asset.rb"
  run_verify
  bad_exit; no_candidate; no_leftovers
  out_has "attestation verification failed"
}

# ── the formula itself ───────────────────────────────────────────────────────

malformed_formula() { printf 'class TsCrap < Formula\n  version "1.2.3"\n  def broken(\nend\n' > "$T/asset.rb"; }

test_malformed_formula_fails() {
  default_world 1.2.2 1.2.3
  malformed_formula
  run_verify
  bad_exit; no_candidate; no_leftovers
  out_has "ruby -c rejected"
}

test_malformed_formula_still_fails_under_bootstrap() {
  default_world 1.2.2 1.2.3
  malformed_formula
  run_verify ALLOW_BOOTSTRAP=true
  bad_exit; no_candidate
  out_has "ruby -c rejected"
}

test_formula_version_must_match_the_tag() {
  default_world 1.2.2 1.2.3
  formula_text 1.2.4 > "$T/asset.rb"
  run_verify
  bad_exit; no_candidate
  out_has "declares version 1.2.4 but the release tag is v1.2.3"
}

test_formula_without_a_version_fails() {
  default_world 1.2.2 1.2.3
  printf 'class TsCrap < Formula\nend\n' > "$T/asset.rb"
  run_verify
  bad_exit; no_candidate
  out_has "does not declare exactly one version"
}

test_second_nested_version_is_rejected() {
  default_world 1.2.2 1.2.3
  printf 'class TsCrap < Formula\n  version "1.2.3"\n  if OS.linux?\n    version "9.9.9"\n  end\nend\n' > "$T/asset.rb"
  run_verify
  bad_exit; no_candidate
  out_has "does not declare exactly one version"
}

test_version_after_end_marker_is_rejected() {
  default_world 1.2.2 1.2.3
  printf 'class TsCrap < Formula\n  version "1.2.3"\nend\n__END__\nversion "9.9.9"\n' > "$T/asset.rb"
  run_verify
  bad_exit; no_candidate
  out_has "does not declare exactly one version"
}

# ── staleness and existing work ──────────────────────────────────────────────

test_older_release_is_not_a_candidate() {
  default_world 1.3.0 1.2.3
  run_verify
  ok_exit; no_candidate
  gh_not_called "release download"
  gh_not_called "attestation verify"
}

test_equal_version_is_not_a_candidate() {
  default_world 1.2.3 1.2.3
  run_verify
  ok_exit; no_candidate
  gh_not_called "release download"
}

test_versions_compare_numerically_not_lexically() {
  default_world 1.9.0 1.10.0
  run_verify
  ok_exit
  output_is candidate true
}

test_existing_update_pr_is_not_a_candidate() {
  default_world 1.2.2 1.2.3
  echo 1 > "$T/pr_count"
  run_verify
  ok_exit; no_candidate
  out_has "already open"
  gh_not_called "release download"
  gh_not_called "attestation verify"
}

# ── bootstrap ────────────────────────────────────────────────────────────────

test_missing_release_with_bootstrap_is_a_no_op() {
  new_tap 1.2.2
  run_verify ALLOW_BOOTSTRAP=true
  ok_exit; no_candidate
  out_has "no published release yet"
}

test_missing_release_without_bootstrap_fails() {
  new_tap 1.2.2
  run_verify
  bad_exit; no_candidate
  out_has "no published release and bootstrap is not allowed"
}

test_missing_source_repository_fails_even_with_bootstrap() {
  new_tap 1.2.2
  : > "$T/src_missing"
  run_verify ALLOW_BOOTSTRAP=true
  bad_exit; no_candidate
  out_has "cannot access source repository"
}

test_release_lookup_error_fails_even_with_bootstrap() {
  new_tap 1.2.2
  echo "gh: Server Error (HTTP 500)" > "$T/release_error"
  run_verify ALLOW_BOOTSTRAP=true
  bad_exit; no_candidate
}

test_missing_tap_formula_with_bootstrap_is_a_candidate() {
  default_world "" 1.0.0
  run_verify ALLOW_BOOTSTRAP=true
  ok_exit
  output_is candidate true
  output_is tag v1.0.0
}

test_missing_tap_formula_without_bootstrap_fails() {
  default_world "" 1.0.0
  run_verify
  bad_exit; no_candidate
  out_has "cannot read Formula/$FORMULA.rb"
}

test_unreadable_current_formula_fails_even_with_bootstrap() {
  default_world 1.2.2 1.2.3
  printf 'class TsCrap < Formula\nend\n' > "$T/tap/Formula/$FORMULA.rb"
  "$REAL_GIT" -C "$T/tap" commit -q -am 'drop the version'
  run_verify ALLOW_BOOTSTRAP=true
  bad_exit; no_candidate
  out_has "cannot read the current formula version"
}

# ── the release must be the one expected ─────────────────────────────────────

test_prerelease_is_rejected() {
  default_world 1.2.2 1.2.3
  write_release v1.2.3 false true "$FORMULA.rb"
  run_verify
  bad_exit; no_candidate
  gh_not_called "release download"
}

test_release_without_the_expected_asset_is_rejected() {
  default_world 1.2.2 1.2.3
  write_release v1.2.3 false false other.rb
  run_verify
  bad_exit; no_candidate
  out_has "exactly one asset named $FORMULA.rb"
  gh_not_called "release download"
}

# ── hostile input is rejected before anything runs ───────────────────────────

# reject_input VAR VALUE: the script must refuse it without calling gh at all.
reject_input() {
  [ -d "$T/tap" ] || default_world 1.2.2 1.2.3
  rm -f "$T/pwned" "$T/github-output"; : > "$T/gh.log"
  run_verify "$1=$2"
  bad_exit; gh_silent; no_candidate
  [ ! -e "$T/pwned" ] || _no "injected command ran for $1=$2"
}

test_malicious_formula_name_is_rejected() {
  reject_input FORMULA 'x;rm -rf /'
  out_has "invalid FORMULA"
}

test_malicious_inputs_never_execute() {
  local bad
  for bad in 'x$(touch $T/pwned)' 'x`touch $T/pwned`' 'x && touch $T/pwned' '../x' 'X' '-x' '' 'a b'; do
    reject_input FORMULA "$bad"
  done
  for bad in 'a/b;touch $T/pwned' 'a/b/c' 'a/$(touch $T/pwned)' '/b' 'a/' 'a b/c'; do
    reject_input SOURCE_REPOSITORY "$bad"
  done
  for bad in '.github/workflows/../../x.yml' '.github/workflows/a b.yml' 'release.yml' '.github/workflows/x.yml;touch $T/pwned' '/.github/workflows/x.yml' '.github/workflows/x.sh' '.github/workflows/'; do
    reject_input WORKFLOW_PATH "$bad"
  done
  for bad in '../main' 'main;touch $T/pwned' 'a//b' '-main' 'main/' 'a..b' 'main.lock' '$(x)'; do
    reject_input BASE_BRANCH "$bad"
  done
  for bad in yes True 1 '' 'true;touch $T/pwned'; do
    reject_input ALLOW_BOOTSTRAP "$bad"
  done
  reject_input GITHUB_REPOSITORY 'a/b;touch $T/pwned'
}

test_missing_input_is_rejected() {
  default_world 1.2.2 1.2.3
  run_verify FORMULA=
  bad_exit; gh_silent; no_candidate
}

# ── main ─────────────────────────────────────────────────────────────────────

[ "$HAVE_RUBY" = 1 ] || echo "note: ruby is not installed; using a stub for 'ruby -c'"

for name in $(declare -F | sed -n 's/^declare -f test_//p'); do
  t "$name"
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  printf 'failed: %s\n' "${failures[*]}"
  exit 1
fi
[ "$passed" -gt 0 ] || { echo "no tests matched '$ONLY'" >&2; exit 1; }
