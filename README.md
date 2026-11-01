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

Every classifier implements `FailureClassifier`, whose `classify` method takes an
`IntegrationFailure`: an immutable snapshot of one failed attempt, built from an HTTP response, a
`CalloutException` or a record's DML errors, plus the name of the integration it belongs to.

### HTTP responses

`HttpFailureClassifier` classifies a failed HTTP response: SOAP faults first, then the status code.

```apex
HttpResponse response = new Http().send(request);
if (response.getStatusCode() >= 300) {
  FailureClassifier classifier = new HttpFailureClassifier();
  FailureClass verdict = classifier.classify(
    IntegrationFailure.fromResponse('SAP_PI_Orders', response)
  );
  // RETRYABLE: retry with backoff. TERMINAL: alert a person. POISON: quarantine the message.
}
```

`new HttpFailureClassifier().classify(statusCode)` applies the status rules alone to a bare status
code.

**SOAP faults.** When the status is 400 or 500 and the body is a SOAP 1.1 or 1.2 fault, the
standard fault code decides:

| Fault code                                                 | Verdict      | Why                                                                                |
| ---------------------------------------------------------- | ------------ | ---------------------------------------------------------------------------------- |
| `Client` (SOAP 1.1), `Sender` (SOAP 1.2)                   | `POISON`     | The receiver says the message itself is wrong                                      |
| `VersionMismatch`, `MustUnderstand`, `DataEncodingUnknown` | `TERMINAL`   | A protocol or configuration mismatch; someone fixes the setup, then replays        |
| `Server` (1.1), `Receiver` (1.2), or any other code        | status rules | Usually transient. SAP PI also reports business errors here; overrides catch those |

A SOAP 1.1 dotted code such as `Client.Authentication` counts as `Client`. Bodies over 100,000
characters skip SOAP parsing and go straight to the status rules: XML parsing takes several times
the body's size in heap, and running out of heap can't be caught in Apex.

**Status codes:**

| Status code            | Verdict     | Why                                                                                                 |
| ---------------------- | ----------- | --------------------------------------------------------------------------------------------------- |
| 3xx                    | `TERMINAL`  | A redirect reached the classifier, so it wasn't followed; the endpoint configuration must change    |
| 408, 425, 429          | `RETRYABLE` | Timing problems; the same request can succeed later                                                 |
| 400, 422               | `POISON`    | The receiver rejected the body itself                                                               |
| Other 4xx              | `TERMINAL`  | Authentication, permissions, missing resources or conflicts: a person fixes the cause, then replays |
| 501, 505               | `TERMINAL`  | The server doesn't support the method or the HTTP version                                           |
| Other 5xx              | `RETRYABLE` | The server erred                                                                                    |
| Below 100 or above 599 | `RETRYABLE` | Invalid HTTP; RFC 9110 says to treat an invalid status code as a 5xx                                |

`null` and 100-299 throw `IllegalArgumentException`, because they aren't failures. So does a
failure of another kind passed to `HttpFailureClassifier`: that's a bug in the caller.

500 is retried by default, even though some middleware returns deterministic business errors as
500: SOAP 1.1 faults always travel on 500, SAP PI's included. SOAP `Client` faults are caught
above; for business errors reported as `Server` faults, planned per-integration overrides and
attempt caps are the defence.

### Callout exceptions

A callout that gets no response at all throws `CalloutException`. `CalloutFailureClassifier`
classifies it by its message, ignoring case:

```apex
try {
  HttpResponse response = new Http().send(request);
} catch (CalloutException error) {
  FailureClass verdict = new CalloutFailureClassifier()
    .classify(IntegrationFailure.fromCalloutException('SAP_PI_Orders', error));
}
```

| Message contains                   | Verdict     | Why                                                                                                    |
| ---------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------ |
| `Unauthorized endpoint`            | `TERMINAL`  | The Remote Site Setting is missing                                                                     |
| `named credential`                 | `TERMINAL`  | The named credential is missing or not permitted                                                       |
| `PKIX`, `certificate`, `handshake` | `TERMINAL`  | A TLS trust or certificate problem                                                                     |
| `uncommitted work pending`         | `TERMINAL`  | A callout after DML in the same transaction: a bug in the calling code                                 |
| Anything else                      | `RETRYABLE` | Timeouts, resets, refused connections and unreachable hosts are usually transient; attempts are capped |

A host that doesn't resolve falls into the last row: Salesforce sends callouts through a proxy, so
it surfaces as `Unable to tunnel through proxy. Proxy returns "HTTP/1.1 503 Service Unavailable"`,
the same message as a host that is briefly down.

### DML errors

`DmlFailureClassifier` classifies the errors DML returned for one record, by each error's status
code. It takes `Database.Error`, so it works for insert, update, upsert and delete results alike:

```apex
List<Database.SaveResult> results = Database.update(records, false);
for (Database.SaveResult result : results) {
  if (!result.isSuccess()) {
    FailureClass verdict = new DmlFailureClassifier()
      .classify(IntegrationFailure.fromDmlErrors('SAP_PI_Orders', result.getErrors()));
  }
}
```

| Status code                                                                                                                                                                 | Verdict     | Why                                                                                                      |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------------------------------------------------------------------------------- |
| `UNABLE_TO_LOCK_ROW`, or any error whose message contains it                                                                                                                | `RETRYABLE` | Row-lock contention clears once the other transaction commits; this also catches a lock inside a trigger |
| `REQUIRED_FIELD_MISSING`, `STRING_TOO_LONG`, `INVALID_TYPE_ON_FIELD_IN_RECORD`, `INVALID_EMAIL_ADDRESS`, `NUMBER_OUTSIDE_VALID_RANGE`, `MALFORMED_ID`, `DUPLICATE_VALUE`    | `POISON`    | The record's own data is wrong, so only a different message can succeed                                  |
| Anything else, for example `FIELD_CUSTOM_VALIDATION_EXCEPTION`, `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`, `INVALID_CROSS_REFERENCE_KEY`, `INSUFFICIENT_ACCESS_OR_READONLY` | `TERMINAL`  | A validation rule, a missing picklist value, missing master data or permissions: a person fixes it first |

When a record has several errors, the most severe wins: `POISON`, then `TERMINAL`, then
`RETRYABLE`. A record that is locked and also fails validation won't succeed on retry.

### Per-integration overrides

A status code or a message can't always tell the right verdict: SAP PI, for example, can report
"material does not exist" as a 500. Rules in the `FailureClassificationRule__mdt` Custom Metadata
type override the built-in verdict for one integration, or for all of them.
`ConfiguredFailureClassifier` is the entry point: rules first, then the built-in classifier for
the failure's kind.

```apex
FailureClassifier classifier = new ConfiguredFailureClassifier(); // loads the rules: one SOQL query
FailureClass verdict = classifier.classify(
  IntegrationFailure.fromResponse('SAP_PI_Orders', response)
);
```

| Field           | Meaning                                                                                                                                                |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `Integration`   | The integration's name, as passed to `IntegrationFailure`, matched without regard to case. Blank makes a global rule                                   |
| `Failure Kind`  | `HTTP_RESPONSE`, `CALLOUT_EXCEPTION` or `DML_ERRORS`                                                                                                   |
| `Status Code`   | HTTP status to match; blank matches any. `HTTP_RESPONSE` rules only                                                                                    |
| `Error Message` | Text the failure must contain, ignoring case: the response body, the exception message, or each DML error as `STATUS_CODE: message`. Blank matches any |
| `Verdict`       | `RETRYABLE`, `TERMINAL` or `POISON`                                                                                                                    |
| `Priority`      | Lower runs first                                                                                                                                       |
| `Active`        | Only active rules are used                                                                                                                             |

Example: Integration `SAP_PI_Orders`, Failure Kind `HTTP_RESPONSE`, Status Code `500`, Error
Message `Material does not exist`, Verdict `TERMINAL`. Store the distinctive part of a message,
not a whole response: bodies carry timestamps and IDs.

Rules for the failure's integration are tried before global rules, so a specific rule always beats
a general one; within each group, by priority, then by name. The first match wins. Validation
rules reject an unknown kind or verdict, and a status code on a non-HTTP rule. Rules load with one
SOQL query rather than `getAll()`, because `getAll()` cuts long text fields to 255 characters.

An override can also classify a 2xx response, such as a 200 whose body reports an error. Without
a matching rule, a 2xx still throws `IllegalArgumentException`.

## Roadmap

| Stage | Scope                                                                                                                                                  |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 0     | Project skeleton and CI; status-code classification. Done.                                                                                             |
| 1     | A classifier interface; classification of callout exceptions and DML results; per-integration overrides in Custom Metadata. Done.                      |
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
