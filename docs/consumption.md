# Consuming the shared runner

Recommend vendoring `scripts/local-ci.sh` with its checksum. It runs from
a normal checkout without fetching code, initializing a submodule, or
requiring a published kit release. Each repository tracks its own
`scripts/local-ci.stages.sh`; change the runner centrally and update copies
with the same bytes.

From a trusted checkout of the kit:

```bash
scripts/vendor-local-ci.sh install /path/to/consumer
scripts/vendor-local-ci.sh check /path/to/consumer /path/to/another-consumer
```

`install` writes the runner and `scripts/local-ci.sha256`. Review those
changes with the stage file. The runner checks its sidecar locally when
present. `check` compares each copy to the kit checkout you run it from.
Both work offline. Local verification detects accidental edits. Comparing
against the newest approved kit requires that revision to be available
locally, so a consumer with an old matching runner and sidecar keeps
working until it is synced. The checksum supplies an integrity comparison
against a trusted copy. Store the approved kit revision in the consumer's
update commit for a reviewable upgrade and rollback.

A submodule also pins a revision and makes it visible in Git, but adds
initialization to every clean checkout and needs access to the kit remote.
A downloaded pinned release fits consumers that already provision tools that
way, but needs a release host, an authenticated digest and a cache or
network access at setup. The pilot uses vendoring to demonstrate the
simplest offline path. The account-wide distribution choice stays open.
