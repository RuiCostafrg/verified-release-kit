# Pilot for homebrew-tap

At `f30c8aef6049d35a9a5cc92e0c669d0cd054e5b5`, homebrew-tap is the
smallest runner consumer by tracked files and bytes (11 files, 32,085
bytes). The next smallest is pi-android-screenshots (12 files, 92,711
bytes).

The [patch](homebrew-tap.patch) replaces the tap runner with the shared
bytes and a checksum. The `run_actionlint`, `stage_workflows`, and
`stage_install` bodies are copied unchanged into
`scripts/local-ci.stages.sh`. The patch also updates the runner usage doc.
The patch touches only those four local CI files.

| Behavior | Before | With the patch |
|---|---|---|
| Default stage | `workflows`, running actionlint and Ruby syntax checks | Same commands |
| Optional stage | `install`, building each formula and invoking its CLI | Same commands |
| Signoff after `install` | The extension parses the stage as its `install` ruleset command and rejects `--commit` | Explicit `create --commit <tested SHA> install` posts the intended context |
| Git status fails after a stage | An empty output can be treated as clean | Run fails before posting a green status |

In a temporary Linux arm64 clone, both original and patched runners passed
the default `--no-signoff` stage with actionlint 1.7.12 and Ruby 3.3.8.
Both formulas passed `ruby -c`. With the optional stage, test doubles for
`brew`, `dotnet-crap`, and `ts-crap` recorded the same six calls in
the same order. A full Homebrew install was outside this verification.
The signoff command was tested separately with real gh-signoff v0.4.1
and a fake GitHub API in the drift harness.

The patch passed `git apply --check` against a pristine clone at the
specified base. No GitHub status or workflow dispatch was sent.

Use these commands to inspect the patch in a disposable clone.

```bash
git apply --check /path/to/verified-release-kit/docs/pilot/homebrew-tap.patch
git apply /path/to/verified-release-kit/docs/pilot/homebrew-tap.patch
scripts/local-ci.sh --no-signoff
```
