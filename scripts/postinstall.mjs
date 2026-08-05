// npm delivers the code; the installers own PATH and rc, not this script.
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));

// install.ps1's Get-CpStore isn't migrated to survive nvm; point at the clone install instead.
if (process.platform === 'win32') {
  console.log('claude-profiles: the Windows install is not yet migrated for npm installs.');
  console.log('Clone the repo and run install.ps1 from there instead:');
  console.log('    powershell -ExecutionPolicy Bypass -File install.ps1');
  process.exit(0);
}

// Lets the test suite pass --no-migrate; npm itself runs this with no argv.
const extraArgs = process.argv.slice(2);
const installer = join(root, 'install.sh');
const run = spawnSync('sh', [installer, '--from-npm', ...extraArgs], { stdio: 'inherit', cwd: root });

if (run.status !== 0) {
  console.error('\nclaude-profiles: the installer did not finish. Run it by hand:');
  console.error(`    sh "${installer}"`);
}
