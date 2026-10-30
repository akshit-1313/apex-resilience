# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Project scaffolding: Salesforce DX project (API 67.0, no namespace), Prettier with the Apex
  plugin, and Husky with lint-staged.
- MIT licence.
- Community files: pull request template, issue forms, this changelog and a security policy.
- CI: a static-analysis job (Prettier and Salesforce Code Analyzer) on every pull request and
  push to `main`.
- `FailureClass` and `HttpFailureClassifier`: classifies a failed callout's HTTP status code as
  RETRYABLE, TERMINAL or POISON.
- CI: a scratch-org job that deploys to a fresh scratch org, runs the Apex tests and requires 90%
  org-wide coverage. Both CI jobs run on a pinned `ubuntu-24.04` runner.
- README (status, verdicts, current classifier rules, roadmap and prior art) and contributing
  guidelines, including how pull requests from forks are tested.

[Unreleased]: https://github.com/akshit-1313/apex-resilience/commits/main
