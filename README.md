# freebsd-template — FreeBSD distribution template

A template for shipping a per-product distribution that is an **overlay on
unmodified upstream FreeBSD**. Product name placeholders: **ExampleBSD**
(slug `examplebsd`). The template never patches `src/` or `ports/`; images
are built with stock release(7)-style tooling:
`buildworld`/`buildkernel`/`installworld`/`distribution`, `pkg -r` staging,
`makefs`/`mkimg` for raw images and the stock
`src/release/<arch>/mkisoimages.sh` for ISOs. License: BSD-2-Clause (see
`LICENSE`).

## Layout

```
.
├── .opencode/agent/         the agent prompts: builder.md, tester.md
├── AGENTS.md                how to work in this repository
├── Jenkinsfile              the CI pipeline (generic)
├── opencode.json            the project agents (no provider, no model)
├── build.sh                 the build driver (POSIX sh)
├── ci/
│   ├── vm.sh                the one VM entry point (create/console/addr/destroy)
│   └── providers/bhyve.sh   the reference provider (stock bhyve(8))
├── tests/
│   ├── run-tests.sh         the test suite (any POSIX host, no root)
│   ├── boot-test.sh         boot an image and wait for it to be usable
│   └── fixtures/            the fake provider and the canned serial logs
└── overlay/                 THE overlay: nothing here patches src/ or ports/
    ├── base/
    │   ├── src.conf         SRCCONF (WITHOUT_ knobs only, conservative)
    │   ├── packages.list    pkg + ca_root_nss + doas
    │   └── rootfs/          copied over /: motd.template, rc.conf.d/{hostname,ntpd,firstboot_user},
    │                        rc.d/firstboot_user, usr/local/sbin/@SLUG@-install
    └── profiles/
        ├── appliance/       headless: packages.list (empty-ish), loader.conf.d,
        │                    rc.conf.d/sshd, sshd_config.d
        └── desktop/         X11 only: packages.list, branding.conf, rc.conf.d/{dbus,lightdm},
                           lightdm configs under rootfs/usr/local/etc
```

## Overlay rules

- **Never patch src or ports.** Configuration happens only via
  `overlay/base/src.conf` (used as `SRCCONF`) and files copied over the
  staged root under `overlay/**/rootfs/`.
- Overlay `rootfs` files are copied base-first, then the profile on top.
- `@DISTRO_NAME@`, `@MOTD@`, `@SLUG@` and `@BRAND_URL@` placeholders in the copied overlay
  files are substituted by `build.sh` from `product.conf`.
- Files staged with a literal `@SLUG@` in their **name** (e.g.
  `usr/local/sbin/@SLUG@-install`) are renamed by `build.sh` to the slug.
- `rc.conf.d` fragments are named **after their service**
  (`rc.conf.d/sshd`, `.../dbus`, ...): rc(8) `load_rc_config` only reads
  `/etc/rc.conf.d/<service-name>`, so a fragment named
  `rc.conf.d/<distro>` or `<profile>` would never be read.
- `overlay/base/rootfs/etc/motd.template` also becomes the live `/etc/motd`;
  `rc.d/motd` keeps using the template on every boot.
- `build.sh` touches a `/firstboot` sentinel in the staged image
  (KEYWORD firstboot scripts only run while it exists); the ISO-only
  install-image/motd additions are undone again after the ISO is built.
- The stock `distribution` step leaves root with an empty password;
  `build.sh` locks root in the staged image and creates the
  `/firstboot` sentinel. Provision a user or SSH key at first boot
  (see **First-boot user + install to disk** below).
- Any `rm -rf` in `build.sh` is guarded: only paths validated non-empty and
  under `OUT` may be removed. Edits such as the `/etc/ttys` change below are
  applied to the STAGED copy only — the upstream tree is never touched.

## The mt76 rule

The mt76 wireless driver is **never enabled, loaded or configured** by this
template. `build.sh` enforces this: the build fails if any file under
`overlay/` even mentions mt76 — which is why the overlay contains no such
mention at all. Keep it that way.

## Profiles

| profile      | what it builds |
|--------------|----------------|
| `appliance`  | headless: serial console (`console="comconsole"`, 115200), sshd with `PermitRootLogin no` / `PasswordAuthentication no`, no extra packages. `build.sh` additionally flips `ttyu0` in the staged `/etc/ttys` from `onifconsole` to `on` (staged copy only) so the serial getty is always up. |
| `desktop`    | X11 only, **no Wayland anywhere**: Xorg + Xfce + LightDM (`greeter-session=lightdm-gtk-greeter`, `user-session=xfce`), dbus; libinput pointer input (`xf86-input-libinput`). Greeter branding hooks point at `/usr/local/share/@SLUG@/artwork/...` — see `overlay/profiles/desktop/branding.conf` for the artwork-template contract (palette `PRIMARY ACCENT DARK DARK2 LIGHT MUTED` from wtfbsd/artwork-template `palette.env`, six hex digits, no `#`; install prefix `/usr/local/share/<slug>/artwork/{logo,wallpapers,loader,lightdm}`). **No art files live in this repo.** sshd is deliberately NOT auto-enabled on the desktop profile. |

## First-boot user + install to disk

`build.sh` locks root, so every image provisions its login account on the
first boot via `overlay/base/rootfs/etc/rc.d/firstboot_user` (KEYWORD
`firstboot`, runs only while the `/firstboot` sentinel exists — which
`build.sh` touches into the stage). It **parses** (never sources)
`/boot/firstboot-user.conf` (`KEY=value` lines):

```
USERNAME=alice                       # ^[a-z_][a-z0-9_-]{0,31}$, required
FULLNAME=Alice                       # no ':' / control characters, optional (default: username)
SSH_KEY=ssh-ed25519 <base64> ci@host # one authorized_keys line, may repeat (required)
PASSWORD_HASH=$6$...                 # crypt(3), $6$ or $2b$ only, optional ($6$|$2b$)
WHEEL=yes                            # yes|no, default yes
```

The config is validated line by line, the user is created with
`pw useradd -n USER -c FULLNAME -m -s /bin/sh [-G wheel]`, a given hash is
fed to `pw usermod -n USER -H 0` over stdin (a locked account cannot ssh,
so without a hash the password stays `*` — key login works — and `pw lock`
is never used), keys are installed as `~USER/.ssh/authorized_keys`
(0700 dir / 0600 file, user-owned), and the conf is renamed to
`/boot/firstboot-user.conf.done` (chmod 600 — it may contain a hash).
When `doas` is installed but `/usr/local/etc/doas.conf` is absent, the
script notes it and deliberately does nothing extra: doas.conf is
operator territory. Without a conf file the console gets instructions
(root is locked).

For CI/test images, `build.sh` bakes the same conf in:

```sh
./build.sh -c product.conf -u ciuser -k ./id_ed25519.pub   # both options together
```

For real installs, boot the ISO (it carries the raw image as
`/usr/local/share/<slug>/install/system.img.xz` (xz-compressed; ISO9660 cannot hold files over 4 GiB), added just before the ISO is
packed and removed again afterwards). Root is locked, so the ISO starts the
installer on the console by itself (an ISO-only `/etc/rc.local`, like stock
FreeBSD install media); it can also be run by hand:

```
<slug>-install [-d disk] [-u user] [-k pubkeyfile] [-p] [-y]
```

It lists disks from `kern.disks` (menu via `bsddialog` when available),
refuses the disk holding the running root, confirms unless `-y`, dd's the
image, recovers/resizes the partition table, grows UFS with `growfs -y`
or the ZFS pool with `zpool online -e`, writes the same first-boot conf
(keys prompted or from `-k`, password hashed via `openssl passwd -6`
with echoing turned off via `stty`), then unmounts/exports and asks you
to remove the media and reboot.

## Building

Needs `product.conf` produced by wtfbsd/agents `scripts/apply-answers.sh`
(the full key list is `KNOWN_KEYS` in `build.sh`, mirroring wtfbsd/agents
`questions.yaml`). The build refuses anything with
`DISTRO_OS` other than `freebsd` and validates the slug against
`^[a-z][a-z0-9-]*$`.

The file is parsed, never sourced. One outer pair of quotes around a value
is stripped — single or double, the single quotes are what
`apply-answers.sh` writes (`KEY='value'`) — while a mix of the two and a
quote inside the pair are refused.

```sh
./build.sh -c product.conf -n                 # dry run: print the plan
./build.sh -c product.conf                    # PROFILE from product.conf
./build.sh -c product.conf -p both            # appliance + desktop
./build.sh -c product.conf -u ci -k ./ci.pub  # bake a CI first-boot user
```

Knobs: `KERNCONF` (default `GENERIC`), `ROOTSIZE` (default `12g`), `PKG_ABI`
(e.g. `FreeBSD:15:aarch64` for cross-arch pkg installs — prefer building in a
VM of the matching arch). `ROOTSIZE` is a number with an optional `k`, `m`, `g`
or `t` suffix; the suffix is lowercased, because `makefs(8)` reads a size only
with a lowercase suffix (`12G` is an illegal number to it).

The output directory (`-o`, default `./out`) is made absolute before the
build starts: the build runs `make(1)` inside the source tree, where a
relative `DESTDIR` would land in the source tree instead of in the output
directory. The plan prints the absolute path. A dry run creates nothing.

Artifacts land as `out/<profile>/<slug>-<profile>-<arch>.{img,iso}` plus
`out/SHA256` (`sha256 -r`). The ISO additionally carries the raw image as
`/usr/local/share/<slug>/install/system.img.xz` (xz-compressed; ISO9660 cannot hold files over 4 GiB) (ISO only) with a matching
`/etc/motd` hint line: run `<slug>-install` as root to install to disk.

## CI (Jenkins)

`Jenkinsfile` is a generic pipeline: a fork runs it on its own Jenkins.
It names no organisation, no real host and no address; the leak check (see
**The leak check**) holds the whole tree to that.

| parameter | default | meaning |
|---|---|---|
| `PROFILE` | `desktop` | `desktop`, `appliance` or `both` |
| `AGENT_LABEL` | `bsd-builder` | label of the agent that builds and boot-tests |
| `WTFBSD_VM_PROVIDER` | `bhyve` | the VM provider `ci/vm.sh` dispatches to |
| `BUILD_ON_AGENT` | `yes` | `yes` = `build.sh` runs on the agent; `no` = the build runs inside a VM made by `ci/vm.sh` |
| `PRODUCT_CONF` | (file parameter) | `product.conf` to build; without it the `product.conf` artifact of the `product-conf` job is copied |
| `WTFBSD_VM_IMAGE` | (empty) | bootable image used when `BUILD_ON_AGENT` is `no` |

Stages: **Validate → Prepare → Test → Build → Boot test → Archive**.

- **Validate** refuses a parameter that is not in the expected list (an
  API-triggered build can bypass the choice lists).
- **Prepare** takes `product.conf` from the `PRODUCT_CONF` file parameter, or
  copies the `product.conf` artifact of the `product-conf` job. It also
  clears the two files of the workspace that belong to one build: the list of
  the VMs the build creates (`.wtfbsd-vms`) and the known hosts file
  (`.wtfbsd-known-hosts`), because the VMs of this build are new and a host
  key that changed has to be learned again.
- **Test** runs `tests/run-tests.sh`: a tree that fails its own checks must
  not produce an image.
- **Build** runs `build.sh -c product.conf -p "$PROFILE"` on the agent, or
  inside a VM (`ci/vm.sh create`, `ci/vm.sh addr`, then `scp`/`ssh`). The two
  paths of the build VM (`WTFBSD_VM_BUILD_DIR` and `WTFBSD_VM_SRC`) are
  checked before they are used: they have to be absolute paths of letters,
  digits, `.`, `_`, `/` and `-`, because they end up in the command that the
  shell of the remote host reads.
- **Boot test** runs `tests/boot-test.sh` once per built profile.
- **Archive** archives `out/**/*.img`, `out/**/*.iso` and `out/SHA256`.
- `post { always }` destroys every VM the pipeline created; the names are
  collected in `${WORKSPACE}/.wtfbsd-vms`. A destroy that failed is a VM that
  may still be running: the names of those VMs are printed and the build is
  failed with them, so that a leaked VM is never a green run.

The agent label comes from the `AGENT_LABEL` parameter; an empty parameter
(the first run of a fresh job) falls back to `bsd-builder`. Jenkins checks
the label when it allocates the agent, which happens before any stage of the
pipeline runs. If your Jenkins does not resolve parameters in the `agent`
directive, set the label in the job configuration instead.

`PRODUCT_CONF` is a **file parameter**: the controller needs the
**File Parameter plugin** to offer it. A Pipeline does not get a file
parameter in its workspace (JENKINS-27413): the plugin stashes the file
under the name of the parameter, and the pipeline takes it back into the
workspace with `unstash('PRODUCT_CONF')`. The parameter is declared with
`stashedFile` in the `parameters` block — that is a parameter type, not a
step: calling it as a step does nothing.

**Prepare** takes the uploaded file when the plugin says there is one: the
plugin sets `PRODUCT_CONF_FILENAME` to the name of the file that was
uploaded, and leaves it empty when the optional parameter was not filled in.
That is what the branch tests. The plugin is not here to be tested against,
so the pipeline says so itself: *unverified: confirm with one real upload
run*.

The name of a VM is built from the job name **with its folder**
(`JOB_NAME`, not `JOB_BASE_NAME`, which is not unique across the folders of
a Jenkins) and from the build number. The name is sanitised and ends with a
six-hex checksum of the full raw name, so that two jobs whose names
sanitise to the same string — and two long names that are shortened to the
same head — never share a VM name.

## The VM layer

Every VM the pipeline or the boot test touches goes through `ci/vm.sh`. It
dispatches to `ci/providers/<name>.sh`, selected with `$WTFBSD_VM_PROVIDER`,
or to a provider script outside this repository, selected with
`$WTFBSD_VM_PROVIDER_PATH`. An unknown or missing provider **fails closed**:
nothing is started and the exit status is 2.

### Provider contract

| subcommand | arguments | stdout | exit codes |
|---|---|---|---|
| `create` | `NAME IMAGE` | nothing | 0 ok, 1 bad arguments, 2 no provider, 3 provider failed |
| `console` | `NAME` | the path of the serial console log, one line | as above |
| `addr` | `NAME` | the address of the VM, one line | as above |
| `destroy` | `NAME` | nothing | as above |

stdout carries the machine-readable answer and nothing else: a provider
writes its progress to stderr. The boot test reads the path of the console
log and the address of the VM from stdout, so a provider that wrote its
progress there would break it.

`NAME` must match `^[a-z][a-z0-9-]{0,30}$`. A provider that cannot do
something exits 3 and says why on stderr; its own status is passed through.

### Plugging in your own provider

Write a script anywhere on the host and point the environment at it:

```sh
WTFBSD_VM_PROVIDER_PATH=/path/to/site-provider.sh ci/vm.sh create build-1 disk.img
```

The script implements the four subcommands above, with the same arguments and
the same meaning of the output, and exits 0 on success, 1 on a bad argument
and 3 when the operation fails. It must be executable. It is never edited by
this repository, so a site can change it without forking. `WTFBSD_VM_PROVIDER`
and `WTFBSD_VM_PROVIDER_PATH` are mutually exclusive; the path wins.

The provider runs with the privileges of the agent — as root on a FreeBSD
build agent, because `bhyve(8)` needs it. It is therefore trusted code: the
file must be **owned by root** and it **must not be writable** by anybody who
can submit a job. A provider a job author can rewrite is a provider a job
author can run as root.

### The reference provider

`ci/providers/bhyve.sh` uses stock `bhyve(8)` and `bhyvectl(8)` on FreeBSD:

```sh
bhyve -c 2 -m 2G -H -A -P -s 0,hostbridge -s 2,virtio-blk,IMAGE \
	-s 3,virtio-net,TAP -s 31,lpc -l com1,/dev/nmdm0A \
	-l bootrom,/usr/local/share/uefi-firmware/BHYVE_UEFI.fd NAME
```

The serial console is a null-modem pair (`nmdm(4)`): the guest side is the A
end, the host reads the B end and copies it into
`$WTFBSD_CONSOLE_DIR/NAME.log` (default `./console-logs`, under the job
workspace). The VM is destroyed with `bhyvectl --destroy --vm=NAME`.

Environment: `WTFBSD_TAP` (default `tap0`), `WTFBSD_BRIDGE` (default
`bridge0`), `WTFBSD_CONSOLE_DIR`, `WTFBSD_VM_CPUS` (default `2`),
`WTFBSD_VM_MEMORY` (default `2G`), `WTFBSD_VM_FIRMWARE` (default
`/usr/local/share/uefi-firmware/BHYVE_UEFI.fd`), `WTFBSD_NMDM_INDEX`
(default `0`), `WTFBSD_VM_DEVICE_DIR` (default `/dev/vmm`) and
`WTFBSD_VM_ADDR`. The tap and the bridge name must match
`^[a-z][a-z0-9]*[0-9]+$`; the reference provider does not do DHCP, so it
reports the address it was given.

When the agent reports an `EXECUTOR_NUMBER` (Jenkins does), the tap and the
null-modem pair are derived from it — `tap$EXECUTOR_NUMBER`, and the pair
number `$EXECUTOR_NUMBER` — so that two jobs on one host do not fight over
the same devices. `WTFBSD_TAP` and `WTFBSD_NMDM_INDEX` win over that. The
console reader of an earlier run of the same VM is stopped before a new one
starts, and `destroy` stops it again. The pid of the reader is read from a
file in the workspace, so it is not under the control of the provider: a
value that is not the pid of a reader is refused and never signalled
(`kill(2)` with 0 reaches every process of the group of the caller).

Host preparation on a FreeBSD host:

```sh
pkg install edk2-bhyve        # the UEFI firmware for bhyve(8)
kldload vmm                   # the hypervisor
kldload if_bridge
kldload if_tap
ifconfig bridge0 create
ifconfig bridge0 up
```

`bhyve(8)` and `bhyvectl(8)` are in the base system; only the firmware comes
from a package. **Only the bridge has to exist on the host.** The provider
makes the tap: opening a tap device creates it outside any bridge and down,
so `create` does `ifconfig tapN create`, `ifconfig tapN up` and
`ifconfig bridge0 addm tapN` itself. Every one of those steps is fatal when
it fails — a VM with no network is not started — and `destroy` detaches the
tap again (`ifconfig(8)` has no `master` keyword: a bridge member is added
with `addm` and removed with `deletem`) and destroys the tap only when the
provider made it.

`destroy` stops the VM first (`bhyvectl --destroy --vm=NAME`), and only
then stops the console reader and takes the tap away: the NIC of a running
guest is not pulled away from under it, and a destroy that fails leaves the
VM and its tap alone. The names of the tap and of the bridge are written
down at the create (`$WTFBSD_CONSOLE_DIR/NAME.tap`) and the destroy acts on
those names: the environment of the destroy may hold other ones (the
executor number of the job is not set in every context), and the tap of the
host must not be taken away with the tap of the guest.

The `addm` is skipped when the bridge already lists the tap as a member: a
run that died hard leaves the tap in the bridge, and `ifconfig(8)` refuses
an `addm` of a member that is already there (EEXIST). The member list of the
bridge is read first, and a bridge that cannot be listed is left to the
`addm`, which fails loudly when the tap is not a member.

## The boot test

```sh
sh tests/boot-test.sh out/appliance/examplebsd-appliance-amd64.img appliance
```

- creates the VM through `ci/vm.sh create`, never directly;
- waits for `login:` on the serial console, bounded by `BOOT_TIMEOUT`
  (default 600 s);
- for the `appliance` profile also waits for sshd to answer on port 22
  (`nc -z -w 2`); the `desktop` profile is happy with the serial login prompt
  for now, because the greeter is not on the serial console;
- always destroys the VM (traps on EXIT, HUP, INT and TERM), also when the
  wait times out;
- exits non-zero when the wait times out;
- exits non-zero when the VM could not be destroyed: a leaked VM is a failed
  run, and the boot test says `destroy failed: VM <name> may still be
  running`.

Usage: `tests/boot-test.sh IMAGE PROFILE [NAME]`. `NAME` is the name of the
VM; without it the name is `boot-$PROFILE-$$`. A caller that has to destroy
the VM by name — the pipeline, for instance — passes it as the third
argument or in `WTFBSD_VM_NAME`.

Environment: `BOOT_TIMEOUT` (seconds, default 600), `SSH_PORT` (default
22) and `WTFBSD_VM_NAME` (the name of the VM).

The ISO boots the built system directly (or run `<slug>-install` as root
to install it to disk — see **First-boot user + install to disk**). The
appliance profile boots to a serial console, the desktop profile boots to the
LightDM greeter on X11.

## The leak check

`tests/run-tests.sh` runs a `no_internal_refs` check over the files of the
tree. In a git checkout that is every file git tracks plus every file git
does not ignore; the files git ignores (the artifacts of a CI run, the
round reports) are not read. In a tree that is not a git checkout the same
files are left out by name (`product.conf`, `PRODUCT_CONF`, `console-logs/`,
`.wtfbsd-*`, `ROUND-REPORT*.md`), and the probe of the artifacts of a CI run,
which needs the ignore rules of git, is skipped. It has two halves.

The **public** half lives in the repository and looks for generic shapes
only. The exact patterns are in `tests/run-tests.sh`:

- an IPv4 or IPv6 address that is not a documented placeholder;
- an e-mail address that is not at a placeholder domain;
- an internal top level domain (the private-network ones and `home.arpa`);
- a key header or a public-key line;
- a token prefix of a well-known service, with the dashes of the keys that
  carry them (`sk-proj-…`, `sk-ant-…`);
- a credential keyword: an API key, a base URL or an authorization header.

Binary files are looked into as well: a key in a blob walks through a check
that only reads the text files.

The documented placeholders are `127.0.0.1`, `::1`, the IPv4 documentation
ranges `192.0.2.0/24`, `198.51.100.0/24` and `203.0.113.0/24`, the IPv6
documentation range `2001:db8::/32`, and the `example.org` and `example.com`
domains. On the domain of the OpenSSH key types only a key type is exempt:
the key types of the security keys (`sk-ssh-ed25519@openssh.com`,
`sk-ecdsa-sha2-nistp256@openssh.com`) are shaped like an e-mail address, and
the product code keeps the exact key types instead of loosening them for
the check. Any other address on that domain is a leak like any other.

The public half never names what it looks for: a list of the names that must
not be published is itself a publication of them, and a name split into
fragments is the same publication with extra steps. So the names live
outside the repository, in the file named by `$WTFBSD_DENYLIST`. Every
non-comment line of that file is used as a case-insensitive extended regular
expression against every file of the tree:

```sh
WTFBSD_DENYLIST=~/private/denylist.txt sh tests/run-tests.sh
```

The repository ships no such file.

The round reports (`ROUND-REPORT*.md`) are per-round artifacts that quote
session material. They are ignored by git and are never tracked.

The artifacts of a CI run are ignored by git as well: the product
configuration of the site (`product.conf`), the file parameter of the
pipeline (`PRODUCT_CONF`), the console logs of the VMs (`console-logs/`) and
the scratch files of the tooling (`.wtfbsd-*`). They are written in the
workspace of a job, they carry the addresses and the targets of one site,
and they are never part of the template — so the leak check reads the tree
and not the debris of a run.

