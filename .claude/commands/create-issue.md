# Create GitHub Issue

Create a GitHub issue for tracking a feature or bug fix (required before submitting PR to Microsoft repos).

## Process

### 1. Determine Issue Type

Ask the user:
- **Feature Request**: New functionality
- **Bug Fix**: Fixing broken behavior
- **Performance**: Optimization work
- **Documentation**: Doc improvements

### 2. Search for Duplicates

```bash
# Search existing issues
gh issue list --repo microsoft/WSL --state all --search "<keywords>" --limit 20
```

If duplicates found, ask user whether to:
- Comment on existing issue instead
- Proceed with new issue (explain differences)

### 3. Generate Issue Content

#### For Feature Requests:
```markdown
## Feature Description
[Clear description of the proposed feature]

## Motivation
[Why this feature is needed - what problem does it solve?]

## Proposed Solution
[High-level approach to implementation]

## Alternatives Considered
[Other approaches that were considered]

## Additional Context
[Any other relevant information, benchmarks, etc.]
```

#### For Bug Fixes:
```markdown
## Bug Description
[Clear description of the bug]

## Steps to Reproduce
1. [Step 1]
2. [Step 2]
3. [Observe issue]

## Expected Behavior
[What should happen]

## Actual Behavior
[What actually happens]

## Environment
- Windows Version:
- WSL Version:
- Distribution:

## Additional Context
[Logs, screenshots, etc.]
```

#### For Performance Issues:
```markdown
## Performance Issue
[Description of the performance problem]

## Current Behavior
[Current performance metrics]

## Expected/Desired Performance
[Target performance goals]

## Proposed Optimization
[Approach to improve performance]

## Benchmarks
[Before/after measurements if available]

## Environment
- Hardware:
- Windows Version:
- WSL Version:
```

### 4. Create the Issue

```bash
gh issue create --repo microsoft/WSL \
  --title "<concise title>" \
  --body "<generated content>"
```

### 5. Return Issue Number

Save the issue number for use in PR creation:
```
Created issue #XXX: <title>
Use this issue number when creating your PR.
```

$ARGUMENTS
