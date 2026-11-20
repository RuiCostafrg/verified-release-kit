# Pilot for homebrew-tap

At `f30c8aef6049d35a9a5cc92e0c669d0cd054e5b5`, homebrew-tap is the
smallest runner consumer by tracked files and bytes (11 files, 32,085
bytes). The next smallest is pi-android-screenshots (12 files, 92,711
bytes).

The [patch](homebrew-tap.patch) vendors the shared runner and checksum and
moves the tap's checks into `scripts/local-ci.stages.sh`. It also updates
the local CI usage doc. The patch touches only those four local CI files.

| Behavior | Before | With the patch |
|---|---|---|
| Default stage | `workflows`, running actionlint and Ruby syntax checks | Same commands |
| Optional stage | Passes an absolute formula file path, which Homebrew 7.0.15 rejects | Installs each formula by its tap-qualified name and checks that Homebrew is using this checkout |
| Signoff after `install` | The extension parses the stage as its `install` ruleset command and rejects `--commit` | Explicit `create --commit <tested SHA> install` posts the intended context |
| Git status fails after a stage | An empty output can be treated as clean | Run fails before posting a green status |

In a temporary Linux arm64 clone, both original and patched runners passed
the default `--no-signoff` stage with actionlint 1.7.12 and Ruby 3.3.8.
Both formulas passed `ruby -c`. A follow-up with real Homebrew 7.0.15
reproduced the original formula-path error. The patch uses names such as
`RuiCostafrg/tap/dotnet-crap` so Homebrew loads formulas it recognizes.
The updated runner installed dotnet-crap 0.2.0 and ts-crap 2.6.1 from a
temporary local tap, and both CLIs passed `--version` and `--help`. A
checkout outside that tap was rejected before installation.
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

For a fresh install check, use a disposable Homebrew prefix with neither
formula installed. Apply the patch to the Homebrew tap checkout itself.
If the tap is registered under a different name, set `LOCAL_CI_BREW_TAP`
to that name before running `scripts/local-ci.sh --no-signoff install`.
