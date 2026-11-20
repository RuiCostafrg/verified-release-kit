# Local CI rollout patches

The [homebrew-tap pilot](../pilot/README.md) passed a real install check.
These seven patches cover the other repositories that had a copy of the
runner. Each patch was prepared in a temporary clone and checked against
its base with `git apply --check`. All seven retained the same stage
lists, and each vendored copy matched the kit's runner and checksum.
The patches change local CI files only.

| Repository | Base | Patch |
|---|---|---|
| pi-android-screenshots | `b501b0b118a467a241c316f35c8ad6c68455f69e` | [Patch](pi-android-screenshots.patch) |
| pi-droid | `b803a78984aacd89ea9b66beae157560c21a041d` | [Patch](pi-droid.patch) |
| fantastic-pi-mobile | `dbd2bca17f80e5f190e9b5553904983beba63623` | [Patch](fantastic-pi-mobile.patch) |
| forge-ios | `f1f91f0560dda9dc6a5e7a1a3745f473847827` | [Patch](forge-ios.patch) |
| forge-android | `30abecf2d3638d257c910b18233ab9b6664c5b1a` | [Patch](forge-android.patch) |
| dotnet-crap | `87f4e19ec16c06a63c94495e5e0cce4e62bdd2b2` | [Patch](dotnet-crap.patch) |
| typescript-crap | `8798a99a0fabb92365cec0fe34f1bee4cba9a6f5` | [Patch](typescript-crap.patch) |

Forge Android checks the APK and checksum in a temporary directory and
cleans up afterward. The verification stage can therefore sign off a
clean checkout. Its explicit upload option remains available. The option
was exercised against a fake GitHub CLI using fixture bytes and a real
SHA-256 check. TypeScript lint now fails if Cargo cannot list the package
contents. The regression check covered a failed listing, forbidden
files, and a clean list. The .NET patch disables Python bytecode writes
during checks so generated caches stay out of the worktree.

The screenshot stage passed eight tests before and after the patch.
Pi Droid lint, build, and the 25-test ADB intents suite passed on both
versions with Linux Node 24. The Android build of Node could not load
Rollup's native dependency on this machine. The full Linux Vitest runs
both stopped making progress after the same test file and still need
a completed run before adoption.
Fantastic Pi Mobile's bridge suite passed 67 of 69 tests before and
after the patch on this machine. The same test in
`bridge/test/review.test.js` failed with “Session is closed” in both runs.
A second review test failed on the original runner, and a different
test timed out in `bridge/test/project-lifecycle.test.js` on the patched
runner. A focused log and reliability run passed all three tests in the
patched checkout. Recheck the full bridge suite on the normal CI
toolchain before adopting its patch.
Forge iOS's project validator passed without a Swift compiler. The Swift
stage and Fantastic Pi Mobile's Android stage still need Swift and a
Java 17/Android SDK setup, respectively. The .NET Python suite ran 249
tests with three skips and no failures. Rust formatting also passed in
both `*-crap` checkouts, and Cargo listed 193 clean files in the
TypeScript package. Full Rust and release checks remain to be run in
the consumer repositories before adoption.

Apply and test one patch at a time in a disposable checkout of its base.
For checks that expect a clean Git tree, such as Cargo's package listing,
test from a local commit in that disposable checkout. Use `--no-signoff`
for the first run and check the tools and optional stages
listed in the consumer's local CI guide before enabling signoff. The
[Homebrew release workflow proposal](../homebrew-sync-proposal.md) remains
a separate step. Adoption in the live repositories and any action on the
stranded fix branches can be reviewed separately.
