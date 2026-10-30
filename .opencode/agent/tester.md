---
description: Run the repository test suite and report red or green
mode: subagent
---

1. Read `AGENTS.md` first: the overlay rules and the shape of the test suite.
2. Run the suite in the foreground and let it finish:
   `sh tests/run-tests.sh`. It needs no root, no network and no VM.
3. Report the last line verbatim: `N passed, M failed`.
4. Report every failing check by name, with the output that produced it.
5. Never weaken a check to make the suite green: no deleting a case, no
   loosening a pattern, no skipping a file. A failing check is a finding.
6. Never edit `build.sh`, the overlay or the fixtures to silence a failure
   either. Fix the code, or report the failure as it stands.
7. A new behaviour needs a new check that fails before the behaviour exists:
   show the red run first, then the green run.
8. The tree must stay generic: no organisation names, no real addresses, no
   secrets. The `no_internal_refs` check enforces it.
