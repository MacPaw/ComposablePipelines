# Contributing to Composable Pipelines

Thank you for your interest in Composable Pipelines!

## This repository is a one-way mirror

The code here is exported one-directionally from an upstream source repository, which is the
single source of truth. As a consequence:

- **`Package.swift` and the `Sources/` tree are synced from upstream.** Do not edit them in this
  repo — changes would be overwritten on the next sync.
- Repository metadata that *is* maintained here — `README.md`, `LICENSE`, `CONTRIBUTING.md`,
  `NOTICE`, and `.github/` — is preserved across syncs.

## Reporting issues

Please open a GitHub issue with:

- the module involved (`PipelineAST`, `PipelineDSL`, `PipelineCompiler`, or `ExecutionEngine`),
- a minimal pipeline that reproduces the problem,
- expected vs. actual behavior, and
- your Swift toolchain and platform versions.

## Pull requests

Because sources are synced from upstream, we cannot merge code PRs into this mirror directly.
If you have a fix or improvement:

1. Open an issue describing the change (a patch or a link to a branch is very welcome).
2. A maintainer will land the change upstream, and it will flow back here on the next sync.

Documentation and metadata maintained in this repo (the files listed above) *can* be changed
via PR here.

## License

By contributing, you agree that your contributions will be licensed under the
[Apache License 2.0](LICENSE).
