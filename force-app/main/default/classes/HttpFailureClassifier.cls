/**
 * @description Classifies a failed HTTP response: SOAP faults first, then the status code.
 * Implements FailureClassifier for HTTP_RESPONSE failures; classify(Integer) applies the status
 * rules alone to a bare status code. Retry-After headers are not considered here.
 *
 * SOAP faults are checked only when the status is 400 or 500, the body contains both "Envelope"
 * and "Fault", and the body is at most 100,000 characters: parsing XML with Dom.Document takes
 * several times the body's size in heap, and a heap LimitException can't be caught. Real faults
 * are a few KB. The standard fault code decides, in SOAP 1.1 (faultcode) or 1.2 (Code/Value):
 * - Client or Sender: POISON. The receiver says the message itself is wrong. A SOAP 1.1 dotted
 *   code such as Client.Authentication counts as Client.
 * - VersionMismatch, MustUnderstand or DataEncodingUnknown: TERMINAL. A protocol or
 *   configuration mismatch that someone fixes before replaying.
 * - Server or Receiver, a non-standard code, or a body that isn't a SOAP fault: the status rules
 *   decide. SAP PI also reports business errors as Server faults; per-integration overrides catch
 *   those by their text.
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
public inherited sharing class HttpFailureClassifier implements FailureClassifier {
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

  private static final String SOAP_11_NAMESPACE = 'http://schemas.xmlsoap.org/soap/envelope/';
  private static final String SOAP_12_NAMESPACE = 'http://www.w3.org/2003/05/soap-envelope';
  private static final Integer MAX_SOAP_BODY_LENGTH = 100000;

  // Standard SOAP fault codes that decide the verdict. Server and Receiver leave it to the status.
  private static final Map<String, FailureClass> SOAP_FAULT_CODES = new Map<String, FailureClass>{
    'Client' => FailureClass.POISON, // SOAP 1.1
    'Sender' => FailureClass.POISON, // SOAP 1.2
    'VersionMismatch' => FailureClass.TERMINAL,
    'MustUnderstand' => FailureClass.TERMINAL,
    'DataEncodingUnknown' => FailureClass.TERMINAL // SOAP 1.2
  };

  /**
   * @description Returns the verdict for a failed HTTP response: by its SOAP fault code if it is
   * a SOAP fault with a deciding code, otherwise by its status code.
   * @param failure a failure of kind HTTP_RESPONSE
   * @return RETRYABLE, TERMINAL or POISON
   * @throws IllegalArgumentException if failure is null or not HTTP_RESPONSE, or if its status
   * code is not a failure (see classify(Integer))
   */
  public FailureClass classify(IntegrationFailure failure) {
    if (failure == null) {
      throw new IllegalArgumentException(
        'Cannot classify a null IntegrationFailure.'
      );
    }
    if (failure.kind != IntegrationFailure.FailureKind.HTTP_RESPONSE) {
      throw new IllegalArgumentException(
        'HttpFailureClassifier handles HTTP_RESPONSE failures, not ' +
          failure.kind +
          '.'
      );
    }
    FailureClass soapVerdict = SOAP_FAULT_CODES.get(soapFaultCode(failure));
    return soapVerdict == null ? classify(failure.statusCode) : soapVerdict;
  }

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

  // Returns the standard fault code of a SOAP 1.1 or 1.2 fault, such as Client, without its
  // prefix or dotted subcode. Null when the response is not a SOAP fault worth parsing.
  private static String soapFaultCode(IntegrationFailure failure) {
    if (!mayBeSoapFault(failure.statusCode, failure.responseBody)) {
      return null;
    }
    Dom.XmlNode envelope;
    try {
      Dom.Document document = new Dom.Document();
      document.load(failure.responseBody);
      envelope = document.getRootElement();
    } catch (XmlException notXml) {
      // Not XML after all, so not a SOAP fault: the status rules decide.
      return null;
    }
    return faultCode(envelope);
  }

  // Cheap checks before any parsing. String.contains is case-sensitive, like XML names.
  private static Boolean mayBeSoapFault(Integer statusCode, String body) {
    return (statusCode == 400 ||
      statusCode == 500) &&
      body != null &&
      body.length() <= MAX_SOAP_BODY_LENGTH &&
      body.contains('Envelope') &&
      body.contains('Fault');
  }

  // Apex's == on Strings ignores case, but XML names and namespaces don't, hence equals().
  private static String faultCode(Dom.XmlNode envelope) {
    String soapNamespace = envelope.getNamespace();
    Boolean isSoap =
      SOAP_11_NAMESPACE.equals(soapNamespace) ||
      SOAP_12_NAMESPACE.equals(soapNamespace);
    if (!isSoap || !'Envelope'.equals(envelope.getName())) {
      return null;
    }
    Dom.XmlNode body = envelope.getChildElement('Body', soapNamespace);
    Dom.XmlNode fault = body == null
      ? null
      : body.getChildElement('Fault', soapNamespace);
    if (fault == null) {
      return null;
    }
    // SOAP 1.1 puts the code in an unqualified faultcode element; SOAP 1.2 in Code/Value.
    Dom.XmlNode code = SOAP_11_NAMESPACE.equals(soapNamespace)
      ? fault.getChildElement('faultcode', null)
      : soap12Value(fault.getChildElement('Code', SOAP_12_NAMESPACE));
    return code == null ? null : localCode(code, soapNamespace);
  }

  private static Dom.XmlNode soap12Value(Dom.XmlNode codeElement) {
    return codeElement == null
      ? null
      : codeElement.getChildElement('Value', SOAP_12_NAMESPACE);
  }

  // 'soap:Client.Authentication' becomes 'Client', but only if the prefix maps to the SOAP
  // namespace: a code in another namespace is not a standard SOAP fault code.
  private static String localCode(Dom.XmlNode codeNode, String soapNamespace) {
    String code = codeNode.getText().trim();
    if (code.contains(':')) {
      String prefix = code.substringBefore(':');
      if (!soapNamespace.equals(codeNode.getNamespaceFor(prefix))) {
        return null;
      }
      code = code.substringAfter(':');
    }
    return code.substringBefore('.');
  }
}
