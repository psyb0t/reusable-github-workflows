
The branch moved while this run was regenerating: commits were pushed to it in
the meantime. The regenerated changes were moved onto the new branch tip, which
is what the checkout holds now. If the move conflicted, the affected files
contain standard Git conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`).
Resolve every one of them, keeping both the new commits' intent and the
regeneration, then make the checks pass on this tip.
