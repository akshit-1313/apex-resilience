# Contributing to apex-resilience

Thanks for your interest. apex-resilience is pre-alpha and maintained by one person, so please
read this before opening a pull request.

## Scope comes first

The library stays small on purpose. Every change must help decide or execute a safe retry.
Logging, generic HTTP clients, trigger frameworks and admin UIs are out of scope. For anything
bigger than a small fix, open an issue first; the feature request form asks how the change helps.

## Development setup

You need:

- Node.js at the version pinned in `package.json` (`volta.node`). [Volta](https://volta.sh)
  switches to it automatically.
- The Salesforce CLI (`sf`), at the version installed in `.github/workflows/ci.yml`.
- A Dev Hub org for scratch orgs. A free Developer Edition or Trailhead Playground works.

```sh
npm ci   # Prettier, the Apex plugin and the pre-commit hook
sf org create scratch --definition-file config/project-scratch-def.json --alias dev \
  --duration-days 7 --target-dev-hub <your-dev-hub>
sf project deploy start --source-dir force-app --target-org dev
sf apex run test --code-coverage --wait 10 --target-org dev
npm run prettier:verify
```

## Conventions

- API version 67.0, in `sfdx-project.json` and every `-meta.xml`.
- There is no namespace, so every name must be specific to this library (`HttpFailureClassifier`),
  never a generic word such as `Logger` or `Util`.
- Tests are table-driven where possible, and every `Assert` call has a message.
- CI requires the tests to pass and org-wide coverage of at least 90%.
- No new dependency (npm package, CLI plugin or Apex library) without agreeing it in an issue
  first.
- Formatting is Prettier's job; the pre-commit hook runs it on staged files.

## Pull requests

1. Branch from `main`, with one change per pull request.
2. Fill in the pull request template, and add a line under `Unreleased` in `CHANGELOG.md`.
3. Both CI checks must pass: `static-analysis` (Prettier and Salesforce Code Analyzer) and
   `scratch-org-tests` (deploy and Apex tests in a fresh scratch org). Pull requests that change
   only Markdown files or `LICENSE` skip the scratch-org job.
4. Pull requests are squash-merged into a single commit on `main`. Write the title in
   [Conventional Commits](https://www.conventionalcommits.org) style, such as `feat: …`, `fix: …`
   or `docs: …`.

## Pull requests from forks

The scratch-org job needs this repository's Dev Hub credential, which is stored as a secret.
GitHub doesn't give secrets to workflows triggered by pull requests from forks, so on a fork pull
request that job is skipped, and GitHub reports a skipped job as successful. A green check on a
fork pull request therefore means only that static analysis passed. The Apex tests have not run in
an org.

Before merging a fork pull request, a maintainer pushes its branch to this repository and runs the
full workflow on it from the Actions tab, so the tests run with the secret.

The workflow never uses the `pull_request_target` trigger to get around this. That trigger runs
with the repository's secrets, so combining it with the fork's code would hand the Dev Hub
credential to untrusted code.

## Reporting security problems

Don't open a public issue. Follow [SECURITY.md](SECURITY.md) instead.

## Licence

By contributing, you agree that your contributions are licensed under the [MIT licence](LICENSE).
