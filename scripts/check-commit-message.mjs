import { readFileSync } from 'node:fs';

const messagePath = process.argv[2];
if (!messagePath) {
  process.stderr.write('Usage: node scripts/check-commit-message.mjs <message-file>\n');
  process.exit(2);
}

const message = readFileSync(messagePath, 'utf8').split('\n', 1)[0].trim();
const conventionalCommit =
  /^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9-]+\))?!?: [a-z].{0,70}$/;

if (!conventionalCommit.test(message) || message.endsWith('.')) {
  process.stderr.write(`Invalid commit message: "${message}"\n`);
  process.stderr.write('Use: type(scope): imperative summary (Conventional Commits)\n');
  process.exit(1);
}
