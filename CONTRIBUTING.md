# Contributing

Contributions are welcome, particularly real application audits, safety improvements, Windows compatibility fixes, and tests.

## Development rules

- Preserve the zero-resident-footprint principle.
- Add a failing test before changing behavior.
- Keep Windows PowerShell 5.1 compatibility unless the project explicitly changes its support policy.
- Tests target Pester 3.4 syntax (`Should Be`, not `Should -Be`) to match CI (`.github/workflows/ci.yml` pins `Pester 3.4.0`); do not introduce Pester 4/5-only syntax.
- Never add automatic cleanup based solely on a snapshot diff.
- Avoid persistent machine changes in tests.

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

## Contributing profiles

A profile pull request should include:

- exact application edition and version tested;
- Windows version;
- evidence explaining each service/process rule;
- whether licensing or helpers are shared with other products;
- a confirmed dry-run and real launch/exit test;
- environment-variable paths rather than user-specific paths.

Do not include license keys, usernames, private paths, telemetry identifiers, or snapshot files containing machine details.

## Commit style

Use short conventional prefixes such as `feat:`, `fix:`, `docs:`, and `test:`.
