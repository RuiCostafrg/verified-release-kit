# Inventory of copied CI and release plumbing

Surveyed 2026-11-13/14 from read-only clones of every repository under
`RuiCostafrg` (`gh repo list`, 12 repositories), at these `main` commits:

| Repository | `main` | Has `scripts/local-ci.sh` |
|---|---|---|
| pi-android-screenshots | `b501b0b` | yes |
| pi-droid (fork) | `b803a78` | yes |
| fantastic-pi-mobile | `dbd2bca` | yes |
| forge-ios | `f1f91f0` | yes |
| forge-android | `30abecf` | yes |
| dotnet-crap | `0224849` | yes |
| homebrew-tap | `51ff345` | yes |
| typescript-crap | `9907f22` | yes |
| oximut | `1a16520` | no |
| homebrew-oximut (private) | `18c8c5a` | no |
| pi-android-perf (private) | `f0cc4de` | no |
| termux-pi-reliability (private) | `dbeec53` | no |

On 2026-11-19, `gh repo list` returned 13 repositories. The additional
`crap-agent-tools` repository (`2cfb12c`) has no copy. Four previously
surveyed `main` tips had changed. The runner files at homebrew-tap
`f30c8ae`, typescript-crap `8798a99`, and dotnet-crap `eac6fcf` are
byte-identical to the versions above. oximut `62c08df` still has no copy.
The other eight tips match the table. The line references in the drift
report therefore also apply at the refresh date.

The local checkouts were read with `--no-optional-locks` and not changed.
The local typescript-crap and dotnet-crap checkouts hold
the same `local-ci.sh` bytes as their `origin/main`. The local fantastic-pi-mobile
checkout is on `feat/shared-conversation-core`, which branched before the script was
added and has no copy.

Drift that looks like bugs is in [DRIFT.md](DRIFT.md). This file covers what
exists and what is shared.

## 1. `scripts/local-ci.sh`: eight copies, none byte-identical

| Repository | Lines | sha256 (12) | Last change on `main` | Runner core | Stages (default **bold**) | Per-repo extras |
|---|---|---|---|---|---|---|
| pi-android-screenshots | 92 | `5f69b90f9797` | `9bd1c9c` 11-06 | A1 | **tests** | `node_min`, `prepare` (`npm ci --omit=peer --ignore-scripts`) |
| pi-droid | 95 | `bef5013319db` | `25f86e9` 11-06 | A1 | **lint build tests** | `node_min`, `prepare` (`npm ci`) |
| fantastic-pi-mobile | 107 | `322b60fdd85f` | `cf8d4f0` 11-06 | A2 | **bridge android** | `node_min`; Java 17 / Android SDK checks |
| forge-ios | 93 | `917f820e9898` | `12ee0ad` 11-06 | B | **tests** | Swift toolchain |
| forge-android | 108 | `e8b7f274d248` | `d9f2f31` 11-06 | B | **verify** | `--publish` option; env-var inputs; uploads a release asset |
| dotnet-crap | 132 | `2c7c73849011` | `97a3f24` 11-06 | B | **tests lint security** mutation e2e | pinned `cargo-audit` / `cargo-mutants` hints |
| homebrew-tap | 155 | `f5f5b8506f38` | `51ff345`¹ 11-11 | C1 | **workflows** install | checksum-pinned actionlint download |
| typescript-crap | 175 | `833becbe1e41` | `ff1ad54` 11-07 | C2 | **tests lint docs** coverage security | global `node_min 24` |

¹ `51ff345` ("Sync verified dotnet-crap releases") changed only the stage list;
the runner core was last changed by `5c9aada` on 11-07.

### What is identical, block by block

Each copy has the same layout: header comment, `set -euo pipefail`,
stage lists, helpers, Linux guard, argument loop, signoff pre-check, stages,
runner. Hashing each block separately:

| Block | Identical in | Differs in |
|---|---|---|
| Helpers `_fail` `_log` `_ok` `require` | all 8 | none |
| `node_min` | the 4 copies that have it | none |
| Linux guard | all 8 apart from the message suffix | message only |
| Argument loop | 7, ignoring the `--help` line | forge-android (`--publish`); the `--help` `sed` line range differs in every copy |
| Signoff pre-check | 7 | dotnet-crap (longer `require gh` message) |
| Runner section (`# ── runner` to end) | five variants, below | |

### The five runner cores

All eight descend from one commit made in each repository between 18:02 and
18:05 (UTC+1) on 2026-11-06, titled "ci: add Linux local CI checks with
gh-signoff". The same series of review fixes was then applied repository by
repository. Where each copy stopped in that series decides its core:

| Core | Copies | Review fixes on `main` | Runner lines |
|---|---|---|---|
| **A1** | pi-android-screenshots, pi-droid (identical runner sections) | errexit-safe stage runner only | 38 |
| **A2** | fantastic-pi-mobile | + fail fast on a dirty tree (still `git status \| grep -q .`) | 41 |
| **B** | forge-ios, forge-android, dotnet-crap (identical runner sections) | + dirty-tree check via `[ -n "$(git status --porcelain)" ]` | 41 |
| **C1** | homebrew-tap | + 11-06 evening and 11-07 series: repository anchor, `--commit` binding, untracked files, unposted status fails the run, HEAD and tree unchanged after a stage, pre-run `git status` failure | 71 |
| **C2** | typescript-crap | C1 + post-stage `git status` failure (`ff1ad54`) | 76 |

C2 is the most complete. C1 differs from C2 by exactly one fix
([DRIFT.md D8](DRIFT.md#d8)). A and B are missing most of the series. For A,
the fixes exist but were pushed to branches after the pull requests had
already merged ([DRIFT.md §3](DRIFT.md#3-stranded-fix-branches)).

### Older variants still on branches

| Repository | Branch | Script blob | Relationship to `main` |
|---|---|---|---|
| pi-android-screenshots | `ci/local-signoff` | `23df10dfc3` | 8 fix commits ahead, never merged |
| pi-droid | `ci/local-signoff` | `a48dfa17e8` | 8 fix commits ahead, never merged |
| fantastic-pi-mobile | `ci/local-signoff` | `d69133bc7f` | 7 fix commits ahead, never merged |
| forge-ios, forge-android, dotnet-crap | `ci/local-signoff`, `ci/local-signoff-dirty` | various | merged, superseded |

Some unmerged feature branches predate the script and carry no copy:
fantastic-pi-mobile `feat/shared-conversation-core`, the `docs/*` banner
branches, and several typescript-crap branches. Merging them does not
touch the script.

### What each repository really supplies

Without the shared core, each copy reduces to the following:

- a name and a one-line description for `--help`
- available and default stage lists
- the `stage_<name>` functions, and for two repositories a `prepare` hook
- forge-android only: one extra option, `--publish`

That is the shape of the stage file the shared runner takes
([local-ci.md](local-ci.md)).

## 2. `docs/local-ci.md`: eight copies, none identical

35 to 47 lines each, with one common skeleton: setup, usage, an optional
merge requirement. Only homebrew-tap and typescript-crap describe `--commit`
binding (line 31 and line 32), which matches their scripts. The other six
describe no integrity guarantees, which also matches their scripts. The docs
have not drifted from their own scripts. The scripts have drifted from
each other.

## 3. Verified release distribution: typescript-crap and dotnet-crap

This table records the November 13/14 snapshot. dotnet-crap removed the npm
channel by the November 19 refresh. See the
[current comparison and extraction priorities](release-verification.md).

| File | typescript-crap | dotnet-crap | Diff lines | Note |
|---|---|---|---|---|
| `dist-workspace.toml` | yes | yes | 4 | installer list, target order, one Windows runner |
| `scripts/install-dist.py` | 53 | 53 | **0** | byte-identical |
| `scripts/verify-npm-packages.py` | 100 | 102 | 28 | near-identical |
| `scripts/npm-packages.py` | 199 | 236 | 167 | same job, diverged |
| `scripts/verify-npm-install.py` | 259 | 188 | 229 | same job, diverged |
| `scripts/verify-installation.py` | 260 | 406 | 494 | same job, diverged |
| `scripts/prepare-release.py` | 47 | 81 | 104 | same job, diverged |
| `.github/workflows/verify-published.yml`, `verify-release.yml`, `npm-install.yml`, `installation.yml`, `release.yml`, `advisories.yml`, `github-action.yml` | yes | yes | not diffed | same names in both |

Both `release.yml` files attest with `actions/attest-build-provenance` at the
same pinned SHA (`4d10147…`, v4), including the Homebrew formula that the tap
verifies. Ranking what to extract here is milestone M6.

## 4. Homebrew taps

**homebrew-tap** (public): `.github/workflows/sync.yml` runs hourly at minute 17
and on dispatch by the owner (actor id 35194998). It has two near-duplicate job
pairs, `verify`/`publish` for ts-crap and `verify-dotnet-crap`/`publish-dotnet-crap`.
Each pair finds a newer stable release, skips it when an update PR is already
open, downloads the formula from the release, and runs
`gh attestation verify` against the source repository, the release workflow,
`refs/tags/<tag>` and the tag's commit, with `--deny-self-hosted-runners`. The
formula is checked with `ruby -c`, never evaluated, and handed over as an
artifact. The publish job runs in the `homebrew` environment, which requires
approval from RuiCostafrg and is limited to the `main` branch. It opens a PR
with a temporary `GITHUB_TOKEN` and dispatches `ci.yml`. The two pairs have
already drifted from each other; see [DRIFT.md D13](DRIFT.md#d13). When this
was surveyed, the 2026-11-13 07:59 UTC run had `publish-dotnet-crap` waiting
for approval. This work did not touch it.

**homebrew-oximut** (private): no sync workflow. `ci.yml` installs and smoke-tests
the tap checkout. Its scripts are near-copies of oximut's:

| Script | homebrew-oximut | oximut | Diff lines |
|---|---|---|---|
| `scripts/candidate-sandbox.py` | 129 | 117 | 16 |
| `scripts/smoke-install.py` | 147 | 132 | 33 |
| `scripts/verify-source-identity.py` | 30 | (none) | tap-only |

## 5. Not duplicated

pi-android-perf and termux-pi-reliability have no local CI runner and no
release plumbing. oximut has its own source-release scripts. Their only
duplication is the two scripts above, which the private tap copied.
