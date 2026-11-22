# Proposal for a reusable verified Homebrew sync

Extract the read-only verification job first. Keep the hourly schedule and the
approval-gated publish jobs in `homebrew-tap`. This moves the provenance policy
to one place while keeping branch writes, PR creation, and CI dispatch in the
repository whose owner approves them.

## Workflow contract

The kit would expose a `workflow_call` workflow. The tap would pin it by full
commit SHA and call it once per formula. Use two named calls so each formula
has its own outputs and approval history. The workflow receives these inputs
from the checked-in caller configuration.

| Input | Purpose |
|---|---|
| Source repository and attesting workflow path | Expected repository and exact `.github/workflows/release.yml` path |
| Formula name | Derive the exact asset filename, `Formula/<name>.rb`, and the update branch |
| Allow missing formula or no published release | Explicit bootstrap policy, initially matching dotnet-crap |
| Tap base branch | Expected caller branch and current formula source, initially `main` |

Require `contents: read` and `pull-requests: read` in both caller and callee,
with read access to attestations if the API requires it. Use the caller's
short-lived token. Each name and path is validated before use. Keep release
metadata out of shell source by passing values through environment variables
or argument arrays. The repository, branch, and owner-only dispatch guard
remain in the tap's caller. The called workflow uses the caller's GitHub
context and cannot raise its token permissions.
[GitHub reusable workflow reference](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations)

1. Read the release and the current formula version from the caller's base
   commit. Skip older or equal stable versions and existing update PRs.
   Treat a missing release as a bootstrap no-op only after confirming source
   repository access and only when the caller opted in. A malformed formula
   fails verification even in bootstrap mode.
2. Resolve the full `refs/tags/<tag>` to its source commit, including annotated
   tags. Download the one expected asset for that release. Verify the asset
   with `gh attestation verify` scoped to the source repository, with exact
   certificate identity for the expected workflow at that tag, exact source
   ref and digest, the build-provenance predicate, and
   `--deny-self-hosted-runners`. This standardizes on the stricter identity
   check already used for dotnet-crap. Confirm both projects' published
   attestations satisfy it before cutting over.
3. Run `ruby -c` without loading the formula and check its declared version
   against the tag. Record the tag, source SHA, workflow identity, formula
   SHA-256, tap base SHA, and artifact ID in the run summary. Return the
   candidate metadata and the same-run artifact ID to the caller. A verifier
   error fails the job and suppresses publication.
   [GitHub CLI attestation verifier](https://cli.github.com/manual/gh_attestation_verify)

## Adoption in homebrew-tap

- Keep `17 * * * *`, `workflow_dispatch`, the owner ID and `refs/heads/main`
  checks, and the existing tap-wide concurrency group. Replace the two
  verification jobs with SHA-pinned calls using `RuiCostafrg/typescript-crap`
  and `RuiCostafrg/dotnet-crap`. Both use `release.yml`, with formula names
  `ts-crap` and `dotnet-crap`. The top-level job names may stay to minimize
  changes to the dependency graph.
- Retain the existing `homebrew` environment on the tap's publish jobs. When
  there is a candidate, the owner can compare the exact verified tag, commit,
  and formula hash before approving. The existing reviewer and deployment
  branch policy stay with the tap. A job using a reusable workflow is a call
  and cannot also declare an environment. Keeping the privileged job local
  preserves the gate and makes its write permissions visible to tap reviewers.
  [GitHub workflow call keywords](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations#supported-keywords-for-jobs-that-call-a-reusable-workflow)
- After approval, use `contents: write`, `pull-requests: write`, and
  `actions: write` only in the publish jobs. Download the exact same-run
  artifact ID. Verify the formula digest, recheck tag identity and the tap
  formula version on the current base, and check again for an existing PR.
  Skip an already-applied candidate and require a fresh verification and
  approval if the release identity changes. Write just the intended formula
  to the deterministic update branch and dispatch `ci.yml` for that branch.
  Open the PR after successful dispatch. On retry, reuse a branch only after
  verifying that it contains the same candidate and no unrelated changes.
  The owner merges through ordinary branch protection.
- First validate fixtures for both projects with write steps absent. Cover
  wrong workflow/ref/commit, altered asset, missing or expired artifact,
  malformed formula, stale update, bootstrap, existing PR, and dispatch
  failure. In the tap, compare one read-only run to the current verifier
  against the same releases before replacing the existing jobs. Roll back
  by restoring the original verifier jobs or the previous verified SHA.

## Risks and limits

Central verification code becomes part of the release trust chain. A pinned
reviewed commit and pinned action dependencies make changes explicit. A
public tap must be able to access the workflow repository. Decide where the
workflow will live before adoption.

A release tag can move, a newer formula can land, or an artifact can expire
while approval is pending. Rechecks protect against stale inputs and should
fail closed on errors. Workflow artifacts need a retention period that
covers normal approval delays. A branch can also be left behind by a
partially failed publish, which is why retries must validate ownership and
content before using it. Tap CI should still validate installation. The
attestation authenticates the formula bytes and their origin, while
`ruby -c` checks their syntax.

The private `homebrew-oximut` tap currently smoke-tests a source-install
formula and verifies source identity. It would need a compatible published
formula asset and provenance policy before using this verifier. Keep its
candidate sandbox and source identity checks. Review private source
attestation access and environment approval support before treating that
tap as an adopter. Its source metadata and tarball identity are a separate
distribution contract.

## Implementation

- `.github/workflows/verify-homebrew-formula.yml`: the `workflow_call`
  workflow. Inputs are `source-repository`, `workflow-path`, `formula`,
  `allow-bootstrap` and `base-branch`. Outputs are `candidate`, `tag`,
  `source-sha`, `formula-sha256` and `artifact-id`. It has read permissions
  only, and all actions are pinned by commit SHA.
- `scripts/verify-homebrew-formula.sh`: the verification logic. It validates
  every input, reads only through `gh`, and fails closed. It runs locally with
  the environment variables listed in its header.
- `tests/verify-homebrew-formula.test.sh`: offline tests using a fake `gh` and
  real temporary git repositories. Run `bash tests/verify-homebrew-formula.test.sh`.
- `docs/adoption/homebrew-tap-verify-shadow.yml`: a read-only,
  `workflow_dispatch`-only caller for the tap that runs both formulas and
  writes the results to the job summary. Replace `<KIT_SHA>` before use.

A called workflow cannot see its own commit, so the workflow asks the caller's
run (`referenced_workflows`) for the pinned commit and checks out the script
from it. This is why callers must also grant `actions: read` and
`attestations: read`.
