/**
 * @description Classifies a callout that got no HTTP response, which Apex raises as a
 * CalloutException, by the exception's message. Matching is a case-insensitive "contains".
 *
 * TERMINAL when the message shows something a person must fix:
 * - "Unauthorized endpoint": the Remote Site Setting is missing.
 * - "named credential": the named credential is missing or not permitted.
 * - "PKIX", "certificate", "handshake": TLS trust or certificate problems.
 * - "uncommitted work pending": a callout after DML in the same transaction, a code bug.
 *
 * Everything else is RETRYABLE. No response at all is most often transient, and the attempt cap
 * bounds the cost when it isn't. Known transient messages: "Read timed out", "connect timed
 * out", "Exceeded maximum time allotted for callout", "Connection reset", "Connection refused",
 * "Unexpected end of file". A host that doesn't resolve also lands here: Salesforce sends callouts
 * through a proxy, so it surfaces as "Unable to tunnel through proxy. Proxy returns HTTP/1.1 503",
 * the same message as a host that is briefly down.
 */
public inherited sharing class CalloutFailureClassifier implements FailureClassifier {
  // Messages that mean a person must fix configuration or code. Checked in this order.
  private static final List<String> TERMINAL_MESSAGES = new List<String>{
    'Unauthorized endpoint',
    'named credential',
    'PKIX',
    'certificate',
    'handshake',
    'uncommitted work pending'
  };

  /**
   * @description Returns the verdict for a callout that got no response, by its message.
   * @param failure a failure of kind CALLOUT_EXCEPTION
   * @return TERMINAL if the message shows a configuration or code problem; otherwise RETRYABLE
   * @throws IllegalArgumentException if failure is null or not CALLOUT_EXCEPTION
   */
  public FailureClass classify(IntegrationFailure failure) {
    if (failure == null) {
      throw new IllegalArgumentException(
        'Cannot classify a null IntegrationFailure.'
      );
    }
    if (failure.kind != IntegrationFailure.FailureKind.CALLOUT_EXCEPTION) {
      throw new IllegalArgumentException(
        'CalloutFailureClassifier handles CALLOUT_EXCEPTION failures, not ' +
          failure.kind +
          '.'
      );
    }
    // Never null: an exception built without a message reports "Script-thrown exception".
    for (String terminalMessage : TERMINAL_MESSAGES) {
      if (failure.exceptionMessage.containsIgnoreCase(terminalMessage)) {
        return FailureClass.TERMINAL;
      }
    }
    return FailureClass.RETRYABLE;
  }
}
