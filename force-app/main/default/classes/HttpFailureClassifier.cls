/**
 * @description Classifies a failed HTTP callout by its status code alone. Exceptions, response
 * bodies and Retry-After headers are not considered here.
 *
 * Each status code band has a default verdict, and a few codes override their band:
 * - 3xx: TERMINAL. A redirect that reaches the classifier was not followed, so the endpoint
 *   configuration has to change.
 * - 4xx: TERMINAL, except 408, 425 and 429 (RETRYABLE: timing problems) and 400 and 422
 *   (POISON: the receiver rejected the body itself).
 * - 5xx: RETRYABLE, except 501 and 505 (TERMINAL: the server does not support the method or
 *   the HTTP version).
 * - Below 100 or above 599: RETRYABLE. RFC 9110 section 15 says a client should treat an invalid
 *   status code as a 5xx.
 *
 * 500 is retried by default, even though some middleware returns deterministic business errors
 * as 500: SOAP 1.1 faults always travel on 500, SAP PI's included. The defences, as the library
 * grows: per-integration overrides (Stage 1), and the attempt cap plus the rule that repeated
 * identical failures become POISON (Stage 2).
 */
public inherited sharing class HttpFailureClassifier {
  // Status codes whose verdict differs from the default for their band.
  private static final Map<Integer, FailureClass> SPECIAL_CASES = new Map<Integer, FailureClass>{
    400 => FailureClass.POISON, // Bad Request
    408 => FailureClass.RETRYABLE, // Request Timeout
    422 => FailureClass.POISON, // Unprocessable Content
    425 => FailureClass.RETRYABLE, // Too Early
    429 => FailureClass.RETRYABLE, // Too Many Requests
    501 => FailureClass.TERMINAL, // Not Implemented
    505 => FailureClass.TERMINAL // HTTP Version Not Supported
  };

  /**
   * @description Returns the verdict for the HTTP status code of a failed callout.
   * @param statusCode the status code of the failed response
   * @return RETRYABLE, TERMINAL or POISON
   * @throws IllegalArgumentException if statusCode is null or between 100 and 299. Neither is a
   * failure to classify: a request with no response is a CalloutException, and 1xx and 2xx
   * responses are not errors.
   */
  public FailureClass classify(Integer statusCode) {
    if (statusCode == null) {
      throw new IllegalArgumentException(
        'Cannot classify a null status code: a request that got no response surfaces as a CalloutException, not an HTTP status.'
      );
    }
    if (statusCode < 100 || statusCode > 599) {
      return FailureClass.RETRYABLE;
    }
    if (statusCode < 300) {
      throw new IllegalArgumentException(
        'Cannot classify status code ' +
          statusCode +
          ': 1xx and 2xx responses are not failures.'
      );
    }
    if (SPECIAL_CASES.containsKey(statusCode)) {
      return SPECIAL_CASES.get(statusCode);
    }
    // Band defaults: 3xx and 4xx need a person to change something; 5xx is the server's problem.
    return statusCode >= 500 ? FailureClass.RETRYABLE : FailureClass.TERMINAL;
  }
}
