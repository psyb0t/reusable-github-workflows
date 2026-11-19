- history/attempt-N-notes.md, history/attempt-N.patch, history/check-N.log:
  for each earlier attempt, its own summary, exactly what it changed, and the
  checks output after it. Those attempts did not get the checks passing. Read
  all of them, work out why, and do not repeat what already failed. Keep their
  changes when they are right; revert them when they are wrong.
- A guard rejection is a failed attempt even if the tests would pass. Read
  check-output.log for the exact rejection, remove the prohibited change, and
  fix the original problem. Do not repeat the suppression or try another way
  to hide the same finding. All attempts are checked against the original
  repair baseline, so leaving an earlier prohibited edit in place still fails.
