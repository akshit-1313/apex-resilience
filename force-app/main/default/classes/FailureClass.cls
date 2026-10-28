/**
 * @description The verdict for a failed integration attempt. Classification comes before retry:
 * every failure gets exactly one of these verdicts, and the retry decision follows from it.
 */
public enum FailureClass {
  /**
   * Transient: the same request can succeed later. Retry with backoff.
   * Examples: timeouts, 429, most 5xx, UNABLE_TO_LOCK_ROW.
   */
  RETRYABLE,
  /**
   * Permanent for this request: the same message can succeed only after someone fixes something
   * outside it, such as configuration, permissions, master data or a validation rule. Don't
   * retry; a person fixes the cause, then replays the message.
   * Examples: 401, 403, 404, 409, missing master data.
   */
  TERMINAL,
  /**
   * The message itself can never succeed; only a different message can. Quarantine it.
   * Examples: an unparseable payload, 400 or 422, repeated identical failures.
   */
  POISON
}
