# Local CI drift

Line references below point to `scripts/local-ci.sh` at the commits in the
[inventory](INVENTORY.md), unless another path is named. The newer November 19
tips have the same runner blobs. The probes use throwaway git repositories
and the real gh-signoff v0.4.1 (`02e0cf9c11c9a1587784fec17c07b93fcb22ec24`)
behind a fake GitHub CLI. The probes override stages to induce the specified
condition, with separate checks for the two real stages in D11 and D12.
Any git pushes in the fixtures go to temporary local bare repositories.
The shared runner passed all 13 runner probes. D1–D12 were reproduced.
D13 comes from static review.

To repeat the probes, use temporary clones at the inventory commits and a
checkout of gh-signoff at the revision above.

```bash
tests/drift/probe-legacy.sh --clones /path/to/clones \
  --gh-signoff /path/to/gh-signoff/gh-signoff --repeat 3
```

## 1. Shared runner

### D1

**Dirty checkout runs checks and exits successfully without signing off.**
pi-android-screenshots:64–66 and pi-droid:67–69 only warn. The other six
copies reject a signed-off run at this point (fantastic-pi-mobile:74–81,
forge-ios:60–67, forge-android:75–82, dotnet-crap:99–106, homebrew-tap:104–113,
typescript-crap:119–128). Reproduced in both older copies with a tracked
edit. The stage ran, no success status was posted, and exit was 0.

### D2

**Large dirty trees can slip through the check.** pi-android-screenshots:64,
pi-droid:67 and fantastic-pi-mobile:74 pipe `git status` into `grep -q`.
Under `pipefail`, grep can find a match and exit early, leaving git with
SIGPIPE, which makes the whole condition false. The other five copies
capture status output without an early-closing pipe. The large-output
probe reproduced the missed warning in all three attempts per affected copy
with 4,000 untracked files.

### D3

**A failing pre-run `git status` can read as a clean checkout.**
pi-android-screenshots:64, pi-droid:67, fantastic-pi-mobile:74, forge-ios:60,
forge-android:75 and dotnet-crap:99 test the result inside a condition
without separately checking git's exit code. homebrew-tap:104–105 and
typescript-crap:119–120 check the command outcome first. All six affected
copies ran stages, posted green statuses and returned 0 in the probe.

### D4

**Six copies let Git config hide untracked files.** The same six check
sites listed in D3 omit `--untracked-files=normal`. With
`status.showUntrackedFiles=no`, a scratch file can escape the check. The
option is forced at homebrew-tap:104,135 and typescript-crap:119,152.
All six affected copies posted green with the untracked file present.

### D5

**Stages and status can use the caller's checkout.** The runner blocks
beginning at pi-android-screenshots:55, pi-droid:58, fantastic-pi-mobile:67,
forge-ios:53, forge-android:68 and dotnet-crap:92 omit repository anchoring.
homebrew-tap:87–93 and typescript-crap:102–108 resolve the script path and
change to its repository. The probe launches each script from a different
clean checkout with its own pushed HEAD. All six affected copies posted
green to the caller's commit.

### D6

**A commit created and pushed mid-stage can receive an unearned green status.**
pi-android-screenshots:78–84, pi-droid:81–87, fantastic-pi-mobile:93–99,
forge-ios:79–85, forge-android:94–100 and dotnet-crap:118–124 leave commit
selection to gh-signoff and omit the post-stage tree and HEAD checks.
homebrew-tap:119–141 and typescript-crap:134–161 capture HEAD, pass
`--commit`, and compare the post-stage HEAD and tree before publishing.
All six affected copies posted green to the newly pushed fixture commit.
When a stage instead left an untracked file, gh-signoff rejected the status
but all six runners still returned 0.

### D7

**An unposted status can still leave a zero exit code.**
pi-android-screenshots:83–84, pi-droid:86–87, fantastic-pi-mobile:98–99,
forge-ios:84–85, forge-android:99–100 and dotnet-crap:123–124 only print
a warning when status creation fails. homebrew-tap:141–148 and
typescript-crap:161–168 mark the run unsuccessful. The probe makes the
status API return HTTP 422. All six affected copies returned 0.

### D8

**homebrew-tap misses the post-stage `git status` failure check.**
At homebrew-tap:134–135 the substitution is inside a test and stderr
can be the only evidence of failure. typescript-crap:149–155 has the
additional fix in `ff1ad54`: it checks a plain assignment before using
the output. The six earlier runner versions have no post-stage check.
The probe induced a post-stage status error. All seven affected copies,
including homebrew-tap, posted green anyway and returned 0.

### D9

**Help prints part of the script, and two repos prepare before validating a
stage name.** Observed `--help` printing shell code at pi-android-screenshots:35,
pi-droid:36, fantastic-pi-mobile:36, forge-ios:30, forge-android:35 and
dotnet-crap:33. The fixed header ranges are at homebrew-tap:31 and
typescript-crap:36. pi-android-screenshots:57–62 and pi-droid:60–65 invoke
`prepare` (including `npm ci`) before rejecting an unknown stage. The probe
confirmed both scripts ran the preparation stub first. The
shared runner validates the selection before preparation and generates
help from the stage list.

### D10

**The `install` stage collides with a gh-signoff subcommand.** homebrew-tap
defines a real `install` stage at line 73 and calls
`gh signoff --commit "$head_sha" "$s"` at line 141. With v0.4.1 this parses
as a ruleset-management command and rejects `--commit`. In the older
implicit-signoff runners, a synthetic `install` stage routes to the
ruleset command without `--commit`, so this also matters when adding stages.
Reproduced with the real extension and a fake API. The successful shared
invocation is `gh signoff create --commit <sha> install`.

All eight copies also pipe `gh extension list` through `grep -q` on
lines 45, 46, 46, 40, 45, 43, 41 and 46 respectively, in inventory order.
A sufficiently long list can make the producer hit SIGPIPE and wrongly
report the extension missing. Reproduced in all three attempts per copy.
This shared bug fails closed. All eight
already have the November errexit fix: a stage runs with `set -e` in a
subshell outside an `if` or `||` condition.

## 2. Repository-specific findings

### D11

**typescript-crap lint can pass when package listing fails.**
`scripts/local-ci.sh:67–69` runs `cargo package --list | grep -E ...` as
an `if` condition. A cargo error becomes indistinguishable from an empty
list of forbidden paths. Reproduced at `9907f22`: a stub cargo exits 101
for package listing, then the lint stage reports success and exit 0.
During migration, capture the listing with a checked exit status before
testing its contents.

### D12

**forge-android verify leaves a dirty checkout and exits 0 without a status.**
`scripts/local-ci.sh:56–59` writes the APK and checksum to the worktree.
`.gitignore:8` ignores the APK, but the new checksum remains untracked.
Reproduced at `30abecf` with fake APK bytes and the matching checksum:
the stage passed, gh-signoff rejected the dirty tree, and the script
returned 0. The pilot for that repo should move its generated files
outside the worktree, with the publication option preserved explicitly.
The probe never invokes `--publish`.

### D13

**The tap's two nearly identical job pairs have different retry and
provenance policies.** Static review of homebrew-tap
`.github/workflows/sync.yml`, unchanged at `f30c8ae`:

- Lines 29–44 and 124–167 treat missing releases, missing formulae, and
  PR-read permissions differently. The dotnet-crap bootstrap fallback at
  156–161 also treats an existing formula with an unparseable version as
  missing.
- Lines 69–71 constrain the TypeScript signer workflow path and source ref
  independently. Lines 187–189 require the exact tagged certificate
  identity for dotnet-crap as well as source ref and digest.
- Lines 103–117 create the TypeScript update branch once and open the PR
  before dispatch. A dispatch failure leaves an open PR that subsequent
  scheduled runs skip. A leftover branch from an earlier failure can also
  block the next attempt. Lines 223–250 let dotnet-crap retry an existing
  branch and dispatch before creating the PR. Its force-reset deserves
  review before reusing that retry strategy.

These are static findings. The live sync was read only, and the proposal
describes how to retain verification and approval during a later migration.

## 3. Stranded fix branches

These commits are in `origin/ci/local-signoff` and missing from the
surveyed `main` in each repo. Entries are ordered oldest first.

### pi-android-screenshots

- `c83538bef558fed3ec115e76590a7749abf6c3c4` fix: fail fast on a dirty tree before running signed-off checks (coderabbit)
- `ea88dd5cae3525b874f45951c677b1f1b53da38d` fix: dirty-tree check without SIGPIPE skip; validate stages before prepare
- `ab82a23ae3acffde05fa62c5dfd1180aaeb0dc7d` fix: --help prints exactly the header comment (cubic P3)
- `9e67742c4ca101135055d8962e9333e38994b994` fix: run local CI from the repo root regardless of invocation directory
- `7c38ccad8150e36bfaa2733b2b78dac9300548f3` fix: fail the run when a required signoff status cannot be posted (coderabbit)
- `b1e513667e6ef26f05111d3721e1d2f16eb27d9b` fix: detect untracked files regardless of status.showUntrackedFiles (coderabbit)
- `71369452af98fa54eb40b0da33219c3c01cc5240` fix: bind signoff statuses to the commit each stage actually tests (coderabbit)
- `d53aeb9fb295b32fc0f66d736219d3738b5ff491` fix: anchor the runner to the repository owning the script (coderabbit)

### pi-droid

- `cbb6c0859cbaa51df3cbf2270d70423d885caa1d` fix: fail fast on a dirty tree before running signed-off checks (coderabbit)
- `0adf771aaf7ca3691d3ee4a7c45dc52d7d9da81a` fix: dirty-tree check without SIGPIPE skip; validate stages before prepare
- `c43c2cfdd3e4e744b710d8bed327eebc314ccc0f` fix: --help prints exactly the header comment (cubic P3)
- `bba191956e1ae854d32040f70f99dd472603f549` fix: run local CI from the repo root regardless of invocation directory
- `f3ece1aca2f928e7f3a10cd952e0b8b68fffa788` fix: fail the run when a required signoff status cannot be posted (coderabbit)
- `9321e6c26ee50deb4cb54ad4160e8a154e200860` fix: detect untracked files regardless of status.showUntrackedFiles (coderabbit)
- `581779c646fafe92a2b1e46ee4703021681ede4d` fix: bind signoff statuses to the commit each stage actually tests (coderabbit)
- `03e76a11df4df22055b9ab1f4e9b9a72bff32105` fix: anchor the runner to the repository owning the script (coderabbit)

### fantastic-pi-mobile

- `452cf370bc2e15c4d83e55582c4813f90d9fb5e7` fix: dirty-tree check without SIGPIPE skip; validate stages before prepare
- `abcc23b4b85c402522bcb6c325447f31d4e183cf` fix: --help prints exactly the header comment (cubic P3)
- `e781b8c40d6356e0916858c1630af7c5802563e3` fix: run local CI from the repo root regardless of invocation directory
- `e2bffffe22ec8240fbe4ce6436c77e46d573d070` fix: fail the run when a required signoff status cannot be posted (coderabbit)
- `402a7d547f2acf60438dcecc70ffa744b39467a6` fix: detect untracked files regardless of status.showUntrackedFiles (coderabbit)
- `61f8f7fcbb0058d69f5540df75ffbe1534b6819b` fix: bind signoff statuses to the commit each stage actually tests (coderabbit)
- `36a879d770dab9b57f35575fbe51ee6dff64d0d0` fix: anchor the runner to the repository owning the script (coderabbit)
