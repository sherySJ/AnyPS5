You are continuing an AnyPS5 change in the current repository. The work so far is the last commit on the current branch (`git show HEAD`). Edit files in place and don't commit; the orchestrator folds your edits into that commit. Read `AGENTS.md` first.

Original task:
{{TASK}}

The change failed a check. Fix the cause; don't weaken a test, skip it or special-case the input to make it pass. Here is the failure:

{{FAILURE}}

Rules are unchanged: no code comments, no made-up success, unknown paths throw, add no stray files, and no `git push`, `gh` or commits. Update `{{OUT}}/commit.txt` and `{{OUT}}/pr.md` if what you changed affects them. If the change can't be fixed correctly, write `{{OUT}}/skip.txt` with the reason; the orchestrator discards the branch.
