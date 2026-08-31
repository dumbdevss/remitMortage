# Test Coverage Threshold Gates

CI enforces a **minimum test coverage** for the backend and the smart
contracts. A pull request that drops coverage below the configured floor fails
CI and cannot merge. This turns the coverage reports (previously informational
only) into an actual quality gate.

## Where the gates live

| Area      | Tool             | Threshold config                                              | CI job / step                                   |
| --------- | ---------------- | ------------------------------------------------------------- | ---------------------------------------------- |
| Backend   | Jest             | `backend/package.json` → `jest.coverageThreshold.global`      | `CI` → `backend-ci` → **Backend Test Coverage Gate** |
| Contracts | cargo-tarpaulin  | `--fail-under` flag in `.github/workflows/ci.yml`             | `CI` → `contracts-coverage` → **Run Coverage** |

### Backend (Jest)

`npm run test:coverage` runs the suite with `--coverage`. Jest exits non-zero
when any of `statements` / `branches` / `functions` / `lines` for the whole
project falls below the values in `jest.coverageThreshold.global`.

Run it locally before pushing:

```bash
cd backend
npm run test:coverage
```

### Contracts (cargo-tarpaulin)

The `Run Coverage` step passes `--fail-under <pct>`; tarpaulin exits non-zero
when total line coverage is below that percentage.

Run it locally:

```bash
cd contracts
cargo tarpaulin --workspace --exclude-files "tests/**/*" --fail-under <pct>
```

## Current thresholds

| Metric                | Backend | Contracts |
| --------------------- | ------- | --------- |
| Lines                 | 60%     | 55%       |
| Statements            | 60%     | —         |
| Functions             | 55%     | —         |
| Branches              | 45%     | —         |

These were seeded **deliberately below** the measured baseline so the gate does
not produce false failures on unrelated PRs while the numbers are being
calibrated. They are a floor, not a target.

## Adjusting a threshold

Thresholds ratchet **up**, not down. The normal direction of travel is: as the
suite improves, raise the floor so the improvement can't silently regress.

### To raise a threshold (routine)

1. Confirm `main` is green and note the current coverage from the CI job
   output or the uploaded `*-coverage-report` artifact.
2. Set the new threshold ~2–5 percentage points **below** that measured value
   (headroom for legitimate churn — a refactor that deletes well-covered code,
   a dependency-driven test skip).
3. Open a PR that changes only the threshold config, referencing the CI run the
   number came from.

### To lower a threshold (exceptional — requires justification)

Lowering the floor is a last resort. It is only acceptable when:

- A large, well-tested module is **intentionally removed**, or
- Coverage tooling changes what it counts (e.g. a Jest/tarpaulin upgrade), or
- A test suite is **temporarily** quarantined for a tracked flake, with a
  linked issue and a target date to restore it.

Requirements for a lowering PR:

1. The PR description states which of the above applies and links the relevant
   issue.
2. The drop is the **minimum** needed — match the new measured baseline minus
   the standard 2–5 point headroom, not a round number well below it.
3. At least one maintainer approval specifically acknowledging the coverage
   reduction.
4. If the cause is temporary (quarantined suite), a follow-up issue is opened
   to raise the threshold back once resolved.

## Rationale

A coverage number that is only ever *reported* drifts downward one unreviewed
PR at a time. A gate makes each reduction a visible, deliberate decision with a
paper trail, while still allowing the number to climb freely.
