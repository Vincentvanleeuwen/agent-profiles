// npm delivers the code; the installers own PATH and rc. Keeping the logic there
// means one implementation per platform, not three.
//
// A failed postinstall must not fail the install: a user who installs on a
// locked-down machine should still get a package they can install by hand.
import { existsSync, symlinkSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));

// The PowerShell half was never migrated to the stable-install layout: its
// Get-CpStore still defaults to the module's own directory, which under npm
// is the node-version-scoped global prefix — the exact fragility this
// dispatcher exists to avoid. Point Windows users at the clone-based install
// instead of running install.ps1 against a location it will lose on nvm/nvs use.
if (process.platform === 'win32') {
  console.log('claude-profiles: the Windows install is not yet migrated for npm installs.');
  console.log('Clone the repo and run install.ps1 from there instead:');
  console.log('    powershell -ExecutionPolicy Bypass -File install.ps1');
  process.exit(0);
}

// npm strips symlinks from published tarballs, so bin/claude-profile never
// reaches a real npm install even though it's in `files`. install.sh's
// copy_code only copies what's there, so without this, link_bin would wire
// PATH to a symlink pointing at nothing.
const binLink = join(root, 'bin', 'claude-profile');
if (!existsSync(binLink)) symlinkSync('../claude-profile.sh', binLink);

// Extra args exist so the test suite can pass --no-migrate; npm itself
// invokes this script with none, so this is a no-op on a real install.
const extraArgs = process.argv.slice(2);
const installer = join(root, 'install.sh');
const run = spawnSync('sh', [installer, '--from-npm', ...extraArgs], { stdio: 'inherit', cwd: root });

if (run.status !== 0) {
  console.error('\nclaude-profiles: the installer did not finish. Run it by hand:');
  console.error(`    sh "${installer}"`);
}
