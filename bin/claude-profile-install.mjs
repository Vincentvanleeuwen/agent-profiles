#!/usr/bin/env node
// Re-runs the installer, for when a shell rc was reset or the install dir was
// removed. The same dispatcher npm's postinstall uses.
import('../scripts/postinstall.mjs');
