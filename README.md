# dual-review

Reviews the same code with two AI models (Claude and Codex, which runs OpenAI GPT models,
optionally Copilot as a third) and writes a comparison: what they all found, what only one
found, and where they disagree. Read-only: it never edits code, commits or pushes.

Any extra models can be added as additional reviewers through the `opencode` CLI, which
speaks to any configured provider (OpenRouter, OpenAI, Anthropic, ...), so models like
GLM-5.3 or DeepSeek V4.1 Flash can review the same code alongside the defaults.

## Usage

Run it from anywhere inside a git repository:

```powershell
dual-review                     # current branch (committed + uncommitted + untracked) vs main/master
dual-review -Base develop       # against another base branch
dual-review -Path src/Payments  # full review of a folder instead of a diff
dual-review -WithCopilot        # add Copilot as a third reviewer
dual-review -OpenCodeModels openrouter/z-ai/glm-5.3,openrouter/deepseek/deepseek-v4.1-flash-1017
dual-review -NoClaude -SummaryModel openrouter/z-ai/glm-5.3 -OpenCodeModels openrouter/z-ai/glm-5.3,openrouter/deepseek/deepseek-v4.1-flash-1017
dual-review -ClaudeModel opus -CodexModel <model> -TimeoutMinutes 30 -NoSummary
```

`-OpenCodeModels` takes one or more model IDs in `provider/model` (or
`provider/model#variant`) form, one reviewer per model. Find the IDs with
`opencode models` or by asking an OpenCode session to look them up. Reviewers whose CLI
is missing are skipped with a warning; the comparison runs when at least two reviews
succeeded. `-NoClaude` skips the Claude reviewer and `-SummaryModel <provider/model>`
writes the comparison with an opencode model instead of Claude, so the whole run can work
without any Anthropic quota.

Output goes to `.reviews/<timestamp>-<branch>/` in the repository:

| File | Content |
|------|---------|
| `scope.md`, `scope.diff` | What was reviewed (identical input for every model) |
| `prompt.md` | The review instructions sent to every model |
| `claude.md`, `copilot.md`, `codex.md` | Each model's review |
| `opencode-<model>.md` | One per `-OpenCodeModels` entry |
| `summary.md` | Comparison written by Claude |
| `*.log` | stderr / progress of each CLI, for troubleshooting |

`.reviews/` is added to `.git/info/exclude`, so it never shows up in `git status` or commits,
and the repo's `.gitignore` is not touched.

## How it works

1. Computes the scope with git and writes it to files.
2. Runs the reviewers in parallel, non-interactively, restricted to read tools and read-only
   git commands (`claude -p`, `codex exec --sandbox read-only`, `copilot -p`,
   `opencode run`).
3. If at least two reviews succeed, Claude (or the `-SummaryModel` opencode model)
   compares them. It is told not to add findings of its own.

Codex is the default second reviewer because it runs GPT models on a ChatGPT login, which
gives a genuinely independent opinion. Copilot runs with `-CopilotModel auto` by default,
because some Copilot plans only expose a single model and reject explicit `--model` values.
If your plan allows choosing, pass a GPT model (`-CopilotModel <gpt-model>`), not a Claude
one, or the third opinion would not be independent.

OpenCode reviewers run `opencode run --standalone --format json` with a temporary
permission configuration injected through the `OPENCODE_CONFIG_CONTENT` environment
variable: every action is denied and only `read`, `glob`, `grep` and the same read-only git
commands are re-enabled. Nothing is written to the repository or to your OpenCode
configuration, and the review is the last `text` event of the JSON output.

## Sample comparison

A run on 2026-11-03 reviewed the same small diff — a ~20-line JavaScript change with three
planted bugs (assignment instead of comparison, off-by-one loop bound, division by zero on
empty input) — with four reviewers and the comparison written by GLM-5.3:

| Reviewer | Time | Findings | Planted bugs found |
|---|---|---|---|
| Codex (GPT, ChatGPT login) | 51 s | 3 | 3/3 |
| GLM-5.3 (OpenRouter) | 92 s | 3 | 3/3 |
| GLM-5.3 Flash (OpenRouter) | 42 s | 4 | 3/3 |
| DeepSeek V4.1 Flash 1017 (OpenRouter) | 22 s | 6 | 3/3 |

```powershell
dual-review -NoClaude -SummaryModel openrouter/z-ai/glm-5.3 -OpenCodeModels openrouter/z-ai/glm-5.3,openrouter/z-ai/glm-5.3-flash,openrouter/deepseek/deepseek-v4.1-flash-1017
```

- All four reviewers found all three planted bugs, with no false positives and no factual
  contradictions; they differed only in severity labels (critical vs high for the
  `=`/`===` bug, high vs medium for the off-by-one).
- GLM-5.3 Flash and DeepSeek also spotted an unplanted issue: `averagePrice` divides the
  revenue total by the line-item count, so it computes an average line total rather than
  the average unit price its name suggests.
- DeepSeek alone flagged two further robustness gaps (no null-safety on `items`, `null`
  entries in `users`), both honestly marked low and unverified against real callers.
- Times come from a single run on Windows and will vary. Per million tokens on OpenRouter,
  GLM-5.3 Flash is roughly $0.03 in / $0.09 out and DeepSeek V4.1 Flash $0.15 / $0.60,
  so the flash models cost cents per review; Codex runs on a ChatGPT login.

One small diff is not a rigorous benchmark — treat this as a taste of the comparison, not
a model ranking.

## Editing the prompts

- `review-prompt.md`: what reviewers look for and the output format.
- `summary-prompt.md`: how the comparison is structured.

## Requirements

PowerShell 7, git, and the CLIs logged in: `claude`, `codex` (`codex login`) and, only for
`-WithCopilot`, `copilot` (`copilot login`). For `-OpenCodeModels`, `opencode` with a
logged-in provider (`opencode auth login`). Claude is not needed when both `-NoClaude` and
`-SummaryModel` are passed.

## Privacy

The reviewed code is sent to each model's provider: Anthropic (Claude), OpenAI (Codex),
GitHub/Microsoft (Copilot), and the providers configured in OpenCode (for example OpenRouter
for GLM or DeepSeek). Check that this is allowed before using it on code that isn't yours.
