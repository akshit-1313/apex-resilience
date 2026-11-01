/**
 * Table-driven tests for CalloutFailureClassifier, using the messages Salesforce really returns
 * (captured in a scratch org) wherever they could be reproduced.
 *
 * ApexUnitTestClassShouldHaveRunAs is suppressed: runAs verifies behaviour under a user's
 * permissions and sharing, and the classifier reads and writes no data, so nothing about it
 * depends on the running user.
 */
@IsTest
@SuppressWarnings('PMD.ApexUnitTestClassShouldHaveRunAs')
private class CalloutFailureClassifierTest {
  @IsTest
  static void classifiesCalloutMessages() {
    Map<String, FailureClass> expectedVerdicts = new Map<String, FailureClass>{
      // Configuration: real messages
      'Unauthorized endpoint, please check Setup->Security->Remote site settings. endpoint = https://example.com/' => FailureClass.TERMINAL,
      'The callout couldn\'t access the endpoint. You might not have the required permissions, or the named credential "SAP_PI" might not exist.' => FailureClass.TERMINAL,
      // TLS: real messages for a self-signed, an expired and a wrong-host certificate
      '(certificate_unknown) PKIX path building failed: sun.security.provider.certpath.SunCertPathBuilderException: unable to find valid certification path to requested target' => FailureClass.TERMINAL,
      '(certificate_expired) PKIX path validation failed: java.security.cert.CertPathValidatorException: validity check failed' => FailureClass.TERMINAL,
      '(certificate_unknown) No subject alternative DNS name matching wrong.host.badssl.com found.' => FailureClass.TERMINAL,
      'Remote host terminated the handshake' => FailureClass.TERMINAL,
      // Callout after DML: real message
      'You have uncommitted work pending. Please commit or rollback before calling out' => FailureClass.TERMINAL,
      // Matching ignores case
      'UNAUTHORIZED ENDPOINT' => FailureClass.TERMINAL,
      // Timing and network: retried
      'Read timed out' => FailureClass.RETRYABLE,
      'connect timed out' => FailureClass.RETRYABLE,
      'Exceeded maximum time allotted for callout (120000 ms)' => FailureClass.RETRYABLE,
      'Connection reset' => FailureClass.RETRYABLE,
      'Connection refused' => FailureClass.RETRYABLE,
      'Unexpected end of file from server' => FailureClass.RETRYABLE,
      // A host that doesn't resolve: real message, through Salesforce's proxy
      'Unable to tunnel through proxy. Proxy returns "HTTP/1.1 503 Service Unavailable"' => FailureClass.RETRYABLE,
      // Unknown and empty messages fall to the default. An exception built with a null message
      // reports "Script-thrown exception", so that falls to the default too.
      'Something nobody has seen before' => FailureClass.RETRYABLE,
      '' => FailureClass.RETRYABLE,
      null => FailureClass.RETRYABLE
    };
    FailureClassifier classifier = new CalloutFailureClassifier();
    List<String> mismatches = new List<String>();

    for (String message : expectedVerdicts.keySet()) {
      FailureClass expectedVerdict = expectedVerdicts.get(message);
      try {
        FailureClass actualVerdict = classifier.classify(
          IntegrationFailure.fromCalloutException(
            'Test',
            new CalloutException(message)
          )
        );
        if (actualVerdict != expectedVerdict) {
          mismatches.add(
            '"' +
              message +
              '": expected ' +
              expectedVerdict +
              ', got ' +
              actualVerdict
          );
        }
      } catch (Exception unexpected) {
        mismatches.add(
          '"' +
            message +
            '": expected ' +
            expectedVerdict +
            ', threw ' +
            unexpected.getTypeName()
        );
      }
    }

    Assert.areEqual(
      0,
      mismatches.size(),
      'Misclassified callout messages: ' + String.join(mismatches, '; ')
    );
  }

  @IsTest
  static void rejectsFailuresItDoesNotHandle() {
    HttpResponse response = new HttpResponse();
    response.setStatusCode(500);
    List<Database.Error> dmlErrors = (List<Database.Error>) JSON.deserialize(
      '[{"statusCode":"UNABLE_TO_LOCK_ROW","message":"locked","fields":[]}]',
      List<Database.Error>.class
    );
    // Each key is text the error message must contain.
    Map<String, IntegrationFailure> failures = new Map<String, IntegrationFailure>{
      'null' => null,
      'HTTP_RESPONSE' => IntegrationFailure.fromResponse('Test', response),
      'DML_ERRORS' => IntegrationFailure.fromDmlErrors('Test', dmlErrors)
    };
    FailureClassifier classifier = new CalloutFailureClassifier();
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
}
