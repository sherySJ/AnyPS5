You are updating an open AnyPS5 pull request by this contributor (branch checked out in the current directory). Read `AGENTS.md` and `CONTRIBUTING.md` first.

What needs work, gathered from GitHub:
{{FEEDBACK}}

Do this:
1. If the branch conflicts with `main` or is behind it, rebase it onto `upstream/main` and resolve the conflicts correctly (use `tools/debt_split.py resolve` or `tools/agc_test_split.py resolve` during the rebase where CONTRIBUTING says to).
2. Address every reviewer request. If a request is wrong or impossible, don't change the code for it; explain why in `{{OUT}}/reply.md`, and the human will post it.
3. Fix failing checks shown above.
4. Build and test: `cmake --build build --target <library> --parallel {{JOBS}}` and the relevant `ctest --test-dir build -R <pattern>`.
5. Commit the fixes as new commits with Conventional Commits subjects (`git commit`). Do not push and do not use `gh`.

Then write `{{OUT}}/reply.md`: a short reply for the human to post to the reviewers, saying what changed per request. If nothing needed doing, write `{{OUT}}/nothing.txt` instead.
