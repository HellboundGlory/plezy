# Review log

One line per reviewed range: what the mandatory passes found, and anything
skipped with the reason. `<base>..<sha>` is the range reviewed, `+wt` an
uncommitted diff that had not landed when it was reviewed.

b3af54a55..c740208f1  simplify: 1 found / 1 fixed  code-review: 0 found  spec-review: 0 found
c740208f1..4f55b2b3d  simplify: 3 found / 3 fixed  code-review: 0 found  skipped: skills, prose-only range read against the runbook's own style rules
884bfe393..ad1ca0e28  simplify: 0 found  code-review: 0 found  skipped: skills, defect this range fixes came from the workflow dry run (version.json ignored --build-name)
ad1ca0e28..b063e786a  simplify: 0 found  code-review: 1 found / 1 fixed  skipped: skills, defect this range fixes came from the workflow dry run (jq reflowed the JSON the assertion matched on)
b063e786a..20106ca1b  simplify: 0 found  code-review: 0 found  skipped: skills, prose-only range correcting the version-stamp description
ac4fa58b0..8a2b6ac64  simplify: 0 found  code-review: 0 found  skipped: skills, prose-only note about upstream's disabled package workflow
