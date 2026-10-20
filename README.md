# Highlite

Highlite is an embeddable browser SDK for capturing narrated, visually contextual web interactions. It is an independent prototype; it does not claim compatibility with Kit Langton's Scrawl format.

## Status

The repository is being built in milestones. The initial foundation includes a pnpm TypeScript workspace, Oxc formatting and linting, Vitest, and Git hooks. See [the implementation notes](docs/implementation-notes.md) for browser constraints and current progress.

## Development

Requires Node.js 22 or newer and pnpm 12. Install dependencies with `pnpm install`. The `prepare` script configures the local Git hooks.

- `pnpm dev` — build workspace packages and start the demo
- `pnpm check` — formatting, lint, typecheck, and tests
- `pnpm build` — build workspace packages in dependency order

Commit messages are checked against Conventional Commits, and the pre-commit hook runs `pnpm check`.
