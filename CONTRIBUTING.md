# Contributing

Thanks for taking the time to look at this project!

Contributions are governed by the [Apache-2.0 License](LICENSE), and
participation by the [Code of Conduct](CODE_OF_CONDUCT.md).

By opening a pull request you agree that your contribution is licensed under the
Apache License 2.0, the same terms as the rest of the repository.

## Before you open a PR

- Open an issue first for anything larger than a bug fix, so we can agree on the
  approach before you spend time on it.
- Keep a pull request to one concern, and describe what you changed and why.
- Do not report security issues here - see [SECURITY.md](SECURITY.md).

## Getting set up

See the [README](README.md) for how to install dependencies, build, and run the
tests. Whatever check the project runs in CI is the contract: a pull request is
expected to be green before review.

## Commits

[Conventional Commits](https://conventionalcommits.org/):
`type(scope): description`, with `type` one of `feat`, `fix`, `docs`, `style`,
`refactor`, `test`, `build`, `ci`, `perf`, `revert`, `improvement`, `chore`.

## Using AI agents

Much of this project is written by AI agents under human review. That does not
change what is expected of a contribution - the gate is the gate - but it does
mean the codebase carries unusually detailed inline rationale. Please keep that
up: explain *why*, not *what*.
