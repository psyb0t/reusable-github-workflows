An automated job ran this repository's code generator and it produced changes.
Describe those changes for the changelog and the commit subject, and classify
them so the workflow can pick the next version.

Context files under /context:
- diff-stat.txt: files changed by the regeneration.
- diff.patch: the full diff against the last commit (may be truncated; a note at the end says so).
- changelog-head.md: the top of the repository's existing changelog. Match its style.
- last-tag.txt: the previous release tag.
- writing-rules.md: rules for every word you write. Follow them, then run its self-audit.
- repo-rules/: the repository's AGENTS.md and .agents/rules. Follow their release and changelog rules.
{{OPTIONAL_CONTEXT}}

{{VERSION_NOTE}}

Write exactly these five files in the output directory and nothing else:

1. changelog.md: the body of ONE changelog entry. No heading, no version, no date.
   - Bullet lines only, each starting with "- ". Plain English, one change per bullet.
   - Describe user-visible changes to the public API or behavior. Name the added,
     removed and changed functions, methods, types and fields in backticks, taken
     from the diff (and apidiff.txt when present).
   - No em dashes and no en dashes. Use commas, colons or separate sentences.
   - No marketing words (for example: seamless, powerful, robust, enhanced, comprehensive).
   - No URLs to chat sessions, no "Co-authored-by" lines, no mention of AI tools.
   - Under 3000 bytes. If the change is large, summarize by area.
   - When fixes.patch exists, add bullets for the fixes that matter to users
     (for example a changed spec patch or a dependency bump).

2. subject.txt: ONE line, the commit subject text WITHOUT any version prefix
   {{SUBJECT_PREFIX_NOTE}}. Lower-case start, concrete, at most
   {{MAX_SUBJECT_TEXT_CHARS}} characters, no trailing period, no dashes of the kinds above.

3. change-kind.txt: exactly one word, one of:
   - fix: regenerated output changed without adding or removing public API
     (documentation, defaults, internal fixes).
   - feature: new public API was added and every existing caller still compiles
     and behaves the same.
   - breaking: public API was removed or renamed, or a signature, type or
     behavior changed so existing callers must change their code.
   When in doubt between two kinds, pick the stronger one.

4. bump-reason.txt: one or two plain sentences explaining the change-kind choice,
   citing the specific identifiers that drove it.

5. verdict.txt: review the whole change, fixes.patch included, before it ships.
   Write exactly "ok" when it is safe to release. Write "block: " and one line
   of reason when it must not ship, for example when a fix deletes or weakens a
   test, hides an error, hard-codes around a failure, removes public API the
   upstream spec still has, edits files unrelated to the regeneration, or adds
   any mention of AI tools or authorship.
