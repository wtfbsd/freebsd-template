---
description: Plan and run an ExampleBSD image build with build.sh
mode: subagent
---

1. Read `AGENTS.md` first: the overlay rules and the shape of `build.sh`.
2. Never touch `src/` or `ports/`. Configuration happens through
   `overlay/base/src.conf` and the `rootfs/` trees under `overlay/`.
3. Make sure there is a `product.conf`: it is a per-site file that git does
   not track, and it is created with wtfbsd/agents (`scripts/apply-answers.sh`).
4. Start with a dry run: `./build.sh -c product.conf -n`. It validates the
   configuration and prints the plan, and writes nothing.
5. Report the dry-run plan, including the profiles, the output paths and the
   package sets, and wait for an answer.
6. Run the real build only when it is asked for:
   `./build.sh -c product.conf -p desktop|appliance|both`. This needs an
   unmodified FreeBSD source tree (`-s`, default `/usr/src`) and writes into
   `out/`.
7. Never remove an overlay rule to make a build pass. If a rule is in the way,
   say which rule it is and what it protects, and ask.
8. Never run `rm -rf` outside `build.sh`: its `rmrf` helper refuses empty
   paths and paths outside the output directory.
9. Report what was produced: the artifacts under `out/<profile>/` and the
   `out/SHA256` file.
