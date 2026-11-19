# verified-release-kit plan

Drafted 2026-11-13. `verified-release-kit` is a working name. The
implementing thread should correct this plan wherever its inventory
contradicts it.

## Goal

The CI and release plumbing copied across the RuiCostafrg repositories has one
home, so a fix lands once.

## Known facts

- There are eight copies of `scripts/local-ci.sh` across thirteen repositories,
  and none are byte-identical.
- Three repositories have review fixes stranded on branches pushed after
  their pull requests merged, so `main` is missing them.
- The tap's `install` stage collides with the `install` subcommand in
  gh-signoff v0.4.1.
- `homebrew-tap` syncs formulae hourly after verifying build provenance and
  requires approval in a protected `homebrew` environment. That pipeline is
  live and must not be triggered or modified by this work.

## Milestones

### M1 — Inventory and drift report

**Status:** Complete. Audited 13 repositories. Documented five runner cores, the drift probes, and all 23 stranded fix commits.

- `docs/INVENTORY.md`: every copy, what is common, what is per-repo.
- `docs/DRIFT.md`: each divergence that looks like a bug, with repository,
  file, line, and whether it was confirmed by running the script.
- List the stranded fix branches with the commits `main` is missing.

**Acceptance:** every drift finding is either reproduced or marked
unconfirmed. The stranded-branch list names exact commits.

### M2 — Shared runner

**Status:** Complete. Shared runner, stage contract, offline regression tests, and mutation checks.

- One `scripts/local-ci.sh` core: stage runner, clean-tree check,
  unchanged-HEAD check before signoff, option handling, signoff.
- Each repository supplies only its stages through a small stage file.
- Tests with a fake `gh` and a real git repository.

**Acceptance:** tests cover a dirty tree, a failing `git status`, a tree
changed mid-run, HEAD moved before signoff, a failing stage under `errexit`,
an unresolvable script path, and the `install` stage-name collision.

### M3 — Consumption model

**Status:** Complete. Vendoring is the recommendation. Offline checks compare against a trusted local kit revision.

- Recommend one way for repositories to consume the runner: vendored copy
  with a sync check, pinned download, or submodule.
- Implement the tooling for the recommended one only.

**Acceptance:** a repository can detect that its copy is out of date without
network access at check time, or the trade-off is stated plainly.

### M4 — Pilot migration

- Migrate the smallest repository that has the script, in a temp clone.
- Keep it as a patch in `docs/pilot/` with before and after behaviour.

**Acceptance:** the pilot's stages produce the same results as before. The
patch is not pushed.

### M5 — Verified Homebrew sync proposal

- A written proposal for a reusable workflow: inputs, permissions, the
  provenance checks it performs, and the approval gate.
- What `homebrew-tap` and `homebrew-oximut` would change to adopt it, and the
  risks.

**Acceptance:** a document only. No workflow is added to any live repository.

### M6 — Release verification scripts (survey)

- Compare the published-release verification scripts in `typescript-crap` and
  `dotnet-crap` and list what could be shared.

**Acceptance:** a ranked list with effort estimates. No extraction yet.

## Out of scope

- Pushing to, or opening pull requests against, any existing repository.
- Creating a GitHub repository for this kit.
- Changing release or tap workflows.

## Decisions for the owner

1. Consumption model.
2. Whether to land the stranded review fixes now, repository by repository,
   before any migration.
3. Final name and whether this becomes a public repository.
