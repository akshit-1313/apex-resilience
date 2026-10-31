/**
 * @description Deliberately breaks a High-severity rule (EmptyCatchBlock), used only to prove that
 * CI's static-analysis gate fails. Never merged.
 */
public inherited sharing class StaticAnalysisGateProbe {
  /**
   * @description Parses text as an Integer and silently ignores bad input.
   * @param text the text to parse
   */
  public void parseQuietly(String text) {
    try {
      Integer.valueOf(text);
    } catch (TypeException e) {
    }
  }
}
