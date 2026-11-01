/**
 * Tests for ConfiguredFailureClassifier. Custom Metadata records can't be inserted in a test, so
 * rules are built in memory and passed to the test-visible constructor. Each rule's verdict
 * differs from what the built-in classifier would say, so a rule that wrongly fails to match
 * shows up as a mismatch.
 *
 * ApexUnitTestClassShouldHaveRunAs is suppressed: runAs verifies behaviour under a user's
 * permissions and sharing, and Custom Metadata reads don't depend on either.
 */
@IsTest
@SuppressWarnings('PMD.ApexUnitTestClassShouldHaveRunAs')
private class ConfiguredFailureClassifierTest {
  private static final String SAP = 'SAP_PI_Orders';

  @IsTest
  static void overridesTheBuiltInVerdictForItsIntegration() {
    FailureClassificationRule__mdt materialMissing = rule(
      'SapMaterialMissing',
      'HTTP_RESPONSE',
      'TERMINAL'
    );
    materialMissing.Integration__c = SAP;
    materialMissing.StatusCode__c = 500;
    materialMissing.ErrorMessage__c = 'Material does not exist';
    FailureClassifier classifier = new ConfiguredFailureClassifier(
      new List<FailureClassificationRule__mdt>{ materialMissing }
    );

    Map<String, Expectation> cases = new Map<String, Expectation>{
      'matching text in another case' => new Expectation(
        response(SAP, 500, '<fault>MATERIAL does not EXIST: 4711</fault>'),
        FailureClass.TERMINAL
      ),
      'integration name in another case' => new Expectation(
        response('sap_pi_orders', 500, 'Material does not exist'),
        FailureClass.TERMINAL
      ),
      'other text: built-in verdict' => new Expectation(
        response(SAP, 500, 'Internal error'),
        FailureClass.RETRYABLE
      ),
      'no body: built-in verdict' => new Expectation(
        response(SAP, 500, null),
        FailureClass.RETRYABLE
      ),
      'other status: built-in verdict' => new Expectation(
        response(SAP, 502, 'Material does not exist'),
        FailureClass.RETRYABLE
      ),
      'other integration: built-in verdict' => new Expectation(
        response('Dynamics_Accounts', 500, 'Material does not exist'),
        FailureClass.RETRYABLE
      ),
      'blank integration: built-in verdict' => new Expectation(
        response(null, 500, 'Material does not exist'),
        FailureClass.RETRYABLE
      )
    };

    List<String> mismatches = mismatches(classifier, cases);

    Assert.areEqual(
      0,
      mismatches.size(),
      'Integration rule applied wrongly: ' + String.join(mismatches, '; ')
    );
  }

  @IsTest
  static void triesIntegrationRulesThenGlobalRulesByPriorityThenName() {
    FailureClassificationRule__mdt globalTimeout = rule(
      'GlobalTimeout',
      'HTTP_RESPONSE',
      'POISON'
    );
    globalTimeout.Priority__c = 1;
    globalTimeout.ErrorMessage__c = 'timeout';
    FailureClassificationRule__mdt sapTimeout = sapRule(
      'SapTimeout',
      'TERMINAL',
      'timeout'
    );
    FailureClassificationRule__mdt lockLater = sapRule(
      'SapLockLater',
      'POISON',
      'locked'
    );
    lockLater.Priority__c = 20;
    FailureClassificationRule__mdt lockFirst = sapRule(
      'SapLockFirst',
      'TERMINAL',
      'locked'
    );
    lockFirst.Priority__c = 10;
    FailureClassificationRule__mdt quotaB = sapRule(
      'B_Quota',
      'TERMINAL',
      'quota'
    );
    FailureClassificationRule__mdt quotaA = sapRule(
      'A_Quota',
      'POISON',
      'quota'
    );
    // Deliberately out of order: the classifier must sort the rules itself.
    FailureClassifier classifier = new ConfiguredFailureClassifier(
      new List<FailureClassificationRule__mdt>{
        globalTimeout,
        sapTimeout,
        lockLater,
        lockFirst,
        quotaB,
        quotaA
      }
    );

    Map<String, Expectation> cases = new Map<String, Expectation>{
      'integration rule beats a global rule with a lower priority' => new Expectation(
        response(SAP, 500, 'gateway timeout'),
        FailureClass.TERMINAL
      ),
      'global rule applies to another integration' => new Expectation(
        response('Dynamics_Accounts', 500, 'gateway timeout'),
        FailureClass.POISON
      ),
      'global rule applies to a blank integration' => new Expectation(
        response(null, 500, 'gateway timeout'),
        FailureClass.POISON
      ),
      'lower priority runs first' => new Expectation(
        response(SAP, 500, 'record locked'),
        FailureClass.TERMINAL
      ),
      'equal priority: developer name decides' => new Expectation(
        response(SAP, 500, 'quota exceeded'),
        FailureClass.POISON
      )
    };

    List<String> mismatches = mismatches(classifier, cases);

    Assert.areEqual(
      0,
      mismatches.size(),
      'Rules tried in the wrong order: ' + String.join(mismatches, '; ')
    );
  }

  @IsTest
  static void skipsInactiveRulesAndUnknownVerdicts() {
    FailureClassificationRule__mdt inactive = sapRule(
      'Inactive',
      'POISON',
      'timeout'
    );
    inactive.Priority__c = 1;
    inactive.Active__c = false;
    FailureClassificationRule__mdt misspelt = sapRule(
      'Misspelt',
      'TERMINL',
      'timeout'
    );
    misspelt.Priority__c = 2;
    FailureClassificationRule__mdt valid = sapRule(
      'Valid',
      'TERMINAL',
      'gateway timeout'
    );
    valid.Priority__c = 3;
    FailureClassifier classifier = new ConfiguredFailureClassifier(
      new List<FailureClassificationRule__mdt>{ inactive, misspelt, valid }
    );

    Map<String, Expectation> cases = new Map<String, Expectation>{
      'skips to the next valid rule' => new Expectation(
        response(SAP, 500, 'gateway timeout'),
        FailureClass.TERMINAL
      ),
      'only skipped rules match: built-in verdict' => new Expectation(
        response(SAP, 500, 'read timeout'),
        FailureClass.RETRYABLE
      )
    };

    List<String> mismatches = mismatches(classifier, cases);

    Assert.areEqual(
      0,
      mismatches.size(),
      'Inactive or invalid rules were used: ' + String.join(mismatches, '; ')
    );
  }

  @IsTest
  static void matchesCalloutAndDmlFailures() {
    FailureClassificationRule__mdt calloutTimeout = rule(
      'SapCalloutTimeout',
      'CALLOUT_EXCEPTION',
      'TERMINAL'
    );
    calloutTimeout.Integration__c = SAP;
    calloutTimeout.ErrorMessage__c = 'Read timed out';
    FailureClassificationRule__mdt duplicate = rule(
      'SapDuplicate',
      'DML_ERRORS',
      'TERMINAL'
    );
    duplicate.Integration__c = SAP;
    duplicate.ErrorMessage__c = 'DUPLICATE_VALUE';
    FailureClassificationRule__mdt plantNotReplicated = rule(
      'PlantNotReplicated',
      'DML_ERRORS',
      'RETRYABLE'
    );
    plantNotReplicated.ErrorMessage__c = 'Plant 1710 is not yet replicated';
    // Same text, wrong kind, first in order: it must not fire for a DML failure.
    FailureClassificationRule__mdt httpPlant = rule(
      'HttpPlant',
      'HTTP_RESPONSE',
      'POISON'
    );
    httpPlant.Priority__c = 1;
    httpPlant.ErrorMessage__c = 'Plant 1710';
    FailureClassifier classifier = new ConfiguredFailureClassifier(
      new List<FailureClassificationRule__mdt>{
        calloutTimeout,
        duplicate,
        plantNotReplicated,
        httpPlant
      }
    );

    Map<String, Expectation> cases = new Map<String, Expectation>{
      'callout message' => new Expectation(
        IntegrationFailure.fromCalloutException(
          SAP,
          new CalloutException('Read timed out')
        ),
        FailureClass.TERMINAL
      ),
      'callout rule for another integration' => new Expectation(
        IntegrationFailure.fromCalloutException(
          'Dynamics_Accounts',
          new CalloutException('Read timed out')
        ),
        FailureClass.RETRYABLE
      ),
      'DML status code' => new Expectation(
        dmlFailure(SAP, 'DUPLICATE_VALUE', 'duplicate value found'),
        FailureClass.TERMINAL
      ),
      'DML message, not an HTTP rule with the same text' => new Expectation(
        dmlFailure(
          'Dynamics_Accounts',
          'FIELD_CUSTOM_VALIDATION_EXCEPTION',
          'Plant 1710 is not yet replicated'
        ),
        FailureClass.RETRYABLE
      )
    };

    List<String> mismatches = mismatches(classifier, cases);

    Assert.areEqual(
      0,
      mismatches.size(),
      'Callout or DML rule applied wrongly: ' + String.join(mismatches, '; ')
    );
  }

  @IsTest
  static void canClassifyA2xxResponseButOtherwiseRejectsIt() {
    FailureClassificationRule__mdt errorIn200 = rule(
      'ErrorIn200',
      'HTTP_RESPONSE',
      'TERMINAL'
    );
    errorIn200.StatusCode__c = 200;
    errorIn200.ErrorMessage__c = '"success":false';
    FailureClassifier classifier = new ConfiguredFailureClassifier(
      new List<FailureClassificationRule__mdt>{ errorIn200 }
    );
    List<String> problems = new List<String>();

    FailureClass verdict = classifier.classify(
      response(SAP, 200, '{"success":false,"error":"Material does not exist"}')
    );
    if (verdict != FailureClass.TERMINAL) {
      problems.add('a matching rule should classify a 200, got ' + verdict);
    }
    try {
      verdict = classifier.classify(response(SAP, 200, '{"success":true}'));
      problems.add(
        'an unmatched 200 returned ' + verdict + ' instead of throwing'
      );
    } catch (IllegalArgumentException expected) {
      if (!expected.getMessage().contains('200')) {
        problems.add(
          'error message does not name the status: ' + expected.getMessage()
        );
      }
    }

    Assert.areEqual(
      0,
      problems.size(),
      '2xx responses handled wrongly: ' + String.join(problems, '; ')
    );
  }

  @IsTest
  static void rejectsNull() {
    FailureClassifier classifier = new ConfiguredFailureClassifier(
      new List<FailureClassificationRule__mdt>()
    );
    IntegrationFailure nothing = null;
    String problem = 'returned a verdict instead of throwing';

    try {
      classifier.classify(nothing);
    } catch (IllegalArgumentException expected) {
      problem = expected.getMessage().contains('null')
        ? null
        : 'error message does not say why: ' + expected.getMessage();
    }

    Assert.isNull(problem, 'A null failure must be rejected: ' + problem);
  }

  @IsTest
  static void loadsDeployedRulesWithOneQuery() {
    Integer queriesBefore = Limits.getQueries();

    FailureClassifier classifier = new ConfiguredFailureClassifier();

    Assert.isTrue(
      Limits.getQueries() - queriesBefore <= 1,
      'Rules must load with at most one SOQL query, used ' +
      (Limits.getQueries() - queriesBefore)
    );
    Assert.isNotNull(
      classifier.classify(response(SAP, 503, 'Service Unavailable')),
      'The default constructor must give a working classifier'
    );
  }

  @IsTest
  static void everyDeployedRuleIsValid() {
    Set<String> kinds = new Set<String>();
    for (
      IntegrationFailure.FailureKind kind : IntegrationFailure.FailureKind.values()
    ) {
      kinds.add(kind.name());
    }
    Set<String> verdicts = new Set<String>();
    for (FailureClass verdict : FailureClass.values()) {
      verdicts.add(verdict.name());
    }
    List<String> problems = new List<String>();

    for (FailureClassificationRule__mdt deployed : [
      SELECT DeveloperName, FailureKind__c, StatusCode__c, Verdict__c
      FROM FailureClassificationRule__mdt
    ]) {
      if (!kinds.contains(deployed.FailureKind__c)) {
        problems.add(
          deployed.DeveloperName + ': unknown kind ' + deployed.FailureKind__c
        );
      }
      if (!verdicts.contains(deployed.Verdict__c)) {
        problems.add(
          deployed.DeveloperName + ': unknown verdict ' + deployed.Verdict__c
        );
      }
      if (
        deployed.StatusCode__c != null &&
        deployed.FailureKind__c != 'HTTP_RESPONSE'
      ) {
        problems.add(
          deployed.DeveloperName + ': status code on a non-HTTP rule'
        );
      }
    }

    Assert.areEqual(
      0,
      problems.size(),
      'Invalid FailureClassificationRule__mdt records: ' +
      String.join(problems, '; ')
    );
  }

  // An active, global rule with priority 100, for each test to adjust.
  private static FailureClassificationRule__mdt rule(
    String developerName,
    String kind,
    String verdict
  ) {
    return new FailureClassificationRule__mdt(
      DeveloperName = developerName,
      MasterLabel = developerName,
      FailureKind__c = kind,
      Verdict__c = verdict,
      Priority__c = 100,
      Active__c = true
    );
  }

  private static FailureClassificationRule__mdt sapRule(
    String developerName,
    String verdict,
    String errorMessage
  ) {
    FailureClassificationRule__mdt sapRule = rule(
      developerName,
      'HTTP_RESPONSE',
      verdict
    );
    sapRule.Integration__c = SAP;
    sapRule.ErrorMessage__c = errorMessage;
    return sapRule;
  }

  private static IntegrationFailure response(
    String integration,
    Integer statusCode,
    String body
  ) {
    HttpResponse response = new HttpResponse();
    response.setStatusCode(statusCode);
    if (body != null) {
      response.setBody(body);
    }
    return IntegrationFailure.fromResponse(integration, response);
  }

  private static IntegrationFailure dmlFailure(
    String integration,
    String statusCode,
    String message
  ) {
    String errorsJson = JSON.serialize(
      new List<Map<String, Object>>{
        new Map<String, Object>{
          'statusCode' => statusCode,
          'message' => message,
          'fields' => new List<String>()
        }
      }
    );
    return IntegrationFailure.fromDmlErrors(
      integration,
      (List<Database.Error>) JSON.deserialize(
        errorsJson,
        List<Database.Error>.class
      )
    );
  }

  // Classifies each case and returns a description of every wrong verdict.
  private static List<String> mismatches(
    FailureClassifier classifier,
    Map<String, Expectation> cases
  ) {
    List<String> mismatches = new List<String>();
    for (String label : cases.keySet()) {
      Expectation expected = cases.get(label);
      try {
        FailureClass actual = classifier.classify(expected.failure);
        if (actual != expected.verdict) {
          mismatches.add(
            label + ': expected ' + expected.verdict + ', got ' + actual
          );
        }
      } catch (Exception unexpected) {
        mismatches.add(
          label +
            ': expected ' +
            expected.verdict +
            ', threw ' +
            unexpected.getTypeName() +
            ': ' +
            unexpected.getMessage()
        );
      }
    }
    return mismatches;
  }

  private class Expectation {
    final IntegrationFailure failure;
    final FailureClass verdict;

    Expectation(IntegrationFailure failure, FailureClass verdict) {
      this.failure = failure;
      this.verdict = verdict;
    }
  }
}
