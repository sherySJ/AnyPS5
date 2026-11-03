You are implementing PS5 system-library exports for AnyPS5 (repository in the current directory, on a fresh branch from upstream `main`). Your work becomes a pull request under a human contributor's name, and they answer for every line. Correctness matters more than output.

Task, chosen by the scout:
{{TASK}}

Before you write code, read `AGENTS.md`, `CONTRIBUTING.md`, `docs/dev/CONVENTIONS.md` and `docs/dev/REVERSE_ENGINEERING.md`, then the library in `core/libs/prx/{{LIBRARY}}/` and its debt file in `docs/dev/debt/` if it exists.

Hard rules (CI enforces them):
- No code comments, except `#endif` and namespace ends, unless you also add a debt entry.
- Implement the general behaviour for every input. Validate arguments and return the library's real error codes, as sibling functions do. Never return a made-up success.
- Anything you cannot settle throws or calls `NotImplemented_nid_no_patch(__func__)`, and the gap goes in `docs/dev/debt/{{LIBRARY}}.md` under the right `###` section.
- Each `APS5_VABI` export has exactly one declaration, in a header reachable from the library's `<library>.hpp`.
- Add a focused test in the library's `tests/` directory when the library already has tests and the behaviour can be tested on the host. Do not add tests that only check that a symbol exists. Each test must finish well under 30 s.
- Add no other files: no notes, no markdown reports.
- Do not copy code verbatim from other projects. Use them to learn behaviour, and name them in `sources`.

Build and test as you go:
  cmake --build build --target {{LIBRARY}} --parallel {{JOBS}}
  ctest --test-dir build -R <pattern> --output-on-failure
The build directory is already configured; do not delete it. Do not run `git push` or `gh`; the orchestrator handles those.

When finished, do not commit. Write these files:
- `{{OUT}}/commit.txt`: one Conventional Commits subject (`feat(<library short name>): implement sceXxx`) and, after a blank line, a short body.
- `{{OUT}}/pr.md`: the PR body, made by copying `.github/pull_request_template.md`, keeping every line, ticking every box and filling `What`, `Tested` (OS: Linux, the exact ctest tests run), `Depends on: none`, `Fixes: Fixes #N` or `none`, `Unblocks: none` unless the issue names a title ID and discussion, `GPUs tested: n/a`, `AI-assisted: yes`. Add a short `Sources` line under What.

If, after reading, you find the behaviour cannot be implemented correctly, write only `{{OUT}}/skip.txt` with one line explaining why; the orchestrator discards the branch.
