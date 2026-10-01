# Contributing to Clutch

Thanks for contributing.  This file is the human-facing counterpart to
[`AGENTS.md`](./AGENTS.md), which is binding for AI agents working on this
repo.  Read both before opening a PR.

## Communication

- Open a PR with a clear description of what changed and why.
- Reference any related issue or board row in the PR body.
- Keep PRs scoped — one coherent change per PR.  Don't bundle "while I'm
  here" cleanups; file them separately so a regression can be bisected.
- Resolve review comments in the same PR they were raised on, or split
  them out into a follow-up PR.  Never resolve by "keeping both sides".

## Code style

- TypeScript for `src/`.  `noUncheckedIndexedAccess`,
  `exactOptionalPropertyTypes`, `verbatimModuleSyntax` are on.  `pnpm
  typecheck` must pass.
- Python for `bridges/`.  stdlib only.  No `pip install`.  Code must run
  under `/opt/homebrew/bin/python3` on the owner's Mac.
- Cordis profiles are YAML.  Empty patch layers are `[]`, not `null` or
  absent — the loader distinguishes.

## Verification gate

- `pnpm typecheck` clean
- `pnpm test` green (or `pnpm test:ci-scope && git diff --check` for
  pure-docs PRs)
- iOS files: `cd ios && swift test` (no iOS files yet, but the gate
  applies once the Swift dock app moves into the repo's CI)
- UI changes: screenshot in the PR body

## Standing rules

The "Operating Rules" section in `AGENTS.md` is binding for AI agents
and applies to human contributors too in spirit:

- **No external contact without owner approval.**  Don't file upstream
  PRs, post upstream issues, comment on upstream discussions, or contact
  third-party maintainers on the owner's behalf.  Pin upstream packages
  and credit via `NOTICE` / README; do not reach out.
- **No forks of other repositories.**  This repo is independent.  If you
  need a custom build of an upstream, file an issue here for the owner
  to review.
- **Two spaces between sentences** in every paragraph a human reads.
  Title Case headings.  Light theme is the first-visit default.
  Timestamps in Central Time.

## License

By contributing, you agree that your contributions are licensed under
the Apache License, Version 2.0, the same license as the rest of this
repository.  See [`LICENSE`](./LICENSE) for the full text.
