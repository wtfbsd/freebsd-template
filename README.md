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
├── Jenkinsfile              CI stub (build VM lifecycle)
├── build.sh                 the build driver (POSIX sh)
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
USERNAME=alice        # ^[a-z_][a-z0-9_-]{0,31}$, required
FULLNAME=Alice        # no ':' / control characters, optional (default: username)
SSH_KEY=ssh-ed25519 AAAA... # one authorized_keys line, may repeat (required)
PASSWORD_HASH=$6$...  # crypt(3), $6$ or $2b$ only, optional ($6$|$2b$)
WHEEL=yes             # yes|no, default yes
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

```sh
./build.sh -c product.conf -n                 # dry run: print the plan
./build.sh -c product.conf                    # PROFILE from product.conf
./build.sh -c product.conf -p both            # appliance + desktop
./build.sh -c product.conf -u ci -k ./ci.pub  # bake a CI first-boot user
```

Knobs: `KERNCONF` (default `GENERIC`), `ROOTSIZE` (default `12G`), `PKG_ABI`
(e.g. `FreeBSD:15:aarch64` for cross-arch pkg installs — prefer building in a
VM of the matching arch).

Artifacts land as `out/<profile>/<slug>-<profile>-<arch>.{img,iso}` plus
`out/SHA256` (`sha256 -r`). The ISO additionally carries the raw image as
`/usr/local/share/<slug>/install/system.img.xz` (xz-compressed; ISO9660 cannot hold files over 4 GiB) (ISO only) with a matching
`/etc/motd` hint line: run `<slug>-install` as root to install to disk.

## Bhyve build VM example (FreeBSD host)

```sh
pkg install vm-bhyve bhyve-firmware
sysrc vm_enable=YES vm_dir="zfs:zroot/vm"   # adjust to your pool
vm init
cp /usr/local/share/examples/vm-bhyve/default.conf /zroot/vm/.templates/   # = the mountpoint of vm_dir
vm switch create public
vm switch add public em0                     # your host's LAN NIC
# ISO placeholder — pick the matching release for your tree:
vm iso fetch https://download.freebsd.org/.../FreeBSD-15.0-RELEASE-amd64-disc1.iso
vm create -t default -c 8 -m 16G -s 120G build-1
vm install build-1 FreeBSD-15.0-RELEASE-amd64-disc1.iso
vm start build-1

# inside build-1 (vm console build-1): unmodified src, this repo, product.conf
pkg install -y git
git clone https://git.freebsd.org/src.git -b releng/15.0 /usr/src
git clone https://github.com/wtfbsd/freebsd-template.git
cd freebsd-template
# product.conf: from wtfbsd/agents scripts/apply-answers.sh answers.yaml
./build.sh -c product.conf -p both

# copy out/<profile>/<slug>...img, ...iso and out/SHA256 somewhere reachable
vm destroy -f build-1
```

## Test boot

```sh
vm create -t default -s 32G test-1
vm install test-1 out/appliance/examplebsd-appliance-amd64.iso
vm console test-1
```

The ISO boots the built system directly (or run `<slug>-install` as root
to install it to disk — see **First-boot user + install to disk**). The
appliance profile boots to a serial console (attach with `vm console`).
The desktop profile boots to the LightDM greeter on X11.
