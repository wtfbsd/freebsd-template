# AGENTS.md — how to work in this repository

## What this is

A template for shipping a per-product distribution that is an **overlay on
unmodified upstream FreeBSD**. The product is a placeholder: **ExampleBSD**
(slug `examplebsd`). Images are built with stock release(7)-style tooling:
`buildworld`/`buildkernel`/`installworld`/`distribution`, `pkg -r` staging,
`makefs`/`mkimg` for raw images and `src/release/<arch>/mkisoimages.sh` for
ISOs. License: BSD-2-Clause (see `LICENSE`).

## Layout

```
.
├── .opencode/agent/         the agent prompts: builder.md, tester.md
├── AGENTS.md              this file
├── Jenkinsfile            the CI pipeline
├── opencode.json          the project agents (no provider, no model)
├── build.sh               the build driver (POSIX sh)
├── ci/
│   ├── vm.sh              the one VM entry point (create/console/addr/destroy)
│   └── providers/bhyve.sh the reference provider (stock bhyve(8))
├── overlay/               THE overlay: nothing here patches src/ or ports/
└── tests/
    ├── run-tests.sh       the test suite (any POSIX host, no root)
    ├── boot-test.sh       boot an image and wait for it to be usable
    ├── stubs/installer/   the stub commands the installer tests run against
    └── fixtures/          the fake provider and the canned serial logs
```

## The overlay rules

- **Never patch src or ports.** Configuration happens only through
  `overlay/base/src.conf` (used as `SRCCONF`) and the files copied over the
  staged root under `overlay/**/rootfs/`.
- Overlay `rootfs` files are copied base-first, then the profile on top.
- `@DISTRO_NAME@`, `@MOTD@`, `@SLUG@` and `@BRAND_URL@` are substituted by
  `build.sh` from `product.conf`.
- Files staged with a literal `@SLUG@` in their **name** are renamed by
  `build.sh` to the slug.
- `rc.conf.d` fragments are named **after their service**: rc(8) only reads
  `/etc/rc.conf.d/<service-name>`.
- `build.sh` locks root in the staged image and leaves a `/firstboot` sentinel
  so the first-boot scripts run once.
- Any `rm -rf` in `build.sh` is guarded: only paths validated non-empty and
  under the output directory are removed.
- The mt76 wireless driver is never enabled, loaded or configured.

## How to build

`product.conf` is flat `KEY=value` output; it is parsed, never sourced. It
is a per-site file that git does not track: create it with wtfbsd/agents
(`scripts/apply-answers.sh`) first.

```sh
./build.sh -c product.conf -n                 # dry run: print the plan
./build.sh -c product.conf                    # PROFILE from product.conf
./build.sh -c product.conf -p both            # appliance + desktop
./build.sh -c product.conf -u ci -k ./ci.pub  # bake a CI first-boot user
```

A real build needs an unmodified FreeBSD source tree (`-s`, default `/usr/src`)
and a FreeBSD host. Artifacts land as `out/<profile>/<slug>-<profile>-<arch>.{img,iso}`
plus `out/SHA256`.

## How to test

```sh
sh tests/run-tests.sh
```

No root, no network, no VM: the suite is dry-run checks plus the CI plumbing.
The last line is `N passed, M failed`. A new behaviour needs a check that
fails before the behaviour exists: show the red run, then the green run.

A check asserts a behaviour, never the words of the fix: a test that greps
the source for `addm` or for a parameter type passes when those words sit in
a comment. Strip the comments first, or run the code — the provider is
exercised with a fake `ifconfig` that logs its arguments, the pipeline is
exercised by taking its shell blocks out and running them.

The Jenkins pipeline runs the suite itself, in a `Test` stage before the
build: a tree that fails its own checks must not produce an image.

The boot test is separate, because it needs a hypervisor:

```sh
sh tests/boot-test.sh out/appliance/examplebsd-appliance-amd64.img appliance
```

It goes through `ci/vm.sh` only, waits for `login:` on the serial console
(and, for the appliance profile, for sshd on port 22), and always destroys the
VM. The name of the VM can be given as a third argument (or in
`WTFBSD_VM_NAME`), so that a caller can destroy it by name even when the
test dies hard.

## The VM layer

`ci/vm.sh` is the only way to touch a VM:

| subcommand | arguments | stdout |
|---|---|---|
| `create` | `NAME IMAGE` | nothing (the progress goes to stderr) |
| `console` | `NAME` | the path of the serial console log |
| `addr` | `NAME` | the address of the VM |
| `destroy` | `NAME` | nothing (the progress goes to stderr) |

stdout carries the machine-readable answer and nothing else: a provider
writes its progress to stderr. The boot test reads the path of the console
log and the address of the VM from stdout.

The provider comes from `$WTFBSD_VM_PROVIDER` (a file in `ci/providers/`) or
from `$WTFBSD_VM_PROVIDER_PATH` (a provider script outside this repository).
An unknown or missing provider fails closed: nothing is started.

The reference provider makes the tap of the guest NIC itself: opening a tap
device creates it outside any bridge and down. Only the **bridge** has to
exist on the host. Every step of the tap (create, up, addm) is fatal when it
fails, and the destroy takes the tap away only when the provider made it.

## The generic-template rule

This repository is public and generic. Anyone must be able to fork it and run
it on their own Jenkins.

- No organisation names, no real host names, no real addresses, no internal
  service names, no ticket numbers, no user names. Placeholders only:
  ExampleBSD, `examplebsd`, `example.org`.
- No secrets and no credential values. Jenkins credentials are referenced by
  id only (the convention is `wtfbsd-ai-token`).
- The pipeline, the tests and the VM layer must not name a site, a host or a
  provider that only exists in one lab.
- `tests/run-tests.sh` enforces this with the `no_internal_refs` check. Its
  public half looks for generic shapes only — addresses, e-mail addresses,
  internal top level domains, key headers, token prefixes, credential
  keywords — and it must never name what it looks for: a list of the names
  that must not be published is itself a publication of them, and a name
  split into fragments is the same publication with extra steps.
- The check reads binary files as well, and the product code is never
  loosened to satisfy it: when a shape of the product trips the check, the
  check gets the documented exception (the OpenSSH key types are shaped like
  an e-mail address, so a key type on that domain is exempt — not every
  address on it), not the product code.
- The names themselves live outside the repository, in the file named by
  `$WTFBSD_DENYLIST` (one case-insensitive extended regular expression per
  line). The repository ships no such file and no list of names.
- `ROUND-REPORT*.md` is ignored by git: a round report quotes session
  material, so it is never tracked.
