/**
 * @description Classifies the errors DML returned for one record, by each error's status code.
 *
 * - RETRYABLE: UNABLE_TO_LOCK_ROW, or any error whose message contains it. Checked first, so a
 *   lock hit inside a trigger, which surfaces as CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY, is still
 *   retried. Row-lock contention clears once the other transaction commits.
 * - POISON: the record's own data is wrong, so only a different message can succeed:
 *   REQUIRED_FIELD_MISSING, STRING_TOO_LONG, INVALID_TYPE_ON_FIELD_IN_RECORD,
 *   INVALID_EMAIL_ADDRESS, NUMBER_OUTSIDE_VALID_RANGE, MALFORMED_ID, and DUPLICATE_VALUE (a unique
 *   field already holds the value, so resending the same message collides every time).
 * - TERMINAL: everything else. A person fixes something outside the message, then replays it.
 *   Known examples: FIELD_CUSTOM_VALIDATION_EXCEPTION (a validation rule),
 *   INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST (an admin adds the value), INVALID_CROSS_REFERENCE_KEY
 *   and ENTITY_IS_DELETED (missing master data), INSUFFICIENT_ACCESS_OR_READONLY and
 *   INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY (permissions), ENTITY_IS_LOCKED (an approval
 *   lock), DUPLICATES_DETECTED (a duplicate rule) and CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY (a
 *   trigger or Flow failed). Unknown codes are TERMINAL too, so they don't refill the queue before
 *   a person has looked.
 *
 * Several errors on one record: the most severe wins, POISON over TERMINAL over RETRYABLE. A
 * record that is locked and also fails validation won't succeed on retry.
 */
public inherited sharing class DmlFailureClassifier implements FailureClassifier {
  private static final String ROW_LOCK = 'UNABLE_TO_LOCK_ROW';

  // Status codes that mean the record's own data is wrong.
  private static final Set<StatusCode> POISON_CODES = new Set<StatusCode>{
    StatusCode.REQUIRED_FIELD_MISSING,
    StatusCode.STRING_TOO_LONG,
    StatusCode.INVALID_TYPE_ON_FIELD_IN_RECORD,
    StatusCode.INVALID_EMAIL_ADDRESS,
    StatusCode.NUMBER_OUTSIDE_VALID_RANGE,
    StatusCode.MALFORMED_ID,
    StatusCode.DUPLICATE_VALUE
  };

  /**
   * @description Returns the verdict for the errors DML returned for one record.
   * @param failure a failure of kind DML_ERRORS
   * @return the most severe verdict among the record's errors
   * @throws IllegalArgumentException if failure is null or not DML_ERRORS
   */
  public FailureClass classify(IntegrationFailure failure) {
    if (failure == null) {
      throw new IllegalArgumentException(
        'Cannot classify a null IntegrationFailure.'
      );
    }
    if (failure.kind != IntegrationFailure.FailureKind.DML_ERRORS) {
      throw new IllegalArgumentException(
        'DmlFailureClassifier handles DML_ERRORS failures, not ' +
          failure.kind +
          '.'
      );
    }
    Set<FailureClass> verdicts = new Set<FailureClass>();
    for (Database.Error error : failure.getDmlErrors()) {
      verdicts.add(classifyError(error));
    }
    if (verdicts.contains(FailureClass.POISON)) {
      return FailureClass.POISON;
    }
    if (verdicts.contains(FailureClass.TERMINAL)) {
      return FailureClass.TERMINAL;
    }
    return FailureClass.RETRYABLE;
  }

  private FailureClass classifyError(Database.Error error) {
    String message = error.getMessage();
    if (
      error.getStatusCode() == StatusCode.UNABLE_TO_LOCK_ROW ||
      (message != null && message.contains(ROW_LOCK))
    ) {
      return FailureClass.RETRYABLE;
    }
    if (POISON_CODES.contains(error.getStatusCode())) {
      return FailureClass.POISON;
    }
    return FailureClass.TERMINAL;
  }
}
