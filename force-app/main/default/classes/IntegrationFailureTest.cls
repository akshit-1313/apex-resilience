/**
 * Tests for IntegrationFailure: each factory captures the right values and only those, the DML
 * errors can't be changed from outside, and inputs with nothing to classify are rejected.
 *
 * ApexUnitTestClassShouldHaveRunAs is suppressed: runAs verifies behaviour under a user's
 * permissions and sharing, and this class reads and writes no data, so nothing about it depends
 * on the running user.
 */
@IsTest
@SuppressWarnings('PMD.ApexUnitTestClassShouldHaveRunAs')
private class IntegrationFailureTest {
  // Database.Error has no public constructor; JSON.deserialize is the only way to build one.
  private static List<Database.Error> dmlErrors(String errorsJson) {
    return (List<Database.Error>) JSON.deserialize(
      errorsJson,
      List<Database.Error>.class
    );
  }

  @IsTest
  static void fromResponseCapturesStatusAndBody() {
    HttpResponse response = new HttpResponse();
    response.setStatusCode(503);
    response.setBody('Service Unavailable');

    IntegrationFailure failure = IntegrationFailure.fromResponse(
      'SAP_PI_Orders',
      response
    );
    // Changing the response afterwards must not change the captured failure.
    response.setStatusCode(200);
    response.setBody('changed');

    List<String> problems = new List<String>();
    if (failure.integration != 'SAP_PI_Orders') {
      problems.add('integration: ' + failure.integration);
    }
    if (failure.kind != IntegrationFailure.FailureKind.HTTP_RESPONSE) {
      problems.add('kind: ' + failure.kind);
    }
    if (failure.statusCode != 503) {
      problems.add('statusCode: ' + failure.statusCode);
    }
    if (failure.responseBody != 'Service Unavailable') {
      problems.add('responseBody: ' + failure.responseBody);
    }
    if (failure.exceptionMessage != null || failure.getDmlErrors() != null) {
      problems.add('fields for other kinds are set');
    }
    Assert.areEqual(
      0,
      problems.size(),
      'fromResponse captured the wrong values: ' + String.join(problems, '; ')
    );
  }

  @IsTest
  static void fromCalloutExceptionCapturesMessage() {
    IntegrationFailure failure = IntegrationFailure.fromCalloutException(
      null,
      new CalloutException('Read timed out')
    );

    List<String> problems = new List<String>();
    if (failure.integration != null) {
      problems.add('integration: ' + failure.integration);
    }
    if (failure.kind != IntegrationFailure.FailureKind.CALLOUT_EXCEPTION) {
      problems.add('kind: ' + failure.kind);
    }
    if (failure.exceptionMessage != 'Read timed out') {
      problems.add('exceptionMessage: ' + failure.exceptionMessage);
    }
    if (
      failure.statusCode != null ||
      failure.responseBody != null ||
      failure.getDmlErrors() != null
    ) {
      problems.add('fields for other kinds are set');
    }
    Assert.areEqual(
      0,
      problems.size(),
      'fromCalloutException captured the wrong values: ' +
      String.join(problems, '; ')
    );
  }

  @IsTest
  static void fromDmlErrorsCapturesACopyOfTheErrors() {
    List<Database.Error> errors = dmlErrors(
      '[{"statusCode":"UNABLE_TO_LOCK_ROW","message":"unable to obtain exclusive access to this record","fields":[]},' +
      '{"statusCode":"FIELD_CUSTOM_VALIDATION_EXCEPTION","message":"Plant is required","fields":["Plant__c"]}]'
    );

    IntegrationFailure failure = IntegrationFailure.fromDmlErrors(
      'SAP_PI_Orders',
      errors
    );
    // Neither the caller's list nor a returned copy may change the captured errors.
    errors.clear();
    failure.getDmlErrors().clear();

    List<String> problems = new List<String>();
    if (failure.kind != IntegrationFailure.FailureKind.DML_ERRORS) {
      problems.add('kind: ' + failure.kind);
    }
    List<Database.Error> captured = failure.getDmlErrors();
    if (captured.size() != 2) {
      problems.add('expected 2 errors, got ' + captured.size());
    } else if (
      captured[0].getStatusCode() != StatusCode.UNABLE_TO_LOCK_ROW ||
      captured[1].getStatusCode() !=
      StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION
    ) {
      problems.add(
        'wrong errors: ' +
          captured[0].getStatusCode() +
          ', ' +
          captured[1].getStatusCode()
      );
    }
    if (
      failure.statusCode != null ||
      failure.responseBody != null ||
      failure.exceptionMessage != null
    ) {
      problems.add('fields for other kinds are set');
    }
    Assert.areEqual(
      0,
      problems.size(),
      'fromDmlErrors captured the wrong values: ' + String.join(problems, '; ')
    );
  }

  @IsTest
  static void rejectsInputsWithNothingToClassify() {
    List<String> problems = new List<String>();

    try {
      IntegrationFailure.fromResponse('Test', null);
      problems.add('fromResponse(null) did not throw');
    } catch (IllegalArgumentException expected) {
      checkMessage(expected, 'null HttpResponse', problems);
    }
    try {
      IntegrationFailure.fromCalloutException('Test', null);
      problems.add('fromCalloutException(null) did not throw');
    } catch (IllegalArgumentException expected) {
      checkMessage(expected, 'null CalloutException', problems);
    }
    try {
      IntegrationFailure.fromDmlErrors('Test', null);
      problems.add('fromDmlErrors(null) did not throw');
    } catch (IllegalArgumentException expected) {
      checkMessage(expected, 'null or empty', problems);
    }
    try {
      IntegrationFailure.fromDmlErrors('Test', new List<Database.Error>());
      problems.add('fromDmlErrors(empty) did not throw');
    } catch (IllegalArgumentException expected) {
      checkMessage(expected, 'null or empty', problems);
    }

    Assert.areEqual(
      0,
      problems.size(),
      'Inputs with nothing to classify must be rejected: ' +
      String.join(problems, '; ')
    );
  }

  private static void checkMessage(
    Exception thrown,
    String expectedText,
    List<String> problems
  ) {
    if (!thrown.getMessage().contains(expectedText)) {
      problems.add(
        'message should mention "' + expectedText + '": ' + thrown.getMessage()
      );
    }
  }
}
