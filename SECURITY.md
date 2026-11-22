# Security policy

## Reporting

Please report security issues privately through GitHub's security-advisory feature rather than opening a public issue with exploit details.

## Security-sensitive areas

LeanLaunch may start/stop Windows services and terminate explicitly configured processes. Reviews should focus on:

- profile path traversal;
- shell/argument injection;
- unsafe environment expansion;
- same-name process collisions;
- stopping pre-existing services;
- PID reuse or stale process identity;
- untrusted contributed profiles;
- elevation boundaries;
- installer PATH handling.

## Trust model

Profiles are executable policy, even though they are JSON. Review downloaded profiles before use. LeanLaunch intentionally refuses to infer cleanup actions automatically from snapshot differences.

The project does not collect telemetry or install resident components.
