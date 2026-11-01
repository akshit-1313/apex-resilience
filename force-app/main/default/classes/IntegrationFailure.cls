/**
 * @description One failed integration attempt, captured so it can be classified: an HTTP response
 * with an error status, a callout that got no response, or DML that returned errors.
 *
 * Immutable. The factory methods copy the values out of the response, exception or error list,
 * so nothing done to those objects afterwards changes what was classified. Only the fields for
 * the failure's kind are set; the others are null.
 *
 * The factories reject only inputs with nothing to classify: null, or a DML result with no
 * errors. What the content means, for example that a 2xx status is not a failure, is for the
 * classifiers to decide.
 */
public inherited sharing class IntegrationFailure {
  /**
   * @description What kind of failure this is. The kind decides which classifier handles it. The
   * value names are the values allowed in FailureClassificationRule__mdt.FailureKind__c.
   */
  public enum FailureKind {
    /** An HTTP response with an error status. */
    HTTP_RESPONSE,
    /** A callout that got no response at all, which Apex raises as a CalloutException. */
    CALLOUT_EXCEPTION,
    /** A DML operation that returned one or more errors for a record. */
    DML_ERRORS
  }

  /**
   * @description The integration's name, for example SAP_PI_Orders. Overrides for this name apply
   * first; blank means only global overrides and the built-in rules apply.
   */
  public final String integration;

  /**
   * @description What kind of failure this is.
   */
  public final FailureKind kind;

  /**
   * @description The response's HTTP status code. Set for HTTP_RESPONSE only.
   */
  public final Integer statusCode;

  /**
   * @description The response's body. Set for HTTP_RESPONSE only.
   */
  public final String responseBody;

  /**
   * @description The exception's message. Set for CALLOUT_EXCEPTION only.
   */
  public final String exceptionMessage;

  // A private copy: Apex has no read-only list, so a public final list could still be changed.
  private final List<Database.Error> dmlErrors;

  private IntegrationFailure(String integration, HttpResponse response) {
    this.integration = integration;
    this.kind = FailureKind.HTTP_RESPONSE;
    this.statusCode = response.getStatusCode();
    this.responseBody = response.getBody();
  }

  private IntegrationFailure(String integration, CalloutException error) {
    this.integration = integration;
    this.kind = FailureKind.CALLOUT_EXCEPTION;
    this.exceptionMessage = error.getMessage();
  }

  private IntegrationFailure(String integration, List<Database.Error> errors) {
    this.integration = integration;
    this.kind = FailureKind.DML_ERRORS;
    this.dmlErrors = new List<Database.Error>(errors);
  }

  /**
   * @description Captures an HTTP response that came back with an error status.
   * @param integration the integration's name; blank means no integration-specific overrides
   * @param response the response; its status code and body are copied
   * @return the failure, of kind HTTP_RESPONSE
   * @throws IllegalArgumentException if response is null
   */
  public static IntegrationFailure fromResponse(
    String integration,
    HttpResponse response
  ) {
    if (response == null) {
      throw new IllegalArgumentException(
        'Cannot capture a null HttpResponse: a callout that got no response is a CalloutException; use fromCalloutException.'
      );
    }
    return new IntegrationFailure(integration, response);
  }

  /**
   * @description Captures a callout that got no response, such as a timeout or a refused
   * connection.
   * @param integration the integration's name; blank means no integration-specific overrides
   * @param error the exception; its message is copied
   * @return the failure, of kind CALLOUT_EXCEPTION
   * @throws IllegalArgumentException if error is null
   */
  public static IntegrationFailure fromCalloutException(
    String integration,
    CalloutException error
  ) {
    if (error == null) {
      throw new IllegalArgumentException(
        'Cannot capture a null CalloutException.'
      );
    }
    return new IntegrationFailure(integration, error);
  }

  /**
   * @description Captures the errors DML returned for one record. Takes Database.Error, so it
   * works for insert, update, upsert and delete results alike.
   * @param integration the integration's name; blank means no integration-specific overrides
   * @param errors the record's errors, for example from Database.SaveResult.getErrors(); the
   * list is copied
   * @return the failure, of kind DML_ERRORS
   * @throws IllegalArgumentException if errors is null or empty: a successful result has no
   * errors, so there is nothing to classify
   */
  public static IntegrationFailure fromDmlErrors(
    String integration,
    List<Database.Error> errors
  ) {
    if (errors == null || errors.isEmpty()) {
      throw new IllegalArgumentException(
        'Cannot capture DML errors from a null or empty list: a successful DML result has no errors to classify.'
      );
    }
    return new IntegrationFailure(integration, errors);
  }

  /**
   * @description Returns the DML errors. Set for DML_ERRORS only.
   * @return a copy of the errors, so changing it does not change this failure; null for other
   * kinds
   */
  public List<Database.Error> getDmlErrors() {
    return dmlErrors == null ? null : new List<Database.Error>(dmlErrors);
  }
}
