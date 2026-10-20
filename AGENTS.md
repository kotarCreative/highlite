# Agent instructions

## Commit messages

- Use Conventional Commits: `type(scope): imperative summary`.
- Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.
- Keep the summary concise, imperative, and without a trailing period.
- Use a scope when it adds useful context, such as `sdk`, `core`, `demo`, or `repo`.
- Do not skip the repository's Git hooks or validation checks.

## Project rules

- Keep the browser SDK framework-agnostic and avoid collecting sensitive form data.
- Never claim upstream Scrawl compatibility until its actual schema, license, and processing interfaces are validated.
- Keep browser APIs behind small interfaces where practical so capture behavior can be tested.
- Run `pnpm check` before committing.
