# apex-resilience

[![CI](https://github.com/akshit-1313/apex-resilience/actions/workflows/ci.yml/badge.svg?branch=main&event=push)](https://github.com/akshit-1313/apex-resilience/actions/workflows/ci.yml?query=branch%3Amain+event%3Apush)

_Decide what to retry. Retry it safely. Park what will never succeed._

An open-source Apex library for Salesforce integrations that fail gracefully. Its core idea:
**classification comes before retry.**

> [!WARNING]
> **Status: pre-alpha.** The API will change, there is no installable package yet, and it is not
> ready for production use.

## Why

Most retry frameworks assume a failure is worth retrying and only ask how many times and how long
to wait. But a timeout is worth retrying, and a missing master-data record is not: it fails the
same way every time and just fills the queue. apex-resilience makes that decision its main
abstraction. Every failure gets one of three verdicts:

| Verdict     | Meaning                                                                                                                                                                                  | Examples                                                      |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `RETRYABLE` | Transient: the same request can succeed later. Retry with backoff.                                                                                                                       | Timeouts, 429, most 5xx, `UNABLE_TO_LOCK_ROW`                 |
| `TERMINAL`  | The same message can succeed once someone fixes something outside it: configuration, permissions, master data or a validation rule. Don't retry; a person fixes the cause, then replays. | 401, 403, 404, 409, missing master data                       |
| `POISON`    | Only a different message can succeed. Quarantine it.                                                                                                                                     | An unparseable payload, 400, 422, repeated identical failures |

Backoff with jitter, dead-lettering, idempotency and circuit breaking all build on that decision.

## What works today

`HttpFailureClassifier` classifies a failed callout by its HTTP status code:

```apex
HttpResponse response = new Http().send(request);
if (response.getStatusCode() >= 300) {
  FailureClass verdict = new HttpFailureClassifier().classify(response.getStatusCode());
  // RETRYABLE: retry with backoff. TERMINAL: alert a person. POISON: quarantine the message.
}
```

| Status code            | Verdict     | Why                                                                                                 |
| ---------------------- | ----------- | --------------------------------------------------------------------------------------------------- |
| 3xx                    | `TERMINAL`  | A redirect reached the classifier, so it wasn't followed; the endpoint configuration must change    |
| 408, 425, 429          | `RETRYABLE` | Timing problems; the same request can succeed later                                                 |
| 400, 422               | `POISON`    | The receiver rejected the body itself                                                               |
| Other 4xx              | `TERMINAL`  | Authentication, permissions, missing resources or conflicts: a person fixes the cause, then replays |
| 501, 505               | `TERMINAL`  | The server doesn't support the method or the HTTP version                                           |
| Other 5xx              | `RETRYABLE` | The server erred                                                                                    |
| Below 100 or above 599 | `RETRYABLE` | Invalid HTTP; RFC 9110 says to treat an invalid status code as a 5xx                                |

`null` and 100-299 throw `IllegalArgumentException`, because they aren't failures.

500 is retried by default, even though some middleware returns deterministic business errors as
500: SOAP 1.1 faults always travel on 500, SAP PI's included. Planned per-integration overrides and
attempt caps are the defence.

## Roadmap

| Stage | Scope                                                                                                                                                  |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 0     | Project skeleton and CI; status-code classification. **Current.**                                                                                      |
| 1     | A classifier interface; classification of callout exceptions and DML results; per-integration overrides in Custom Metadata                             |
| 2     | A request ledger (custom object); dispatch through Queueable and Transaction Finalizer; backoff with full jitter; idempotency keys; dead-letter status |
| 3     | A scheduled sweeper that recovers orphaned requests; an invocable replay action; a purge job                                                           |
| 4     | The v0.1 unlocked package                                                                                                                              |
| Later | Circuit breaker, a row-lock retry helper for batch DML, bulkheads, a Nebula Logger adapter                                                             |

## Prior art

These projects overlap with parts of apex-resilience and are worth knowing:

- [jantaks/salesforce-apex-retry](https://github.com/jantaks/salesforce-apex-retry): scheduled
  Queueable retries backed by a custom object, with basic HTTP status classification.
- [j-fischer/rflib](https://github.com/j-fischer/rflib): a broad framework; retry is one
  Platform-Event-based feature inside it.
- [afawcett/force-brf](https://github.com/afawcett/force-brf): batch retry built on
  `BatchApexErrorEvent`, marked as a work in progress.
- [jongpie/NebulaLogger](https://github.com/jongpie/NebulaLogger): logging, not retry.
  apex-resilience plans to integrate with it rather than compete.

What's different here: failure classification is the core abstraction, covering callouts and DML,
with dead-lettering, idempotency and circuit breaking planned as one tested, documented package.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md). Please report vulnerabilities privately, as described in
[SECURITY.md](SECURITY.md).

## Licence

[MIT](LICENSE)
