/**
 * Table-driven tests for HttpFailureClassifier. Each test collects every wrong row and asserts
 * once, so a failing run lists all of them instead of stopping at the first.
 *
 * ApexUnitTestClassShouldHaveRunAs is suppressed: runAs verifies behaviour under a user's
 * permissions and sharing, and the classifier reads and writes no data, so nothing about it
 * depends on the running user.
 */
@IsTest
@SuppressWarnings('PMD.ApexUnitTestClassShouldHaveRunAs')
private class HttpFailureClassifierTest {
  // One table for both entry points, so classify(Integer) and the interface can never disagree.
  private static Map<Integer, FailureClass> verdictTable() {
    return new Map<Integer, FailureClass>{
      // Invalid HTTP status codes are treated as 5xx (RFC 9110 section 15)
      -1 => FailureClass.RETRYABLE,
      0 => FailureClass.RETRYABLE,
      99 => FailureClass.RETRYABLE,
      600 => FailureClass.RETRYABLE,
      999 => FailureClass.RETRYABLE,
      // 3xx: a redirect that wasn't followed
      300 => FailureClass.TERMINAL,
      302 => FailureClass.TERMINAL,
      399 => FailureClass.TERMINAL,
      // 4xx special cases
      400 => FailureClass.POISON,
      408 => FailureClass.RETRYABLE,
      422 => FailureClass.POISON,
      425 => FailureClass.RETRYABLE,
      429 => FailureClass.RETRYABLE,
      // Other 4xx
      401 => FailureClass.TERMINAL,
      403 => FailureClass.TERMINAL,
      404 => FailureClass.TERMINAL,
      409 => FailureClass.TERMINAL,
      499 => FailureClass.TERMINAL,
      // 5xx special cases
      501 => FailureClass.TERMINAL,
      505 => FailureClass.TERMINAL,
      // Other 5xx
      500 => FailureClass.RETRYABLE,
      502 => FailureClass.RETRYABLE,
      503 => FailureClass.RETRYABLE,
      504 => FailureClass.RETRYABLE,
      599 => FailureClass.RETRYABLE
    };
  }

  private static HttpResponse response(Integer statusCode) {
    HttpResponse response = new HttpResponse();
    response.setStatusCode(statusCode);
    response.setBody('{"error":"test"}');
    return response;
  }

  @IsTest
  static void classifiesEveryFailureCodeBand() {
    Map<Integer, FailureClass> expectedVerdicts = verdictTable();
    HttpFailureClassifier classifier = new HttpFailureClassifier();
    List<String> mismatches = new List<String>();

    for (Integer statusCode : expectedVerdicts.keySet()) {
      FailureClass expectedVerdict = expectedVerdicts.get(statusCode);
      try {
        FailureClass actualVerdict = classifier.classify(statusCode);
        if (actualVerdict != expectedVerdict) {
          mismatches.add(
            statusCode +
              ': expected ' +
              expectedVerdict +
              ', got ' +
              actualVerdict
          );
        }
      } catch (Exception unexpected) {
        mismatches.add(
          statusCode +
            ': expected ' +
            expectedVerdict +
            ', threw ' +
            unexpected.getTypeName()
        );
      }
    }

    Assert.areEqual(
      0,
      mismatches.size(),
      'Misclassified status codes: ' + String.join(mismatches, '; ')
    );
  }

  @IsTest
  static void classifiesHttpResponsesThroughTheInterface() {
    Map<Integer, FailureClass> expectedVerdicts = verdictTable();
    FailureClassifier classifier = new HttpFailureClassifier();
    List<String> mismatches = new List<String>();

    for (Integer statusCode : expectedVerdicts.keySet()) {
      FailureClass expectedVerdict = expectedVerdicts.get(statusCode);
      try {
        FailureClass actualVerdict = classifier.classify(
          IntegrationFailure.fromResponse('Test', response(statusCode))
        );
        if (actualVerdict != expectedVerdict) {
          mismatches.add(
            statusCode +
              ': expected ' +
              expectedVerdict +
              ', got ' +
              actualVerdict
          );
        }
      } catch (Exception unexpected) {
        mismatches.add(
          statusCode +
            ': expected ' +
            expectedVerdict +
            ', threw ' +
            unexpected.getTypeName()
        );
      }
    }

    Assert.areEqual(
      0,
      mismatches.size(),
      'Misclassified responses: ' + String.join(mismatches, '; ')
    );
  }

  private static String soap11Fault(String faultCode) {
    return '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><soap:Fault>' +
      '<faultcode>' +
      faultCode +
      '</faultcode><faultstring>Material 4711 does not exist</faultstring>' +
      '</soap:Fault></soap:Body></soap:Envelope>';
  }

  private static String soap12Fault(String codeValue) {
    return '<env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope"><env:Body><env:Fault>' +
      '<env:Code><env:Value>' +
      codeValue +
      '</env:Value></env:Code><env:Reason><env:Text xml:lang="en">Invalid order</env:Text></env:Reason>' +
      '</env:Fault></env:Body></env:Envelope>';
  }

  @IsTest
  static void classifiesSoapFaults() {
    // Each label starts with the response's status code.
    Map<String, String> bodies = new Map<String, String>{
      '500 SOAP 1.1 Client' => soap11Fault('soap:Client'),
      '500 SOAP 1.1 dotted Client code' => soap11Fault(
        'soap:Client.InvalidMaterial'
      ),
      '500 SOAP 1.1 unprefixed Client' => soap11Fault('Client'),
      '500 SOAP 1.1 Server' => soap11Fault('soap:Server'),
      '400 SOAP 1.1 Server' => soap11Fault('soap:Server'),
      '500 SOAP 1.1 VersionMismatch' => soap11Fault('soap:VersionMismatch'),
      '500 SOAP 1.1 MustUnderstand' => soap11Fault('soap:MustUnderstand'),
      '502 SOAP 1.1 Client, not checked on 502' => soap11Fault('soap:Client'),
      '500 SOAP 1.1 Client in a non-SOAP namespace' => soap11Fault('sap:Client')
        .replace(
          '<faultcode>',
          '<faultcode xmlns:sap="urn:sap-com:document:sap">'
        ),
      '500 SOAP 1.1 fault without a faultcode' => soap11Fault('soap:Client')
        .replace('<faultcode>soap:Client</faultcode>', ''),
      '500 SOAP 1.1 Client over 100,000 characters' => soap11Fault(
          'soap:Client'
        )
        .replace('Material 4711 does not exist', 'x'.repeat(100000)),
      '400 SOAP 1.2 Sender' => soap12Fault('env:Sender'),
      '500 SOAP 1.2 Sender' => soap12Fault('env:Sender'),
      '500 SOAP 1.2 Receiver' => soap12Fault('env:Receiver'),
      '500 SOAP 1.2 DataEncodingUnknown' => soap12Fault(
        'env:DataEncodingUnknown'
      ),
      '500 SOAP 1.2 fault without a Code' => soap12Fault('env:Sender')
        .replace('<env:Code><env:Value>env:Sender</env:Value></env:Code>', ''),
      '500 Envelope without a Fault element' => '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><m:Result xmlns:m="urn:example">Fault tolerance off</m:Result></soap:Body></soap:Envelope>',
      '500 Envelope without a Body' => '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Header><m:Fault xmlns:m="urn:example"/></soap:Header></soap:Envelope>',
      '500 Envelope in a non-SOAP namespace' => '<Envelope xmlns="urn:example"><Body><Fault><faultcode>Client</faultcode></Fault></Body></Envelope>',
      '500 Not XML' => 'Envelope Fault: <soap:Envelope><soap:Fault>'
    };
    Map<String, FailureClass> expectedVerdicts = new Map<String, FailureClass>{
      '500 SOAP 1.1 Client' => FailureClass.POISON,
      '500 SOAP 1.1 dotted Client code' => FailureClass.POISON,
      '500 SOAP 1.1 unprefixed Client' => FailureClass.POISON,
      '500 SOAP 1.1 Server' => FailureClass.RETRYABLE,
      '400 SOAP 1.1 Server' => FailureClass.POISON,
      '500 SOAP 1.1 VersionMismatch' => FailureClass.TERMINAL,
      '500 SOAP 1.1 MustUnderstand' => FailureClass.TERMINAL,
      '502 SOAP 1.1 Client, not checked on 502' => FailureClass.RETRYABLE,
      '500 SOAP 1.1 Client in a non-SOAP namespace' => FailureClass.RETRYABLE,
      '500 SOAP 1.1 fault without a faultcode' => FailureClass.RETRYABLE,
      '500 SOAP 1.1 Client over 100,000 characters' => FailureClass.RETRYABLE,
      '400 SOAP 1.2 Sender' => FailureClass.POISON,
      '500 SOAP 1.2 Sender' => FailureClass.POISON,
      '500 SOAP 1.2 Receiver' => FailureClass.RETRYABLE,
      '500 SOAP 1.2 DataEncodingUnknown' => FailureClass.TERMINAL,
      '500 SOAP 1.2 fault without a Code' => FailureClass.RETRYABLE,
      '500 Envelope without a Fault element' => FailureClass.RETRYABLE,
      '500 Envelope without a Body' => FailureClass.RETRYABLE,
      '500 Envelope in a non-SOAP namespace' => FailureClass.RETRYABLE,
      '500 Not XML' => FailureClass.RETRYABLE
    };
    FailureClassifier classifier = new HttpFailureClassifier();
    List<String> mismatches = new List<String>();

    for (String label : expectedVerdicts.keySet()) {
      FailureClass expectedVerdict = expectedVerdicts.get(label);
      HttpResponse response = new HttpResponse();
      response.setStatusCode(Integer.valueOf(label.substringBefore(' ')));
      response.setBody(bodies.get(label));
      try {
        FailureClass actualVerdict = classifier.classify(
          IntegrationFailure.fromResponse('Test', response)
        );
        if (actualVerdict != expectedVerdict) {
          mismatches.add(
            label + ': expected ' + expectedVerdict + ', got ' + actualVerdict
          );
        }
      } catch (Exception unexpected) {
        mismatches.add(
          label +
            ': expected ' +
            expectedVerdict +
            ', threw ' +
            unexpected.getTypeName() +
            ': ' +
            unexpected.getMessage()
        );
      }
    }

    Assert.areEqual(
      0,
      mismatches.size(),
      'Misclassified SOAP responses: ' + String.join(mismatches, '; ')
    );
  }

  @IsTest
  static void rejectsFailuresItDoesNotHandle() {
    List<Database.Error> dmlErrors = (List<Database.Error>) JSON.deserialize(
      '[{"statusCode":"UNABLE_TO_LOCK_ROW","message":"locked","fields":[]}]',
      List<Database.Error>.class
    );
    // Each key is text the error message must contain.
    Map<String, IntegrationFailure> failures = new Map<String, IntegrationFailure>{
      'null' => null,
      'CALLOUT_EXCEPTION' => IntegrationFailure.fromCalloutException(
        'Test',
        new CalloutException('Read timed out')
      ),
      'DML_ERRORS' => IntegrationFailure.fromDmlErrors('Test', dmlErrors),
      '200' => IntegrationFailure.fromResponse('Test', response(200))
    };
    FailureClassifier classifier = new HttpFailureClassifier();
    List<String> problems = new List<String>();

    for (String expectedText : failures.keySet()) {
      try {
        FailureClass verdict = classifier.classify(failures.get(expectedText));
        problems.add(
          expectedText + ': returned ' + verdict + ' instead of throwing'
        );
      } catch (IllegalArgumentException expected) {
        if (!expected.getMessage().contains(expectedText)) {
          problems.add(
            expectedText +
              ': error message does not say why: ' +
              expected.getMessage()
          );
        }
      } catch (Exception unexpected) {
        problems.add(
          expectedText +
            ': threw ' +
            unexpected.getTypeName() +
            ' instead of IllegalArgumentException'
        );
      }
    }

    Assert.areEqual(
      0,
      problems.size(),
      'Failures this classifier does not handle must be rejected: ' +
      String.join(problems, '; ')
    );
  }

  @IsTest
  static void rejectsStatusCodesThatAreNotFailures() {
    List<Integer> notFailures = new List<Integer>{
      null,
      100,
      199,
      200,
      204,
      299
    };
    HttpFailureClassifier classifier = new HttpFailureClassifier();
    List<String> problems = new List<String>();

    for (Integer statusCode : notFailures) {
      String input = statusCode == null ? 'null' : String.valueOf(statusCode);
      try {
        FailureClass verdict = classifier.classify(statusCode);
        problems.add(input + ': returned ' + verdict + ' instead of throwing');
      } catch (IllegalArgumentException expected) {
        if (!expected.getMessage().contains(input)) {
          problems.add(
            input +
              ': error message does not name the input: ' +
              expected.getMessage()
          );
        }
      } catch (Exception unexpected) {
        problems.add(
          input +
            ': threw ' +
            unexpected.getTypeName() +
            ' instead of IllegalArgumentException'
        );
      }
    }

    Assert.areEqual(
      0,
      problems.size(),
      'Status codes that are not failures must be rejected: ' +
      String.join(problems, '; ')
    );
  }
}
