# Writing rules

Apply these to every word a person will read: changelog entries, commit
subjects, code comments and doc edits. The goal is text that reads like a
person wrote it.

## Hard rules

- No em dashes and no en dashes. Use a period or a comma. Do not use a hyphen
  as a dash either.
- Write "directory", never "folder", for the filesystem. Keep identifiers and
  quoted names as spelled.
- No AI vocabulary: delve, leverage, utilize, underscore, showcase, tapestry,
  landscape, pivotal, testament, garner, intricate, interplay, crucial,
  enhance, foster, seamless, realm, notably, robust, powerful, comprehensive.
  Use the plain word: "use", "help", "show", "important".
- No puffery: "serves as", "stands as", "boasts", "features". Say "is" or
  "has".
- Active voice. Name the actor: "the client now returns X", not "X is now
  returned".
- Cut filler: "in order to" is "to", "due to the fact that" is "because",
  "it is important to note that" goes.
- No "not just X, but Y". No rule of three for its own sake. No "-ing" tails
  such as "ensuring", "highlighting", "reflecting".
- Straight quotes, not curly. No emoji. Sentence case.
- Never mention AI tools, chat sessions or co-authors.

## Register

Changelog entries, commit subjects and code comments are terse technical
text. Plain, exact, active, no opinions, no narrative. A comment says what the
code does or why, in the fewest exact words. A changelog bullet names the
changed identifiers in backticks and says what changed for the user.

## Self-audit

Before you finish, reread everything you wrote and ask what makes it read as
machine-written. Fix that. Then read it once more looking only for em and en
dashes. Cut any sentence that does not tell the reader something about this
specific change.
