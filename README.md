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
    │   ├── packages.list    pkg + ca_root_nss
    │   └── rootfs/          copied over /: motd.template, rc.conf.d/examplebsd
    └── profiles/
        ├── appliance/       headless: packages.list (empty-ish), loader.conf.d,
        │                    rc.conf.d/appliance, sshd_config.d
        └── desktop/         X11 only: packages.list, branding.conf, rc.conf.d,
                           lightdm configs under rootfs/usr/local/etc
```

## Overlay rules

- **Never patch src or ports.** Configuration happens only via
  `overlay/base/src.conf` (used as `SRCCONF`) and files copied over the
  staged root under `overlay/**/rootfs/`.
- Overlay `rootfs` files are copied base-first, then the profile on top.
- `@DISTRO_NAME@`, `@MOTD@`, `@SLUG@` and `@BRAND_URL@` placeholders in the copied overlay
  files are substituted by `build.sh` from `product.conf`.
- `overlay/base/rootfs/etc/motd.template` also becomes the live `/etc/motd`;
  `rc.d/motd` keeps using the template on every boot.
- The stock `distribution` step leaves root with an empty password;
  `build.sh` locks root in the staged image. Provision a user or SSH key
  at first boot (first-boot user creation is not in this template yet).
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
| `desktop`    | X11 only, **no Wayland anywhere**: Xorg + Xfce + LightDM (`greeter-session=lightdm-gtk-greeter`, `user-session=xfce`), dbus. Greeter branding hooks point at `/usr/local/share/@SLUG@/artwork/...` — see `overlay/profiles/desktop/branding.conf` for the artwork-template contract (palette `PRIMARY ACCENT DARK DARK2 LIGHT MUTED` from wtfbsd/artwork-template `palette.env`, six hex digits, no `#`; install prefix `/usr/local/share/<slug>/artwork/{logo,wallpapers,loader,lightdm}`). **No art files live in this repo.** |

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
```

Knobs: `KERNCONF` (default `GENERIC`), `ROOTSIZE` (default `12G`), `PKG_ABI`
(e.g. `FreeBSD:15:aarch64` for cross-arch pkg installs — prefer building in a
VM of the matching arch).

Artifacts land as `out/<profile>/<slug>-<profile>-<arch>.{img,iso}` plus
`out/SHA256` (`sha256 -r`).

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

The ISO boots the built system directly (installer media comes from
wtfbsd/installer-template). The appliance profile boots to a serial console (attach with `vm console`).
The desktop profile boots to the LightDM greeter on X11.
