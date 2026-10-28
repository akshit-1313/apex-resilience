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
  @IsTest
  static void classifiesEveryFailureCodeBand() {
    Map<Integer, FailureClass> expectedVerdicts = new Map<Integer, FailureClass>{
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
