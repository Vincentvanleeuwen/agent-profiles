# Cross-platform install validation

Date: 2026-09-16
Status: proposed

## Purpose

Prove that a published `agent-profiles` package works from a clean machine by
following the documented install, create, switch, default, and uninstall
journeys. Cover the operating-system families and AI clients the project claims
to support without making every pull request depend on paid APIs, downloaded
models, or GUI automation.

This system validates support; it does not claim every physical device is
tested. A passing platform means the supported shells and current hosted runner
for that OS family pass.

## Supported scope

The target clients are:

- Claude Code
- Codex CLI and Codex Desktop configuration
- Gemini CLI
- Ollama and LM Studio as local model providers selected by a client profile

Grok is excluded. Agent Profiles manages local-provider settings only. It does
not install providers, start servers, download models, or manage provider data.

The target platforms are:

- macOS with zsh and bash
- Linux with bash, zsh, and POSIX sh
- Windows with Windows PowerShell 5.1, PowerShell 7, and Git Bash
- WSL as a separate Linux installation, covered by a release smoke test

`cmd.exe` remains unsupported. A client/platform pair is not advertised as
supported until its required adapter and fresh-install job pass.

## Validation layers

### 1. Hermetic tests

Run on every pull request. Existing shell and PowerShell tests remain the fast
feedback loop. Each client adapter also gets a fake executable that reports the
native config or environment it received. The shared acceptance journey is:

1. Seed a recognizable default client setting.
2. Install Agent Profiles into an empty fake home.
3. Create a profile.
4. Change that profile's recognizable setting.
5. Activate it and prove the fake client reads the profile setting.
6. Select `default` and prove the original setting returns.
7. Uninstall and prove the profile store survives.

The test journey is shared, but client-specific config discovery stays in small
client fixtures. Do not build a general adapter framework before those three
fixtures need common code.

### 2. Fresh-install package tests

Run on every pull request on GitHub-hosted `ubuntu-latest`, `macos-latest`, and
`windows-latest` runners. Build one npm tarball and install that exact artifact
on every runner; never install from the checkout. Each job uses a new temporary
home and no existing Agent Profiles state.

The jobs execute the same user journey shown in the README:

```text
install package -> open a fresh shell -> create -> activate -> inspect ->
restore default -> uninstall -> verify retained store
```

POSIX jobs exercise clone and npm installation. Windows jobs exercise
`install.ps1`, Git Bash delegation, PowerShell profile loading, and the expected
npm guidance until npm installation is supported there. Tests also assert the
published tarball contains every canonical entry point and compatibility shim.

The smoke scripts are the executable definition of the README journey. The
README names those scripts beside the documented commands, and a lightweight
documentation assertion checks that every tested journey is still documented.
The suite does not parse arbitrary Markdown code blocks.

### 3. Real-client compatibility tests

Run nightly and on release candidates. Install the latest stable Claude Code,
Codex, and Gemini CLI, then verify:

- the executable starts and reports its version;
- the native configuration written by the active profile parses;
- switching profiles changes the configuration the client discovers;
- returning to default restores the original configuration;
- an already-running client is never treated as proof of a successful switch.

These checks do not call a model and need no account credentials. Each run
records OS, shell, Node, PowerShell, Agent Profiles, and client versions as a
downloadable evidence artifact.

### 4. Authenticated live smoke tests

Run nightly in protected GitHub environments, never for forks. Make one tiny,
deterministic request through each cloud client and assert a fixed marker in the
response. Use dedicated low-privilege test accounts, strict spend limits, short
timeouts, and redacted logs.

Failures alert maintainers but do not block unrelated pull requests. A release
candidate must have a recent successful live smoke run. Provider outages are
reported separately from install/configuration failures.

### 5. Release-only manual tests

Use a short checklist for behavior hosted runners cannot represent reliably:

- Codex Desktop observes an activated profile after restart;
- LM Studio reads the selected endpoint/model settings;
- Ollama completes one request with a small local model;
- WSL behaves as an independent Linux installation;
- Windows PowerShell 5.1 works on a normal non-developer Windows account.

Record the result and tested versions in the release evidence artifact. Do not
automate GUI clicking or maintain custom VM images until this checklist becomes
a measurable release bottleneck.

## CI matrix

| Gate | Ubuntu | macOS | Windows |
| --- | --- | --- | --- |
| POSIX unit suite | sh, bash, zsh | sh, bash, zsh | Git Bash |
| PowerShell suite | PowerShell 7 | PowerShell 7 | 5.1 and 7 |
| Fresh npm install | yes | yes | expected guidance until supported |
| Fresh clone install | yes | yes | Git Bash and `install.ps1` |
| Fake Claude adapter | yes | yes | yes |
| Fake Codex adapter | yes | yes | yes after PowerShell support |
| Fake Gemini adapter | yes | yes | yes |
| Real clients | nightly | nightly | nightly |
| Authenticated request | one nightly runner | optional diagnostic | optional diagnostic |

Linux containers may add distro and old-shell coverage later. They do not
replace native macOS and Windows runners. GitHub-hosted runners are the VM layer;
custom VMs are deferred until a missing platform requirement proves necessary.

## Adapter responsibilities

Each client adapter owns only four operations:

- snapshot the client's default configuration;
- create profile-owned configuration;
- activate profile configuration;
- restore the snapshot when returning to default or uninstalling.

Claude continues to use `CLAUDE_CONFIG_DIR`. Codex continues to use its native
`config.toml`. Gemini must use its documented native configuration mechanism;
the implementation may not guess paths. Local provider selection is data inside
the relevant client config, with fixtures for Ollama and LM Studio endpoints.

An adapter must preserve unknown client settings. Export/import must include its
profile-owned files while continuing to exclude known credentials. Secrets and
runtime histories remain outside the profile unless the client provides a safe,
documented reason otherwise.

## Release gates

A pull request is mergeable when hermetic and fresh-install jobs pass for every
currently supported pair. A new pair starts as experimental and becomes
supported only after its native runner job and real-client nightly job pass.

A release requires:

- all pull-request gates green on the release commit;
- a real-client run less than seven days old;
- a live cloud smoke run less than seven days old;
- the release-only checklist completed for changed GUI/local-provider behavior;
- the generated evidence artifact attached to the release.

Known unsupported combinations must be explicit in the README and must fail
with actionable guidance rather than partially installing.

## Failure handling and security

Every job gets a disposable home and store. Tests must never read or write the
runner account's real Claude, Codex, Gemini, Ollama, or LM Studio configuration.
Installation output is captured, but configuration contents are not uploaded
when they may contain environment values, tokens, MCP credentials, or endpoints.

Authenticated jobs use environment-scoped secrets, cannot run from forks, and
have concurrency and timeout limits. A failed cleanup does not reuse the same
home on a later job because hosted runners are disposable.

## Delivery order

1. Add the three-OS fresh-package matrix for the currently supported Claude and
   Codex behavior.
2. Close the existing Windows gaps: shared store defaults, Codex switching, and
   npm installation or an explicit supported alternative.
3. Add the Gemini adapter through the same acceptance journey.
4. Add Ollama and LM Studio setting fixtures to the Codex/Gemini adapters.
5. Add nightly real-client jobs, then the protected authenticated smoke jobs.
6. Add release evidence generation and the manual checklist.

This order makes the publication and clean-install path trustworthy before
expanding the product surface.
