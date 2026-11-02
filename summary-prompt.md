Several AI models reviewed the same code independently. Their reviews are in these files:

{{REVIEWS}}

The scope they reviewed is described in `{{RUN_DIR}}/scope.md`.

Compare the reviews. Two findings are the same issue when they point at the same problem in
the same place, even if they are worded differently or give slightly different line numbers.
Read the code when you need to decide whether two findings are the same issue or whether
reviewers really disagree. Do not modify any file.

Do NOT add findings of your own. Your job is to compare, not to review.

Output format: Markdown, nothing before or after it.

# Review comparison

## Found by all reviewers
Highest confidence. For each issue: severity (the highest any reviewer gave, and note if they
differ), title, `path:line`, one-sentence problem, which reviewers.

## Found by only one reviewer
Grouped by reviewer. Same fields. Add a one-line note when the issue looks clearly valid or
clearly wrong after checking the code; otherwise write "needs a human look".

## Contradictions
Places where reviewers disagree (one says it is a bug, another says the same code is correct,
or they propose incompatible fixes). Explain both positions and what would settle it.
Write "None." if there are none.

## Where to look first
At most five bullet points, most important first.
