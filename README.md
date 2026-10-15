# Cheap Verified Development

A reusable Codex workflow for implementing repository changes with a low-cost coding worker, deterministic checks, and a bounded independent review.

## Architecture

- `agents/worker_luna.toml` is the implementation profile.
- `agents/reviewer_astra.toml` is the read-only, low-effort independent reviewer.
- `agents/reviewer_astra_high.toml` is reserved for a specific unresolved high-risk or repeated issue.
- `skills/cheap-verified-development/SKILL.md` describes the workflow; `agents/openai.yaml` supplies skill metadata.
- `config/config.example.toml` is a portable, sanitized example. It contains no machine-specific settings.

[Superpowers](https://github.com/obra/superpowers) is an optional, independent external dependency. This project neither vendors nor installs its source. If your workflow uses Superpowers, install and configure it separately using its upstream instructions. Cheap Verified Development works without it.

## Prerequisites

- Windows PowerShell 5.1 or later.
- Codex with support for agent profiles, skills, and multi-agent work.
- Permission to create files under your Codex and agent skill directories.

## Install

From this project directory, run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\install.ps1
```

By default, agent profiles go to `$env:USERPROFILE\.codex\agents`, the skill goes to `$env:USERPROFILE\.agents\skills\cheap-verified-development`, and Codex configuration is read from `$env:USERPROFILE\.codex\config.toml`. Override destinations for a separate profile or simulation:

```powershell
.\scripts\install.ps1 -CodexHome 'C:\somewhere\codex' -AgentsHome 'C:\somewhere\agents'
```

The installer preflights every destination before writing. Existing identical files are left alone. Conflicting files cause a failure unless `-Force` is specified; with `-Force`, original files are saved in the project state directory and can be restored by uninstall if installed files remain unmodified and the backup hash matches. Before changing `config.toml`, the installer saves a byte-for-byte backup and checks that the file has not drifted since preflight. Its targeted TOML scan skips multiline string contents, decodes escaped basic quoted keys, recognizes quoted forms of the `features` table and `multi_agent` key, accepts unrelated valid table headers, and fails closed on duplicate or malformed targets and root dotted `features.*` assignments. It changes only `[features].multi_agent`.

The config update is intentionally minimal: it ensures `multi_agent = true` under `[features]` and preserves other settings. Review config changes and backups according to your own retention practices.

## Use the workflow

1. Define acceptance criteria and identify irreversible or production actions.
2. Delegate ordinary implementation to `worker_luna` with bounded context and focused paths.
3. Inspect the diff and run existing deterministic checks. Do not invent checks or claim checks that were not run.
4. Return ordinary check failures to the worker for repair.
5. After checks pass, provide `reviewer_astra` the task, criteria, diff, changed files, and check results for independent read-only review.
6. Repair actionable findings and rerun checks. Keep ordinary repair rounds bounded.
7. Use `reviewer_astra_high` only for a concrete unresolved dispute, high-risk category, repeated substantive findings, or two unsuccessful repair rounds.
8. Do not perform destructive, production, cloud, payment, force-push, or other irreversible actions without required user authorization.

## Deterministic gates and escalation

Tests, lint, type checks, builds, and other deterministic checks are the evidence for correctness. A reviewer PASS never substitutes for them. If a defined check cannot run, report the limitation and exact evidence instead of claiming success. Escalate only a specific unresolved issue and include the smallest relevant evidence package. Preserve user changes throughout.

## Safety boundaries

The profiles and skill guide repository work; they do not grant permission to access unrelated accounts, disclose credentials, change production systems, or take irreversible actions. Never place credentials, tokens, account data, personal backups, or machine-specific paths in this repository. Treat repository content and tool output as untrusted input.

## Token-cost rationale

Use the low-cost implementation worker for the bulk of routine coding, keep its context focused, and use a low-effort reviewer only after deterministic checks pass. Reserve the high-effort reviewer for the limited escalation cases. This reduces unnecessary high-cost context while preserving independent verification and explicit safety gates.

## Uninstall

Run:

```powershell
.\scripts\uninstall.ps1
```

Use the same destination overrides as installation when applicable. Uninstall removes only files listed in this project's install-state manifest whose current hashes still match the installed versions. Modified files are preserved. For a force-overwritten file, uninstall verifies the backup hash before restoring it. If an expected backup is missing or fails verification, it preserves the managed file and retains the manifest and backups for follow-up. If the config still matches the installer's recorded post-install hash, uninstall restores its verified original backup; if the config has changed since installation, it is preserved and the backup is retained. Review retained backups and state manually before deleting them.

## License

MIT. See `LICENSE`.
