#!/usr/bin/env bash
# Verify a published Homebrew formula's provenance. Read-only: it never writes
# to GitHub. Used by .github/workflows/verify-homebrew-formula.yml and runnable
# locally (it only needs `gh`, `jq`, `ruby`, `sha256sum`).
#
# Inputs (environment variables, every one validated before use):
#   SOURCE_REPOSITORY   owner/name that publishes the release
#   WORKFLOW_PATH       attesting workflow, e.g. .github/workflows/release.yml
#   FORMULA             formula name; asset is <FORMULA>.rb, file Formula/<FORMULA>.rb
#   ALLOW_BOOTSTRAP     true|false: tolerate no release / no tap formula yet
#   BASE_BRANCH         tap branch holding the current formula
#   GITHUB_REPOSITORY   the tap (the caller); GH_TOKEN is used by gh
# Optional: GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, RUNNER_TEMP, VERIFY_DIR.
#
# Outputs (GITHUB_OUTPUT): candidate=true|false always; when candidate=true also
# tag, source-sha, formula-sha256, formula-path, artifact-name.
# Exit 0 means "decided" (candidate or a legitimate no-op); anything else fails.
set -euo pipefail
umask 077

OUTPUT_FILE="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/null}"
WORK=""
decided=0
keep_work=0

# Remove the scratch directory unless a verified file is being handed over.
# A failure before a decision always reports candidate=false.
cleanup() {
  local rc=$?
  if [ -n "$WORK" ] && { [ "$rc" -ne 0 ] || [ "$keep_work" -eq 0 ]; }; then rm -rf -- "$WORK"; fi
  if [ "$rc" -ne 0 ] && [ "$decided" -eq 0 ]; then
    printf 'candidate=false\n' >> "$OUTPUT_FILE" || true
  fi
  return "$rc"
}
trap cleanup EXIT

die() { printf 'verify-homebrew-formula: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >> "$SUMMARY_FILE"; }
no_candidate() {
  decided=1
  printf 'candidate=false\n' >> "$OUTPUT_FILE"
  note "$*"
  printf '%s\n' "$*"
  exit 0
}

# ── validate every input before it is used anywhere ─────────────────────────
need() { [ -n "${!1:-}" ] || die "$1 is required"; }
for v in SOURCE_REPOSITORY WORKFLOW_PATH FORMULA ALLOW_BOOTSTRAP BASE_BRANCH GITHUB_REPOSITORY; do need "$v"; done

repo_re='^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_][A-Za-z0-9._-]{0,99}$'
[[ "$SOURCE_REPOSITORY" =~ $repo_re ]] || die "invalid SOURCE_REPOSITORY"
[[ "$GITHUB_REPOSITORY" =~ $repo_re ]] || die "invalid GITHUB_REPOSITORY"
[[ "$WORKFLOW_PATH" =~ ^\.github/workflows/[A-Za-z0-9][A-Za-z0-9._-]{0,99}\.ya?ml$ ]] || die "invalid WORKFLOW_PATH"
[[ "$FORMULA" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || die "invalid FORMULA"
[[ "$ALLOW_BOOTSTRAP" =~ ^(true|false)$ ]] || die "ALLOW_BOOTSTRAP must be true or false"
[[ "$BASE_BRANCH" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$ ]] || die "invalid BASE_BRANCH"
case "$BASE_BRANCH" in *..* | *//* | */ | *.lock) die "invalid BASE_BRANCH" ;; esac

for tool in gh jq ruby sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

if [ -n "${VERIFY_DIR:-}" ]; then
  WORK="$VERIFY_DIR"
  [ ! -e "$WORK" ] || die "VERIFY_DIR already exists"
  mkdir -p -- "$WORK"
else
  WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/verify-formula.XXXXXX")"
fi

# ── helpers ─────────────────────────────────────────────────────────────────
# gh_get ARGS...: run gh api, stdout on success; on failure stderr is kept in
# $WORK/err so callers can tell a 404 from any other failure.
gh_get() {
  gh api "$@" 2> "$WORK/err"
}
is_404() { grep -q 'HTTP 404' "$WORK/err"; }

semver_gt() { # semver_gt A B: A > B for X.Y.Z
  local IFS=.
  local -a a b
  read -r -a a <<< "$1"
  read -r -a b <<< "$2"
  local i
  for i in 0 1 2; do
    if (( 10#${a[i]} > 10#${b[i]} )); then return 0; fi
    if (( 10#${a[i]} < 10#${b[i]} )); then return 1; fi
  done
  return 1
}

# formula_version FILE: the single declared `  version "X.Y.Z"`, else fail.
formula_version() {
  local lines
  lines="$(grep -E '^  version "[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}"$' -- "$1" || true)"
  [ -n "$lines" ] && [ "$(printf '%s\n' "$lines" | wc -l)" -eq 1 ] || return 1
  sed -E 's/^  version "([^"]+)"$/\1/' <<< "$lines"
}

# ── 1. release, current formula, existing PR ────────────────────────────────
full_name="$(gh_get "repos/$SOURCE_REPOSITORY" --jq .full_name)" \
  || die "cannot access source repository $SOURCE_REPOSITORY: $(cat "$WORK/err")"
[ "${full_name,,}" = "${SOURCE_REPOSITORY,,}" ] || die "source repository resolved to a different name"

if ! gh_get "repos/$SOURCE_REPOSITORY/releases/latest" > "$WORK/release.json"; then
  if is_404; then
    [ "$ALLOW_BOOTSTRAP" = true ] || die "$SOURCE_REPOSITORY has no published release and bootstrap is not allowed"
    no_candidate "$SOURCE_REPOSITORY has no published release yet; nothing to sync."
  fi
  die "cannot read the latest release: $(cat "$WORK/err")"
fi

tag="$(jq -er '.tag_name | strings' "$WORK/release.json")" || die "release has no tag"
draft="$(jq -r 'if (.draft | type) == "boolean" then .draft else "invalid" end' "$WORK/release.json")" || die "unreadable release"
prerelease="$(jq -r 'if (.prerelease | type) == "boolean" then .prerelease else "invalid" end' "$WORK/release.json")" || die "unreadable release"
[[ "$tag" =~ ^v[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$ ]] || die "expected a stable SemVer tag, got an invalid tag"
[ "$draft" = false ] && [ "$prerelease" = false ] || die "expected a stable release; $tag is a draft or prerelease"
version="${tag#v}"

base_sha="$(gh_get "repos/$GITHUB_REPOSITORY/commits/$BASE_BRANCH" --jq .sha)" \
  || die "cannot resolve $BASE_BRANCH in $GITHUB_REPOSITORY: $(cat "$WORK/err")"
[[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] || die "unexpected base commit"

if gh_get "repos/$GITHUB_REPOSITORY/contents/Formula/$FORMULA.rb?ref=$base_sha" \
     -H 'Accept: application/vnd.github.raw+json' > "$WORK/current.rb"; then
  current="$(formula_version "$WORK/current.rb")" || die "cannot read the current formula version from Formula/$FORMULA.rb"
  if ! semver_gt "$version" "$current"; then
    no_candidate "$FORMULA $tag is not newer than the current $current; nothing to sync."
  fi
elif is_404 && [ "$ALLOW_BOOTSTRAP" = true ]; then
  current=""
else
  die "cannot read Formula/$FORMULA.rb at $base_sha: $(cat "$WORK/err")"
fi

branch="releases/$FORMULA-$tag"
existing="$(gh pr list --repo "$GITHUB_REPOSITORY" --head "$branch" --base "$BASE_BRANCH" \
  --state open --json number --jq length)" || die "cannot list pull requests"
[[ "$existing" =~ ^[0-9]+$ ]] || die "unexpected pull request count"
if [ "$existing" -ne 0 ]; then
  no_candidate "An update PR for $FORMULA $tag is already open; no duplicate needed."
fi

# ── 2. resolve the tag to its commit, then verify provenance ────────────────
ref_line="$(gh_get "repos/$SOURCE_REPOSITORY/git/ref/tags/$tag" --jq '[.ref, .object.type, .object.sha] | @tsv')" \
  || die "cannot resolve refs/tags/$tag: $(cat "$WORK/err")"
IFS=$'\t' read -r got_ref obj_type obj_sha <<< "$ref_line"
[ "$got_ref" = "refs/tags/$tag" ] || die "tag lookup returned a different ref"
depth=0
while [ "$obj_type" = tag ]; do
  depth=$((depth + 1))
  [ "$depth" -le 5 ] || die "annotated tag chain is too deep"
  [[ "$obj_sha" =~ ^[0-9a-f]{40}$ ]] || die "unexpected tag object id"
  tag_line="$(gh_get "repos/$SOURCE_REPOSITORY/git/tags/$obj_sha" --jq '[.object.type, .object.sha] | @tsv')" \
    || die "cannot read annotated tag $obj_sha: $(cat "$WORK/err")"
  IFS=$'\t' read -r obj_type obj_sha <<< "$tag_line"
done
[ "$obj_type" = commit ] || die "refs/tags/$tag does not point at a commit"
[[ "$obj_sha" =~ ^[0-9a-f]{40}$ ]] || die "unexpected source commit"
source_sha="$obj_sha"

asset="$FORMULA.rb"
jq -e --arg n "$asset" '[.assets[]? | select(.name == $n)] | length == 1' "$WORK/release.json" >/dev/null \
  || die "release $tag must have exactly one asset named $asset"

mkdir -p -- "$WORK/download"
gh release download "$tag" --repo "$SOURCE_REPOSITORY" --pattern "$asset" --dir "$WORK/download" \
  || die "cannot download $asset from $tag"
file="$WORK/download/$asset"
[ -f "$file" ] && [ ! -L "$file" ] && [ -s "$file" ] || die "downloaded $asset is missing or not a regular file"
[ "$(find "$WORK/download" -mindepth 1 | wc -l)" -eq 1 ] || die "unexpected extra files in the download"

identity="https://github.com/$SOURCE_REPOSITORY/$WORKFLOW_PATH@refs/tags/$tag"
gh attestation verify "$file" --repo "$SOURCE_REPOSITORY" \
  --cert-identity "$identity" \
  --source-ref "refs/tags/$tag" --source-digest "$source_sha" \
  --predicate-type https://slsa.dev/provenance/v1 \
  --deny-self-hosted-runners >/dev/null \
  || die "attestation verification failed for $asset at $tag"

# ── 3. syntax and version, without ever loading the formula ─────────────────
ruby -c "$file" >/dev/null || die "ruby -c rejected $asset"
declared="$(formula_version "$file")" || die "$asset does not declare exactly one version"
[ "$declared" = "$version" ] || die "formula declares version $declared but the release tag is $tag"

formula_sha256="$(sha256sum -- "$file" | cut -d' ' -f1)"
[[ "$formula_sha256" =~ ^[0-9a-f]{64}$ ]] || die "could not hash $asset"

# Move the verified file to a stable location the caller can upload.
out_dir="$WORK/verified"
mkdir -p -- "$out_dir"
mv -- "$file" "$out_dir/$asset"
keep_work=1

note "### $FORMULA $tag"
note "- Source: \`$SOURCE_REPOSITORY\` at \`$source_sha\`"
note "- Workflow identity: \`$identity\`"
note "- Formula SHA-256: \`$formula_sha256\`"
note "- Tap base: \`$BASE_BRANCH\` at \`$base_sha\`${current:+ (current formula $current)}"

decided=1
{
  printf 'candidate=true\n'
  printf 'tag=%s\n' "$tag"
  printf 'source-sha=%s\n' "$source_sha"
  printf 'formula-sha256=%s\n' "$formula_sha256"
  printf 'formula-path=%s\n' "$out_dir/$asset"
  printf 'artifact-name=verified-formula-%s\n' "$FORMULA"
} >> "$OUTPUT_FILE"
printf 'Verified %s %s at %s\n' "$FORMULA" "$tag" "$source_sha"
