# Search Related PRs

Search for existing PRs and issues related to current changes before submitting new work.

## Process

### 1. Analyze Current Changes

First, understand what's being changed:

```bash
# Get list of changed files
git diff --name-only HEAD~1

# Get commit messages on current branch
git log origin/main..HEAD --oneline

# Summarize the changes
git diff --stat HEAD~1
```

Extract keywords from:
- File paths (e.g., "plan9", "networking", "init")
- Commit messages
- Function/class names modified

### 2. Search Open PRs

```bash
# Search by keywords
gh pr list --repo microsoft/WSL --state open --search "<keyword1> <keyword2>"

# Search by file paths
gh pr list --repo microsoft/WSL --state open --search "path:<directory>"
```

### 3. Search Closed PRs

```bash
# Recent closed PRs with similar keywords
gh pr list --repo microsoft/WSL --state closed --search "<keywords>" --limit 20

# Check if similar changes were rejected
gh pr list --repo microsoft/WSL --state closed --label "won't fix" --search "<keywords>"
```

### 4. Search Issues

```bash
# Open issues that might be addressed by these changes
gh issue list --repo microsoft/WSL --state open --search "<keywords>"

# Closed issues for context
gh issue list --repo microsoft/WSL --state closed --search "<keywords>" --limit 10
```

### 5. Report Findings

Provide a summary table:

| Type | # Found | Action Needed |
|------|---------|---------------|
| Open PRs (related) | X | Review for conflicts |
| Closed PRs (similar) | X | Check rejection reasons |
| Open Issues | X | Link in new PR |
| Closed Issues | X | Reference if relevant |

### 6. Recommendations

Based on findings, recommend:
- **Proceed**: No conflicts found
- **Coordinate**: Related open PR exists, consider collaborating
- **Reconsider**: Similar PR was rejected, review reasons
- **Link Issues**: Found issues that should be referenced

$ARGUMENTS
