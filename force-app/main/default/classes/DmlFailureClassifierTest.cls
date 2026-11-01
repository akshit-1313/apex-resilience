/**
 * Table-driven tests for DmlFailureClassifier. Each row is one record's errors, written as
 * 'STATUS_CODE: message' and separated by ' | ' when a record has several.
 *
 * Database.Error has no public constructor, so the errors are built with JSON.deserialize. That
 * accepts any status code string without complaint, and a misspelt code would silently fall to the
 * TERMINAL default, so every fixture's code is checked against StatusCode.values() first.
 *
 * ApexUnitTestClassShouldHaveRunAs is suppressed: runAs verifies behaviour under a user's
 * permissions and sharing, and the classifier reads and writes no data, so nothing about it
 * depends on the running user.
 */
@IsTest
@SuppressWarnings('PMD.ApexUnitTestClassShouldHaveRunAs')
private class DmlFailureClassifierTest {
  private static final String LOCK_IN_TRIGGER = 'CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY: OrderTrigger: execution of AfterUpdate caused by: System.DmlException: Update failed. First exception on row 0; first error: UNABLE_TO_LOCK_ROW, unable to obtain exclusive access to this record: []';

  @IsTest
  static void classifiesEachStatusCode() {
    Map<String, FailureClass> expectedVerdicts = new Map<String, FailureClass>{
      // Row locks, including one hit inside a trigger
      'UNABLE_TO_LOCK_ROW: unable to obtain exclusive access to this record' => FailureClass.RETRYABLE,
      LOCK_IN_TRIGGER => FailureClass.RETRYABLE,
      // Fixed outside the message, then replayed
      'INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST: bad value for restricted picklist field: 1710' => FailureClass.TERMINAL,
      'FIELD_CUSTOM_VALIDATION_EXCEPTION: Plant is required' => FailureClass.TERMINAL,
      'INVALID_CROSS_REFERENCE_KEY: invalid cross reference id' => FailureClass.TERMINAL,
      'ENTITY_IS_DELETED: entity is deleted' => FailureClass.TERMINAL,
      'INSUFFICIENT_ACCESS_OR_READONLY: insufficient access rights on object id' => FailureClass.TERMINAL,
      'INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY: insufficient access rights on cross-reference id' => FailureClass.TERMINAL,
      'ENTITY_IS_LOCKED: the entity is locked for editing' => FailureClass.TERMINAL,
      'DUPLICATES_DETECTED: Use one of these records?' => FailureClass.TERMINAL,
      'CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY: OrderTrigger: execution of BeforeInsert caused by: System.NullPointerException' => FailureClass.TERMINAL,
      // The record's own data is wrong
      'REQUIRED_FIELD_MISSING: Required fields are missing: [Name]' => FailureClass.POISON,
      'STRING_TOO_LONG: Material: data value too large' => FailureClass.POISON,
      'INVALID_TYPE_ON_FIELD_IN_RECORD: Quantity: value not of required type' => FailureClass.POISON,
      'INVALID_EMAIL_ADDRESS: Email: invalid email address' => FailureClass.POISON,
      'NUMBER_OUTSIDE_VALID_RANGE: Amount: number outside valid range' => FailureClass.POISON,
      'MALFORMED_ID: Account ID: id value of incorrect type' => FailureClass.POISON,
      'DUPLICATE_VALUE: duplicate value found: External_Id__c duplicates value on record with id' => FailureClass.POISON,
      // A code the table doesn't list falls to the default, with or without a message
      'FIELD_INTEGRITY_EXCEPTION: field integrity exception' => FailureClass.TERMINAL,
      'FIELD_INTEGRITY_EXCEPTION' => FailureClass.TERMINAL
    };

    List<String> mismatches = mismatches(expectedVerdicts);

    Assert.areEqual(
      0,
      mismatches.size(),
      'Misclassified DML errors: ' + String.join(mismatches, '; ')
    );
  }

  @IsTest
  static void mostSevereErrorWins() {
    Map<String, FailureClass> expectedVerdicts = new Map<String, FailureClass>{
      'UNABLE_TO_LOCK_ROW: locked | FIELD_CUSTOM_VALIDATION_EXCEPTION: Plant is required' => FailureClass.TERMINAL,
      'UNABLE_TO_LOCK_ROW: locked | REQUIRED_FIELD_MISSING: Required fields are missing: [Name]' => FailureClass.POISON,
      'REQUIRED_FIELD_MISSING: Required fields are missing: [Name] | UNABLE_TO_LOCK_ROW: locked' => FailureClass.POISON,
      'FIELD_CUSTOM_VALIDATION_EXCEPTION: Plant is required | DUPLICATE_VALUE: duplicate value found' => FailureClass.POISON,
      'UNABLE_TO_LOCK_ROW: locked | ' +
      LOCK_IN_TRIGGER => FailureClass.RETRYABLE
    };

    List<String> mismatches = mismatches(expectedVerdicts);

    Assert.areEqual(
      0,
      mismatches.size(),
      'Records with several errors were misclassified: ' +
      String.join(mismatches, '; ')
    );
  }

  @IsTest
  static void rejectsFailuresItDoesNotHandle() {
    HttpResponse response = new HttpResponse();
    response.setStatusCode(500);
    // Each key is text the error message must contain.
    Map<String, IntegrationFailure> failures = new Map<String, IntegrationFailure>{
      'null' => null,
      'HTTP_RESPONSE' => IntegrationFailure.fromResponse('Test', response),
      'CALLOUT_EXCEPTION' => IntegrationFailure.fromCalloutException(
        'Test',
        new CalloutException('Read timed out')
      )
    };
    FailureClassifier classifier = new DmlFailureClassifier();
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

  // Classifies every row and returns a description of each wrong one.
  private static List<String> mismatches(
    Map<String, FailureClass> expectedVerdicts
  ) {
    FailureClassifier classifier = new DmlFailureClassifier();
    List<String> mismatches = new List<String>();
    for (String row : expectedVerdicts.keySet()) {
      FailureClass expectedVerdict = expectedVerdicts.get(row);
      try {
        FailureClass actualVerdict = classifier.classify(
          IntegrationFailure.fromDmlErrors('Test', dmlErrors(row))
        );
        if (actualVerdict != expectedVerdict) {
          mismatches.add(
            row + ': expected ' + expectedVerdict + ', got ' + actualVerdict
          );
        }
      } catch (Exception unexpected) {
        mismatches.add(
          row +
            ': expected ' +
            expectedVerdict +
            ', threw ' +
            unexpected.getTypeName() +
            ': ' +
            unexpected.getMessage()
        );
      }
    }
    return mismatches;
  }

  // Builds one record's errors from a row. A part with no ': ' has no message.
  private static List<Database.Error> dmlErrors(String row) {
    Set<String> realCodes = new Set<String>();
    for (StatusCode code : StatusCode.values()) {
      realCodes.add(code.name());
    }
    List<Map<String, Object>> errors = new List<Map<String, Object>>();
    for (String part : row.split(' \\| ')) {
      String code = part.substringBefore(': ');
      if (!realCodes.contains(code)) {
        throw new IllegalArgumentException(
          'Fixture uses ' + code + ', which is not a real StatusCode'
        );
      }
      Map<String, Object> error = new Map<String, Object>{
        'statusCode' => code,
        'fields' => new List<String>()
      };
      if (part.contains(': ')) {
        error.put('message', part.substringAfter(': '));
      }
      errors.add(error);
    }
    return (List<Database.Error>) JSON.deserialize(
      JSON.serialize(errors),
      List<Database.Error>.class
    );
  }
}
