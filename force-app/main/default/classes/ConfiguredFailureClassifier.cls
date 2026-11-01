/**
 * @description The entry point for classification: per-integration overrides from
 * FailureClassificationRule__mdt first, then the built-in classifier for the failure's kind.
 *
 * Which rule wins: only active rules count. Rules naming the failure's integration (matched
 * without regard to case) are checked before global rules, which have a blank Integration__c and
 * apply to every failure, so a specific rule always beats a general one. Within each group,
 * Priority__c then DeveloperName. The first matching rule wins.
 *
 * A rule matches when its FailureKind__c is the failure's kind, its StatusCode__c is blank or the
 * response's status, and its ErrorMessage__c is blank or contained in the failure's text, ignoring
 * case. The text is the response body, the exception message, or each DML error written as
 * "STATUS_CODE: message", one per line, so a DML rule can match a status code too.
 *
 * Rules load with one SOQL query, not getAll(): getAll() cuts Long Text Area values to 255
 * characters, and a cut ErrorMessage__c would match more failures than its author meant. Because
 * the query selects a Long Text Area field, it counts against the 100-query limit: once, in the
 * constructor.
 */
public inherited sharing class ConfiguredFailureClassifier implements FailureClassifier {
  private static final Map<IntegrationFailure.FailureKind, FailureClassifier> BUILT_IN = new Map<IntegrationFailure.FailureKind, FailureClassifier>{
    IntegrationFailure.FailureKind.HTTP_RESPONSE => new HttpFailureClassifier(),
    IntegrationFailure.FailureKind.CALLOUT_EXCEPTION => new CalloutFailureClassifier(),
    IntegrationFailure.FailureKind.DML_ERRORS => new DmlFailureClassifier()
  };

  private static final Map<String, FailureClass> VERDICTS = new Map<String, FailureClass>();
  static {
    for (FailureClass verdict : FailureClass.values()) {
      VERDICTS.put(verdict.name(), verdict);
    }
  }

  // Active rules in the order they are tried. Integration keys are lower case.
  private final Map<String, List<FailureClassificationRule__mdt>> rulesByIntegration = new Map<String, List<FailureClassificationRule__mdt>>();
  private final List<FailureClassificationRule__mdt> globalRules = new List<FailureClassificationRule__mdt>();

  /**
   * @description Loads every FailureClassificationRule__mdt record with one SOQL query, in system
   * mode: rules are configuration, so every user who classifies a failure gets the same rules,
   * whether or not their profile can see the type.
   */
  public ConfiguredFailureClassifier() {
    this(
      [
        SELECT
          DeveloperName,
          Integration__c,
          FailureKind__c,
          StatusCode__c,
          ErrorMessage__c,
          Verdict__c,
          Priority__c,
          Active__c
        FROM FailureClassificationRule__mdt
        WITH SYSTEM_MODE
      ]
    );
  }

  // Tests pass rules built in memory: Custom Metadata records can't be inserted in a test.
  @TestVisible
  private ConfiguredFailureClassifier(
    List<FailureClassificationRule__mdt> rules
  ) {
    List<FailureClassificationRule__mdt> activeRules = new List<FailureClassificationRule__mdt>();
    for (FailureClassificationRule__mdt rule : rules) {
      if (rule.Active__c == true) {
        activeRules.add(rule);
      }
    }
    activeRules.sort(new RuleOrder());
    for (FailureClassificationRule__mdt rule : activeRules) {
      if (String.isBlank(rule.Integration__c)) {
        globalRules.add(rule);
      } else {
        String key = rule.Integration__c.toLowerCase();
        if (!rulesByIntegration.containsKey(key)) {
          rulesByIntegration.put(
            key,
            new List<FailureClassificationRule__mdt>()
          );
        }
        rulesByIntegration.get(key).add(rule);
      }
    }
  }

  /**
   * @description Returns the verdict of the first matching rule, or the built-in classifier's
   * verdict if no rule matches.
   * @param failure the failure to classify, of any kind
   * @return RETRYABLE, TERMINAL or POISON
   * @throws IllegalArgumentException if failure is null, or if no rule matches and the built-in
   * classifier rejects it (for example a 2xx response)
   */
  public FailureClass classify(IntegrationFailure failure) {
    if (failure == null) {
      throw new IllegalArgumentException(
        'Cannot classify a null IntegrationFailure.'
      );
    }
    String text = searchText(failure);
    FailureClass verdict = firstMatch(
      rulesFor(failure.integration),
      failure,
      text
    );
    if (verdict == null) {
      verdict = firstMatch(globalRules, failure, text);
    }
    return verdict == null
      ? BUILT_IN.get(failure.kind).classify(failure)
      : verdict;
  }

  private List<FailureClassificationRule__mdt> rulesFor(String integration) {
    String key = String.isBlank(integration) ? '' : integration.toLowerCase();
    return rulesByIntegration.containsKey(key)
      ? rulesByIntegration.get(key)
      : new List<FailureClassificationRule__mdt>();
  }

  // A rule whose verdict isn't a FailureClass name is skipped. The VerdictIsKnown validation rule
  // stops one being saved, and a test checks every deployed rule.
  private static FailureClass firstMatch(
    List<FailureClassificationRule__mdt> rules,
    IntegrationFailure failure,
    String text
  ) {
    for (FailureClassificationRule__mdt rule : rules) {
      FailureClass verdict = VERDICTS.get(rule.Verdict__c);
      if (verdict != null && matches(rule, failure, text)) {
        return verdict;
      }
    }
    return null;
  }

  private static Boolean matches(
    FailureClassificationRule__mdt rule,
    IntegrationFailure failure,
    String text
  ) {
    Boolean kindMatches = failure.kind.name().equals(rule.FailureKind__c);
    Boolean statusMatches =
      rule.StatusCode__c == null ||
      rule.StatusCode__c == failure.statusCode;
    Boolean textMatches =
      String.isBlank(rule.ErrorMessage__c) ||
      text.containsIgnoreCase(rule.ErrorMessage__c);
    return kindMatches && statusMatches && textMatches;
  }

  private static String searchText(IntegrationFailure failure) {
    switch on failure.kind {
      when HTTP_RESPONSE {
        return failure.responseBody == null ? '' : failure.responseBody;
      }
      when CALLOUT_EXCEPTION {
        return failure.exceptionMessage;
      }
      when else {
        List<String> lines = new List<String>();
        for (Database.Error error : failure.getDmlErrors()) {
          lines.add(error.getStatusCode() + ': ' + error.getMessage());
        }
        return String.join(lines, '\n');
      }
    }
  }

  // Priority__c ascending, then DeveloperName, so the order never depends on how rules were loaded.
  private class RuleOrder implements Comparator<FailureClassificationRule__mdt> {
    public Integer compare(
      FailureClassificationRule__mdt first,
      FailureClassificationRule__mdt second
    ) {
      if (first.Priority__c != second.Priority__c) {
        return first.Priority__c < second.Priority__c ? -1 : 1;
      }
      return first.DeveloperName.compareTo(second.DeveloperName);
    }
  }
}
