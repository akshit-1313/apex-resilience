/**
 * @description Deliberately untested class, used only to prove that CI's coverage gate fails
 * when org-wide coverage drops below 90%. Never merged.
 */
public inherited sharing class CoverageGateProbe {
  /**
   * @description Describes what to do next for a verdict.
   * @param verdict the verdict to describe
   * @return a short instruction
   */
  public String describe(FailureClass verdict) {
    if (verdict == FailureClass.RETRYABLE) {
      return 'Retry later.';
    }
    if (verdict == FailureClass.TERMINAL) {
      return 'A person must fix the cause.';
    }
    return 'Quarantine the message.';
  }
}
