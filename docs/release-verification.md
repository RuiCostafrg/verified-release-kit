# Release verification survey

The November inventory saw npm packaging in both projects. On the November
19 `main` tips, typescript-crap `8798a99` still publishes npm platform
packages and verifies portable Linux packages. dotnet-crap `eac6fcf` has
removed its npm builders and verifiers and has a separate NuGet release
workflow. Both still build cargo-dist archives for Linux glibc and musl and
verify published shell and Homebrew installations. The package channels
should be configured per project.

| Order | Candidate | What could be shared | Estimated effort |
|---|---|---|---|
| 1 | `scripts/install-dist.py` | The file is byte-identical at both current tips. Share the pinned cargo-dist version, target-specific checksums and installer. Keep the PowerShell and Windows runner differences in project config. | Half to one day |
| 2 | Published-release asset identity | Share a strict tag-to-source resolution and attestation verifier. Both `release.yml` workflows attest the formula with the same pinned build-provenance action. In dotnet-crap, `verify-published-inputs.py`, `verify-published.py`, and the read-only portion of `verify-published.yml` prepare the fixtures. typescript-crap does equivalent checks in `verify-published.yml`. Keep the asset list, workflow identity and tag policy as explicit inputs. | One to two days with fixture tests |
| 3 | `scripts/verify-installation.py` | Extract safe asset staging, digest comparison, subprocess timeouts and the loopback fixture server. Both simulate installation from local fixtures. TypeScript tests an upgrade from a previous release and CLI behavior against JS fixtures. .NET checks installer and formula metadata, selected target digests, and CLI behavior against its own coverage fixtures. Keep those assertions in their projects. | Two to four days after comparing negative cases |
| 4 | Package channel verifiers | Keep npm platform packages and portable Linux packaging in typescript-crap and NuGet RIDs in dotnet-crap. Share byte/checksum verification below the package-format layer if another consumer needs it. Reuse provenance checks for the source artifacts. | Two to four days for a helper with a second consumer |

The Homebrew verifier proposal covers the first use of a shared provenance
policy. Extract no release scripts or configuration in this slice.
