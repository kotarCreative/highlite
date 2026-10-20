import { build } from 'esbuild';

const shared = {
  entryPoints: ['src/index.ts'],
  bundle: true,
  platform: 'browser',
  target: 'es2022',
  sourcemap: true,
  logLevel: 'info',
};

await build({ ...shared, format: 'esm', outfile: 'dist/highlite.js' });
await build({
  ...shared,
  format: 'iife',
  globalName: 'Highlite',
  outfile: 'dist/highlite.iife.js',
});
