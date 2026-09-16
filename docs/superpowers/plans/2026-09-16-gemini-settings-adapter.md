# Gemini settings adapter plan

**Goal:** Switch Gemini CLI user settings with the same profile lifecycle as Claude and Codex, then prove Ollama and LM Studio endpoint/model settings survive switching.

**Verified native mechanism:** Gemini CLI documents its user settings at `~/.gemini/settings.json`; `GEMINI_CLI_HOME` changes the parent containing `.gemini`, but a whole-home override would also move credentials and history. Agent Profiles therefore switches only the documented user settings file.

## Tasks

1. Add failing POSIX lifecycle checks for default preservation, create, activate, edit, second-profile snapshot, reset, export/import, and uninstall.
2. Add the matching copy-based PowerShell lifecycle checks for Windows.
3. Implement the smallest Gemini file adapter beside the existing Codex adapter, including rollback to the prior active selection when either client activation fails.
4. Add Codex fixtures containing Ollama (`127.0.0.1:11434`) and LM Studio (`127.0.0.1:1234`) settings and assert byte-preserving profile switches. Do not start providers or validate models.
5. Extend fresh-install tests and README claims, run local suites, push, and require all native CI jobs to pass.
