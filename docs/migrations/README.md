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
| forge-ios | `f1f91f0560dda9dc6a5e7a7a1a3745f473847827` | [Patch](forge-ios.patch) |
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
Rollup's native dependency on this machine. The
[integration test patch](pi-droid-extension-test.patch) builds from the
current sources and loads `dist/index.js`, the entry point declared by
the package, in an isolated directory so the package test can rebuild
the checkout's `dist/` in parallel. Individual build hooks and pack
checks have outer deadlines longer than their subprocess deadlines.
All seven extension tests passed on Linux Node 26 after
that change. The sandbox install test now bounds its npm subprocesses
and packs into its own temporary directory. The capture-audit test also
passed after increasing its fixture deadline from 20 to 60 seconds. The
migration patch accepts
`PI_DROID_TEST_TIMEOUT_MS` for slow machines and preserves the default
30-second deadline. All 63 unit-test files passed across batches and
serial retries, covering 864 tests. All nine integration checks passed
together after the sandbox fixture stopped installing Pi's host peer
dependencies. The sandbox installs the tarball and its own dependencies
through npm. The isolated extension fixture exercises loading with the
host dependencies and the package metadata and runtime files in place.
The final rollout run and a follow-up for the seven unfinished files
covered all 65 files and 873 tests in `test:ci` successfully.
Fantastic Pi Mobile's bridge suite passed 67 of 69 tests before and
after the patch on this machine. The same test in
`bridge/test/review.test.js` failed with “Session is closed” in both runs.
A second review test failed on the original runner, and a different
test timed out in `bridge/test/project-lifecycle.test.js` on the patched
runner. A focused log and reliability run passed all three tests in the
patched checkout. Recheck the full bridge suite on the normal CI
toolchain before adopting its patch.
The [bridge test patch](fantastic-pi-mobile-bridge-tests.patch) makes the
snapshot test wait for a terminal state and joins its pending read
before closing the store. It also gives the routing fixture a bounded
elapsed-time deadline. Both cases passed in the Linux Node 26 full rerun,
which hit its overall timeout before the review file finished. The review
file then passed all 18 tests on its own. Together the two runs covered
all 69 bridge tests successfully.
After the review fix, one complete Linux Node 24 run passed all 69
bridge tests with zero failures or cancellations.
Fantastic Pi Mobile's Android stage passed with Java 17, Android SDK 35,
and the local ARM64 AAPT2. It built the debug APK, passed lint, and ran
all 22 unit tests successfully.

Forge iOS passed its full Linux stage with Swift 6.1.3. All 43 tests
and project validation passed. The .NET default stages passed across
two local runs. The Python suite had three skips, the Rust debug and
release suites passed, and lint and security passed. TypeScript's lint,
documentation, package listing and security checks passed. Its runtime
suite hit the Rust pipeline panic-ordering test's deadline under load.
That test passed by itself and in a serial run. The
[coverage publication patch](typescript-crap-coverage-publish.patch)
checks the destination after the collector exits and before creating
staging files, while keeping the final pre-publication check. All 11
coverage configuration tests passed, including both directory-alias
cases. The full Node suite passed with 125 tests and one skip.
Final verification also passed all 186 Python tests and 238 Rust tests
in each of the debug and release profiles, with one Rust test ignored
in each profile. Lint and docs passed from the committed verification
checkout.
Full release checks are outside these local runs.

Apply and test one patch at a time in a disposable checkout of its base.
For checks that expect a clean Git tree, such as Cargo's package listing,
test from a local commit in that disposable checkout. Use `--no-signoff`
for the first run and check the tools and optional stages
listed in the consumer's local CI guide before enabling signoff. The
[Homebrew release workflow proposal](../homebrew-sync-proposal.md) remains
a separate step. Adoption in the live repositories and any action on the
stranded fix branches can be reviewed separately.
