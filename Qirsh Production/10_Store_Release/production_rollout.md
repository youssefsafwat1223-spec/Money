# Production Rollout

## Ordered sequence

```
1. Legal site live                        (Phase 1)
2. Production Supabase project created    (Phase 2)
3. Secrets set                            (Phase 3.1)
4. Migrations 0001–0091 applied           (Phase 3.2)
5. 24 Edge Functions deployed             (Phase 3.3)
6. Backend verification sweep             (Phase 3.4)
7. Apple + Android configuration          (Phases 5, 6)
8. Signed builds with LEGAL_BASE_URL      (Phase 7)
9. Physical-device QA + UX-035            (Phase 8)
10. Internal beta, ≥1 week                (Phase 9)
11. PUSH proof → activation → verify      (Phase 10.3)
12. PULL proof → activation → verify      (Phase 10.4)
13. Store submission                      (Phase 11)
14. Staged rollout                        (Phase 12)
15. Monitoring
```

Steps 1, 2, 7 are independent and should run in parallel — they are the critical
path and each waits on an external party.

## Staged rollout

### Google Play
5% → 20% → 50% → 100%, **at least 24h at each step**. Halt at the current
percentage on any regression; do not roll forward through a signal.

### App Store
Phased release (7-day automatic ramp). Can be paused from App Store Connect.

## Monitoring at each stage

| Signal | Where | Threshold to halt |
|---|---|---|
| Crash-free sessions | Play Console / App Store Connect | <99% |
| Sentry error rate | Sentry | any new error affecting >0.5% |
| Parse failure rate | `sms_parsers` telemetry | a sudden rise on any bank |
| Parked writes | outbox | growing rather than draining |
| Auth failures | Supabase logs | any sustained rise |
| Support reports of wrong amounts | support inbox | **any at all — this is a halt** |

## Why capability activation comes after beta

Activating exact-money sync before real-device beta would mean proving a
financial transport against a build nobody has used in anger. The order exists so
that when PUSH is activated, the only new variable is the transport.
