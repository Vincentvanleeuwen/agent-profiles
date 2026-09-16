// npm delivers the code; the installers own PATH and rc, not this script.
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const extraArgs = process.argv.slice(2);

if (process.platform === 'win32') {
  const installer = join(root, 'install.ps1');
  const run = spawnSync('powershell.exe', [
    '-NoLogo', '-ExecutionPolicy', 'Bypass', '-File', installer, ...extraArgs,
  ], {stdio: 'inherit', cwd: root});
  if (run.status !== 0) {
    console.error('\nagent-profiles: the Windows installer did not finish. Run it by hand:');
    console.error(`    powershell -ExecutionPolicy Bypass -File "${installer}"`);
    process.exit(run.status ?? 1);
  }
  process.exit(0);
}

// Lets the test suite pass --no-migrate; npm itself runs this with no argv.
const installer = join(root, 'install.sh');
const run = spawnSync('sh', [installer, '--from-npm', ...extraArgs], { stdio: 'inherit', cwd: root });

if (run.status !== 0) {
  console.error('\nagent-profiles: the installer did not finish. Run it by hand:');
  console.error(`    sh "${installer}"`);
}
