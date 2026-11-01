/**
 * @description Decides the verdict for one failed integration attempt. Every classifier in this
 * library implements it, so callers and per-integration overrides treat them all the same way.
 */
public interface FailureClassifier {
  /**
   * @description Returns the verdict for a failed integration attempt.
   * @param failure the failure to classify
   * @return RETRYABLE, TERMINAL or POISON
   * @throws IllegalArgumentException if failure is null or is a kind this classifier does not
   * handle: both are caller bugs, not failures to classify.
   */
  FailureClass classify(IntegrationFailure failure);
}
