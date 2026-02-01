# PR Workflow

Create a pull request following Microsoft's contribution guidelines.

## Required Steps

Before creating the PR, you MUST complete these steps in order:

### Step 1: Search for Related PRs and Issues

Search GitHub for existing PRs and issues related to the changes:

```bash
# Search for related open PRs
gh pr list --repo microsoft/WSL --state open --search "<keywords from changes>"

# Search for related closed PRs (to avoid duplicates)
gh pr list --repo microsoft/WSL --state closed --search "<keywords from changes>" --limit 10

# Search for related issues
gh issue list --repo microsoft/WSL --state all --search "<keywords from changes>" --limit 10
```

Report findings to the user:
- List any related open PRs (potential conflicts or duplicates)
- List any related closed PRs (prior art, rejected approaches)
- List any related issues (link these in the PR)

If duplicates or conflicts are found, STOP and ask the user how to proceed.

### Step 2: Verify CLA Status

Inform the user:
- Microsoft requires a Contributor License Agreement (CLA)
- A bot will automatically prompt when the PR is created
- One-time signing process at https://cla.microsoft.com

### Step 3: Check for Required Issue

Ask the user:
- "Do you have a GitHub issue filed for this change?"
- If not, offer to help create one first (required by Microsoft guidelines)

### Step 4: Validate Changes

Run pre-PR validation:

```bash
# Check for uncommitted changes
git status

# Verify branch is up to date with upstream
git fetch origin
git log HEAD..origin/main --oneline

# Run code formatting check
clang-format --dry-run --style=file $(git diff --name-only HEAD~1 | grep -E '\.(cpp|c|h)$') 2>/dev/null || echo "No C/C++ files to check"

# Validate copyright headers
python3 tools/devops/validate-copyright-headers.py 2>/dev/null || echo "Copyright validation skipped"
```

### Step 5: Generate PR Description

Create a PR description following this template:

```markdown
## Summary
[One paragraph describing what this PR does and why]

## Related Issue
Fixes #XXX (or "Related to #XXX")

## Changes
- [Bullet point list of key changes]

## Testing
- [How the changes were tested]
- [Benchmark results if performance-related]

## Checklist
- [ ] Code follows project style guidelines
- [ ] Changes have been tested locally
- [ ] Documentation updated (if applicable)
- [ ] No breaking changes (or documented if unavoidable)

## Screenshots/Benchmarks
[If applicable]
```

### Step 6: Create the PR

```bash
gh pr create --repo microsoft/WSL \
  --title "<concise title>" \
  --body "<generated description>" \
  --base main
```

### Step 7: Post-Creation Checklist

After PR is created:
1. Verify CLA bot has commented
2. Check automated validation status
3. Respond to any bot feedback
4. Share PR URL with user

## Usage

When the user asks to create a PR, run through ALL steps above. Do not skip the search for related PRs - this is critical to avoid duplicate work and conflicts.

$ARGUMENTS
