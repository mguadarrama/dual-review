# dual-review

Reviews the same code with two AI models (Claude and Codex, which runs OpenAI GPT models,
optionally Copilot as a third) and writes a comparison: what they all found, what only one
found, and where they disagree. Read-only: it never edits code, commits or pushes.

## Usage

Run it from anywhere inside a git repository:

```powershell
dual-review                     # current branch (committed + uncommitted + untracked) vs main/master
dual-review -Base develop       # against another base branch
dual-review -Path src/Payments  # full review of a folder instead of a diff
dual-review -WithCopilot        # add Copilot as a third reviewer
dual-review -ClaudeModel opus -CodexModel <model> -TimeoutMinutes 30 -NoSummary
```

Output goes to `.reviews/<timestamp>-<branch>/` in the repository:

| File | Content |
|------|---------|
| `scope.md`, `scope.diff` | What was reviewed (identical input for every model) |
| `prompt.md` | The review instructions sent to every model |
| `claude.md`, `copilot.md`, `codex.md` | Each model's review |
| `summary.md` | Comparison written by Claude |
| `*.log` | stderr / progress of each CLI, for troubleshooting |

`.reviews/` is added to `.git/info/exclude`, so it never shows up in `git status` or commits,
and the repo's `.gitignore` is not touched.

## How it works

1. Computes the scope with git and writes it to files.
2. Runs the reviewers in parallel, non-interactively, restricted to read tools and read-only
   git commands (`claude -p`, `codex exec --sandbox read-only`, `copilot -p`).
3. If at least two reviews succeed, Claude compares them. It is told not to add findings of
   its own.

Codex is the default second reviewer because it runs GPT models on a ChatGPT login, which
gives a genuinely independent opinion. Copilot runs with `-CopilotModel auto` by default,
because some Copilot plans only expose a single model and reject explicit `--model` values.
If your plan allows choosing, pass a GPT model (`-CopilotModel <gpt-model>`), not a Claude
one, or the third opinion would not be independent.

## Editing the prompts

- `review-prompt.md`: what reviewers look for and the output format.
- `summary-prompt.md`: how the comparison is structured.

## Requirements

PowerShell 7, git, and the CLIs logged in: `claude`, `codex` (`codex login`) and, only for
`-WithCopilot`, `copilot` (`copilot login`).

## Privacy

The reviewed code is sent to each model's provider: Anthropic (Claude), OpenAI (Codex) and
GitHub/Microsoft (Copilot). Check that this is allowed before using it on code that isn't
yours.
