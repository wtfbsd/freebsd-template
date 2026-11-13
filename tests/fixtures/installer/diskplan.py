# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
"""The disk plan of the installer, without a display.

The disk page builds a plan, the root helper and every install command
check it, and the summary describes it.  The plan is one JSON object
(version 1) that the front end writes to a file of mode 0600 and the
install command reads with -p.  Its schema is in the contract of the
installer (README.md, "The disk plan").

Everything here is pure: what the operating system offers (layouts,
filesystems, encryption), the usable size and the redundancy of a layout,
the default swap, the checks of a plan against the disks the adapter
reports, the partition bars before and after, and the actions per disk.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Tuple

MiB = 1024 * 1024
GiB = 1024 * MiB
# re.ASCII: \d is 0 to 9 only, never another digit of Unicode.
# A disk: letters then digits (ada0, sd1, nda0), or the cXtYdZ of illumos
# (c2t0d0, c0t5000CCA012345678d0).
DISK_RE = re.compile(r"[a-z]+\d+|c\d+(?:t[0-9A-F]+)?d\d+", re.ASCII)
NAME_RE = re.compile(r"[a-z][a-z0-9_-]{0,31}")
MOUNT_RE = re.compile(r"/([A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*)?")
MAX_PLAN_BYTES = 64 * 1024
MODES = ("erase", "alongside", "manual")
PART_TYPES = ("efi", "bios-boot", "root", "swap", "data")
WIPES = ("quick", "secure")
PLAN_KEYS = {
    "version", "mode", "boot", "disks", "layout", "filesystem", "encryption",
    "swap_mb", "sector_4k", "trim", "wipe", "confirm_foreign", "alongside",
    "partitions", "data", "usage",
}
USAGES = ("together", "separate")
SINGLE_DISK = "Single disk"


@dataclass(frozen=True)
class Layout:
    """A layout of the system disks: its name, the disks it needs, the
    disks whose loss it survives and the share of the space it keeps."""

    ident: str
    title: str
    min_disks: int
    max_disks: int = 64
    even: bool = False
    note: str = ""
    encrypted: bool = False

    def usable(self, sizes: List[int]) -> int:
        """The usable bytes on disks of these sizes."""
        n = len(sizes)
        if n == 0:
            return 0
        small = min(sizes)
        if self.ident in ("single", "crypto"):
            return sizes[0]
        if self.ident == "stripe":
            return small * n
        if self.ident in ("mirror", "raid1", "raid1c"):
            return small
        if self.ident == "raid10":
            return small * (n // 2)
        if self.ident in ("raidz1", "raid5"):
            return small * (n - 1)
        if self.ident == "raidz2":
            return small * (n - 2)
        if self.ident == "raidz3":
            return small * (n - 3)
        return small

    def survives(self, n: int) -> int:
        """How many disks may fail without losing the system."""
        if self.ident in ("single", "stripe", "crypto"):
            return 0
        if self.ident in ("mirror", "raid1", "raid1c"):
            return max(n - 1, 0)
        if self.ident == "raid10":
            return 1
        if self.ident in ("raidz1", "raid5"):
            return 1
        if self.ident == "raidz2":
            return 2
        if self.ident == "raidz3":
            return 3
        return 0

    def fits(self, n: int) -> Optional[str]:
        """None when the layout can use n disks, else the reason."""
        if n < self.min_disks:
            return f"needs at least {self.min_disks} disks"
        if n > self.max_disks:
            return f"takes at most {self.max_disks} disk" + ("s" if self.max_disks > 1 else "")
        if self.even and n % 2:
            return "needs an even number of disks"
        return None


# What every operating system offers.  The first filesystem is the default.
SYSTEMS: Dict[str, dict] = {
    "freebsd": {
        "layouts": [
            Layout("single", SINGLE_DISK, 1, 1),
            Layout("stripe", "Stripe", 2, note="all the space, no redundancy"),
            Layout("mirror", "Mirror", 2),
            Layout("raid10", "RAID 10", 4, even=True, note="mirrors, striped"),
            Layout("raidz1", "RAID-Z1", 3),
            Layout("raidz2", "RAID-Z2", 4),
            Layout("raidz3", "RAID-Z3", 5),
        ],
        "filesystems": [("zfs", "ZFS"), ("ufs", "UFS")],
        "single_only": {"ufs"},
        "encryption": "GELI",
        "boot": ("uefi", "bios"),
    },
    "netbsd": {
        "layouts": [
            Layout("single", SINGLE_DISK, 1, 1),
            Layout("raid1", "RAID 1 (RAIDframe)", 2),
            Layout("raid5", "RAID 5 (RAIDframe)", 3),
        ],
        "filesystems": [("ffs-wapbl", "FFSv2 with logging (WAPBL)"), ("ffs", "FFSv2")],
        "single_only": set(),
        "encryption": "cgd",
        "boot": ("uefi", "bios"),
    },
    # OpenBSD cannot start from a softraid RAID 5, and its install command
    # takes whole disks only.
    "openbsd": {
        "layouts": [
            Layout("single", SINGLE_DISK, 1, 1),
            Layout("raid1", "RAID 1 (softraid)", 2),
            Layout("crypto", "Encrypted (softraid CRYPTO)", 1, 1, encrypted=True),
            Layout("raid1c", "RAID 1C (mirrored and encrypted)", 2, encrypted=True),
        ],
        "filesystems": [("ffs", "FFS")],
        "single_only": set(),
        "encryption": "softraid CRYPTO",
        "boot": ("uefi", "bios"),
        "modes": ("erase",),
        # The install command makes each data disk its own FFS.
        "data_pools": True,
        "not_offered": "not offered on OpenBSD yet",
    },
    # illumos: what its install command takes (--capabilities): ZFS on
    # whole disks, Erase and install, the disks together; the home
    # directories and the data encrypted (ZFS native), never the system.
    "illumos": {
        "layouts": [
            Layout("single", SINGLE_DISK, 1, 1),
            Layout("stripe", "Stripe", 2, note="all the space, no redundancy"),
            Layout("mirror", "Mirror", 2),
            Layout("raid10", "RAID 10", 4, even=True, note="mirrors, striped"),
            Layout("raidz1", "RAID-Z1", 3),
            Layout("raidz2", "RAID-Z2", 4),
            Layout("raidz3", "RAID-Z3", 5),
        ],
        "filesystems": [("zfs", "ZFS")],
        "single_only": set(),
        "encryption": "",
        "home_encryption": "ZFS native",
        "swap_encryption": False,
        "boot": ("uefi", "bios"),
        "modes": ("erase",),
        "usages": ("together",),
        "data_pools": False,
        "not_offered": "not offered on illumos yet",
    },
    "dragonfly": {
        "layouts": [Layout("single", SINGLE_DISK, 1, 1)],
        "filesystems": [("hammer2", "HAMMER2"), ("ufs", "UFS")],
        "single_only": set(),
        "encryption": "dm_crypt (LUKS)",
        "boot": ("uefi", "bios"),
    },
}


def mount_ok(mount) -> bool:
    """An absolute mount point of plain names, without . or .. in it."""
    if not isinstance(mount, str) or not MOUNT_RE.fullmatch(mount) or len(mount) > 200:
        return False
    return all(part not in (".", "..") for part in mount.split("/")[1:])


def is_int(value) -> bool:
    """An integer of JSON, not a boolean (which Python counts as one)."""
    return isinstance(value, int) and not isinstance(value, bool)


BOOT_MODES = ("uefi", "bios")


def system(os_name: str, detail: Optional[dict] = None) -> dict:
    """What the system can do: the "capabilities" the adapter reports in
    the disk report when there are any (the install command of the system
    is the source of truth), else the built-in table."""
    base = dict(SYSTEMS.get(os_name, SYSTEMS["freebsd"]))
    base.setdefault("modes", MODES)
    base.setdefault("data_pools", True)
    base.setdefault("not_offered", "not offered on this system")
    base.setdefault("usages", USAGES)
    base.setdefault("home_encryption", "")
    base.setdefault("swap_encryption", True)
    caps = (detail or {}).get("capabilities") if isinstance(detail, dict) else None
    if not isinstance(caps, dict) or not caps:
        return base
    out = dict(base)
    _caps_disk_keys(caps, out)
    _caps_choice_keys(caps, out)
    return out


def _caps_disk_keys(caps: dict, out: dict) -> None:
    """The layouts, filesystems, modes, data pools and swap encryption of
    the capabilities, over the table."""
    items = _caps_layouts(caps)
    if items:
        out["layouts"] = items
    fss = _caps_filesystems(caps)
    if fss:
        out["filesystems"] = fss
    modes = [m for m in caps.get("modes") or [] if m in MODES]
    if modes:
        out["modes"] = tuple(modes)
    for key in ("data_pools", "swap_encryption"):
        if isinstance(caps.get(key), bool):
            out[key] = caps[key]


def _known(caps: dict, key: str, known: Tuple[str, ...]) -> Tuple[str, ...]:
    """The values of a list of the capabilities that are known, in the
    order of known; () when there is none."""
    given = caps.get(key) if isinstance(caps.get(key), list) else []
    return tuple(v for v in known if v in given)


def _caps_choice_keys(caps: dict, out: dict) -> None:
    """The boot modes, the usages and the texts of the capabilities."""
    # How the system starts: only the modes the install command takes;
    # an unknown value is left out, none at all keeps the table.
    boots = _known(caps, "boot", BOOT_MODES)
    if boots:
        out["boot"] = boots
    # Together and separately: only the ways the install command takes;
    # none at all (the BSDs) keeps both.
    usages = _known(caps, "usages", USAGES)
    if usages:
        out["usages"] = usages
    for key in ("encryption", "home_encryption", "not_offered"):
        if isinstance(caps.get(key), str):
            out[key] = caps[key]


def _int_or(raw: dict, key: str, default: int) -> int:
    """raw[key] when it is an integer of JSON, else the default."""
    return int(raw.get(key, default)) if is_int(raw.get(key, default)) else default


def _caps_layouts(caps: dict) -> List[Layout]:
    """The layouts of the capabilities: those with an ident."""
    items = []
    for raw in caps.get("layouts") or []:
        if not isinstance(raw, dict) or not isinstance(raw.get("ident"), str):
            continue
        items.append(Layout(raw["ident"], str(raw.get("title") or raw["ident"]),
                            _int_or(raw, "min_disks", 1), _int_or(raw, "max_disks", 64),
                            bool(raw.get("even", False)), str(raw.get("note", "")),
                            bool(raw.get("encrypted", False))))
    return items


def _caps_filesystems(caps: dict) -> List[Tuple[str, str]]:
    """The filesystems of the capabilities: pairs of ident and title."""
    return [(f[0], f[1]) for f in caps.get("filesystems") or []
            if isinstance(f, list) and len(f) == 2 and all(isinstance(x, str) for x in f)]


OS_TITLES = {"freebsd": "FreeBSD", "netbsd": "NetBSD", "openbsd": "OpenBSD",
             "dragonfly": "DragonFly", "illumos": "illumos"}


# The modes in the words of a terse refusal ("OpenBSD: no install alongside").
MODE_WORDS = {"erase": "erase and install", "alongside": "install alongside",
              "manual": "manual partitioning"}


def os_title(os_name: str) -> str:
    return OS_TITLES.get(os_name, os_name)


def layouts(os_name: str, detail: Optional[dict] = None) -> List[Layout]:
    return list(system(os_name, detail)["layouts"])


def layout(os_name: str, ident: str, detail: Optional[dict] = None) -> Optional[Layout]:
    for item in layouts(os_name, detail):
        if item.ident == ident:
            return item
    return None


def filesystems(os_name: str, detail: Optional[dict] = None) -> List[Tuple[str, str]]:
    return list(system(os_name, detail)["filesystems"])


def data_pools_offered(os_name: str, detail: Optional[dict] = None) -> bool:
    return bool(system(os_name, detail)["data_pools"])


def layout_cards(os_name: str, sizes: List[int], detail: Optional[dict] = None) -> List[dict]:
    """What a card of every layout shows for the chosen disks: usable
    size, redundancy, minimum disks, and why it cannot be chosen."""
    cards = []
    for item in layouts(os_name, detail):
        reason = item.fits(len(sizes)) if sizes else "choose a disk"
        survives = item.survives(len(sizes))
        if survives == 0:
            redundancy = "no redundancy: a failed disk loses the system"
        elif survives == 1:
            redundancy = "survives 1 disk failure"
        else:
            redundancy = f"survives {survives} disk failures"
        cards.append({
            "ident": item.ident, "title": item.title, "min_disks": item.min_disks,
            "usable_bytes": item.usable(sizes) if not reason else 0,
            "redundancy": redundancy, "reason": reason, "note": item.note,
        })
    return cards


def default_layout(os_name: str, n: int, detail: Optional[dict] = None) -> str:
    """The layout a number of disks gets first: the safest that fits."""
    order = ["mirror", "raid1", "raidz2", "raidz1", "raid5", "single", "stripe"]
    if n >= 4:
        order = ["raidz2", "raid10", "raid5", "mirror", "raid1", "raidz1", "single", "stripe"]
    elif n == 3:
        order = ["raidz1", "raid5", "mirror", "raid1", "single", "stripe"]
    for ident in order:
        item = layout(os_name, ident, detail)
        if item is not None and item.fits(n) is None:
            return ident
    return "single"


def default_swap_mb(ram_mb: int) -> int:
    """Swap as large as the memory up to 4 GiB, half of it above, at most
    16 GiB."""
    if ram_mb <= 0:
        return 2048
    if ram_mb <= 4096:
        return ram_mb
    return min(max(4096, ram_mb // 2), 16384)


def human(size: int) -> str:
    """Bytes the way the pages show them."""
    if size <= 0:
        return "0 B"
    value = float(size)
    for unit in ("B", "kB", "MB", "GB", "TB", "PB"):
        if value < 1000 or unit == "PB":
            if unit == "B":
                return f"{int(value)} B"
            return f"{value:.1f} {unit}" if value < 100 else f"{value:.0f} {unit}"
        value /= 1000
    return f"{size} B"


def human_mb(mb: int) -> str:
    """A size given in MB (MiB) the way it was given: 260 MB, 8 GB."""
    if mb >= 1024:
        return f"{mb / 1024:g} GB" if mb % 1024 == 0 else f"{mb / 1024:.1f} GB"
    return f"{mb} MB"


def passphrase_strength(text: str) -> Tuple[int, str]:
    """A rough strength of a passphrase, 0 to 4, and a word for it."""
    if not text:
        return 0, "none"
    classes = sum(bool(re.search(p, text)) for p in (r"[a-z]", r"[A-Z]", r"[0-9]", r"[^A-Za-z0-9]"))
    score = 0
    if len(text) >= 8:
        score += 1
    if len(text) >= 12:
        score += 1
    if len(text) >= 16 or (len(text) >= 12 and classes >= 3):
        score += 1
    if classes >= 3 and len(text) >= 10:
        score += 1
    score = min(score, 4)
    return score, ("too short", "weak", "fair", "good", "strong")[score]


# ----------------------------------------------------------------- details


def disk_index(detail: dict) -> Dict[str, dict]:
    """The disks of an adapter report by name."""
    out = {}
    for disk in detail.get("disks", []) or []:
        if isinstance(disk, dict) and isinstance(disk.get("name"), str):
            out[disk["name"]] = disk
    return out


def foreign(disk: dict) -> List[str]:
    """The operating systems and pools the report found on a disk."""
    found = []
    for item in disk.get("os", []) or []:
        if isinstance(item, dict):
            found.append(str(item.get("detail") or item.get("name") or "an operating system"))
    return found


# The free space a system needs at least, when the configuration says
# nothing (MIN_DISK_GB of installer.conf).
MIN_INSTALL_MB = 16 * 1024
# Room to spare above the installed image.
HEADROOM_MB = 2 * 1024


def requirements(detail: dict) -> dict:
    req = detail.get("requirements") if isinstance(detail, dict) else None
    return req if isinstance(req, dict) else {}


def min_disk_mb(req: dict, swap_mb: int = 0) -> int:
    """The smallest disk the system goes on: the setting MIN_DISK_GB, but
    never less than the installed image, 2 GB to spare and the swap."""
    setting = req.get("min_disk_gb")
    setting_mb = setting * 1024 if is_int(setting) and setting > 0 else MIN_INSTALL_MB
    image = req.get("image_bytes")
    image_mb = -(-image // MiB) if is_int(image) and image > 0 else 0
    floor = 0
    if image_mb:
        swap = swap_mb if is_int(swap_mb) and swap_mb > 0 else 0
        floor = image_mb + HEADROOM_MB + swap
    return max(setting_mb, floor)


def min_disk_reason(req: dict, swap_mb: int = 0) -> str:
    """Why the minimum is what it is, for the message of a refusal."""
    need = min_disk_mb(req, swap_mb)
    setting = req.get("min_disk_gb")
    setting_mb = setting * 1024 if is_int(setting) and setting > 0 else MIN_INSTALL_MB
    image = req.get("image_bytes")
    if is_int(image) and image > 0 and need > setting_mb:
        return (f"{human_mb(need)} the system needs (the system image takes "
                f"{human_mb(-(-image // MiB))}, plus {human_mb(HEADROOM_MB)} to spare and "
                f"{human_mb(swap_mb)} of swap)")
    return f"{human_mb(need)} the system needs (the setting MIN_DISK_GB of this media)"


def _join(items: List[str]) -> str:
    if len(items) <= 1:
        return "".join(items)
    return ", ".join(items[:-1]) + " and " + items[-1]


def largest_free_mb(disk: dict) -> int:
    return max([f.get("size_mb", 0) for f in disk.get("free", []) or []
                if isinstance(f, dict) and is_int(f.get("size_mb", 0))] or [0])


def is_blank(disk: dict) -> bool:
    """A disk with nothing on it, as the system read it: no partition
    table, no filesystem, pool or encryption signature, no unknown data."""
    return (disk.get("scheme") in (None, "", "none")
            and not disk.get("partitions")
            and not disk.get("os")
            and not disk.get("signature")
            and not disk.get("unknown_bytes"))


def needs_usage_question(detail: dict, os_name: str = "") -> bool:
    """Two or more installable disks: use them together or separately?
    Asked only when the system offers both ways."""
    if len(detail.get("disks", []) or []) < 2:
        return False
    return not os_name or len(system(os_name, detail)["usages"]) > 1


def separate_plan(system_disk: str, others: Dict[str, Optional[str]], filesystem: str) -> dict:
    """The disks used separately: the system on one disk, every other disk
    left untouched (None) or formatted as its own drive on a mount point."""
    data = []
    for name in sorted(others):
        mount = others[name]
        if not mount:
            continue
        base = mount.rstrip("/").rsplit("/", 1)[-1] or name
        label = re.sub(r"[^a-z0-9_-]", "", base.lower())[:31] or name
        if not label[0].isalpha():
            label = "d" + label[:30]
        data.append({"name": label, "disks": [name], "layout": "single",
                     "filesystem": filesystem, "mount": mount})
    return {"usage": "separate", "disks": [system_disk], "layout": "single", "data": data}


def single_blank(detail: dict) -> bool:
    """Exactly one installable disk and it is blank: there is nothing to
    choose, and the page "Installation type" only says so."""
    disks = detail.get("disks", []) or []
    return len(disks) == 1 and is_blank(disks[0])


def machine_summary(detail: dict) -> List[str]:
    """One line for every disk: what it is, what it holds, its free space."""
    lines = []
    for disk in detail.get("disks", []) or []:
        head = f"{disk.get('name')} ({disk.get('model') or 'disk'}, {human(int(disk.get('size_bytes', 0)))})"
        found = foreign(disk)
        free = largest_free_mb(disk)
        if found:
            line = f"{head} holds {_join(found)}"
            line += f"; {human(free * MiB)} free" if free else "; no free space"
        elif disk.get("partitions"):
            line = f"{head} holds {len(disk['partitions'])} partitions"
            line += f"; {human(free * MiB)} free" if free else ""
        else:
            line = f"{head} is empty"
        lines.append(line)
    return lines


def install_types(detail: dict, product: str, os_name: str = "freebsd") -> List[dict]:
    """The installation types: what each does, whether it can be chosen
    (and why not), and what to know before choosing it."""
    disks = detail.get("disks", []) or []
    holding = [(d.get("name"), foreign(d)) for d in disks if foreign(d)]
    warning = " ".join(f"{name} holds {_join(found)}." for name, found in holding)
    if warning:
        warning += " Erase and install deletes everything on the disks you choose."
    need_mb = min_disk_mb(requirements(detail))
    room = [d for d in disks if largest_free_mb(d) >= need_mb]
    sysinfo = system(os_name, detail)
    types = [
        {"ident": "erase", "title": "Erase and install",
         "line": f"Use whole disks for {product}; everything on them is deleted.",
         "available": bool(disks), "reason": "" if disks else "no disk was found",
         "warning": warning},
        {"ident": "alongside", "title": "Install alongside",
         "line": f"Keep what is on a disk and put {product} in its free space.",
         "available": bool(room),
         "reason": "" if room else
         f"No disk has {human_mb(need_mb)} of free space for {product}.",
         "warning": ""},
        {"ident": "manual", "title": "Manual",
         "line": "Make the partitions yourself: type, size and mount point.",
         "available": bool(disks), "reason": "" if disks else "no disk was found",
         "warning": ""},
    ]
    for item in types:
        # A mode the install command does not take is not shown at all.
        item["offered"] = item["ident"] in sysinfo["modes"]
        if not item["offered"]:
            item["available"] = False
            item["reason"] = f"{os_title(os_name)}: no {MODE_WORDS[item['ident']]}"
    return types


# ----------------------------------------------------------------- checks


def validate(plan: dict, detail: dict, os_name: str) -> List[str]:
    """Every rule of the plan; an empty list when it may be installed.

    The same function runs in the front end, in the root helper and in the
    tests; every install command checks the same rules again.  The checks
    run in this order, and the errors come in it: the header and the mode,
    the disks and their usage, the disks to erase and the layout, the
    filesystem, encryption and swap, the wipes and confirmations, Install
    alongside, Manual, the data pools and last the checks across them."""
    if not isinstance(plan, dict):
        return ["the plan is not a JSON object"]
    check = _Validation(plan, detail, os_name)
    check.header()
    check.offered = disk_index(detail)
    check.disks_and_usage()
    check.erase_disks()
    check.storage()
    check.wipe_and_confirm()
    check.alongside()
    check.manual()
    check.data_pools()
    check.cross_checks()
    return check.errors


@dataclass
class _Partitions:
    """What the partitions of a manual plan add up to."""

    mounts: List[str]
    per_disk: Dict[str, int]
    roots: int = 0
    efi: int = 0


# How a plan's "usage" reads in a sentence.
USAGE_WORDS = {"together": "together", "separate": "separately"}

class _Validation:
    """The state the checks of one plan share: the errors in the order they
    are found, the disks the report offers and the disks the plan uses.
    Every method is one part of validate(), called in its order."""

    def __init__(self, plan: dict, detail: dict, os_name: str):
        self.plan = plan
        self.detail = detail
        self.os_name = os_name
        self.errors: List[str] = []
        self.offered: Dict[str, dict] = {}
        self.used: List[str] = []
        self.sysinfo: dict = {}
        self.mode = None
        self.disks: list = []
        self.fs_ids: List[str] = []
        self.wipe: dict = {}
        self.confirm: list = []
        self.data: list = []

    def check_disk(self, name, where) -> bool:
        if not isinstance(name, str) or not DISK_RE.fullmatch(name):
            self.errors.append(f"{where}: '{name}' is not the name of a disk")
            return False
        if name not in self.offered:
            self.errors.append(f"{where}: the disk {name} is not one the installer may write to")
            return False
        self.used.append(name)
        return True

    def swap_for_minimum(self) -> int:
        """The swap the minimum size counts: swap_mb when it is a number."""
        return self.plan.get("swap_mb", 0) if is_int(self.plan.get("swap_mb", 0)) else 0

    # The header: keys, version, mode and boot.
    def header(self) -> None:
        plan, errors = self.plan, self.errors
        unknown = set(plan) - PLAN_KEYS
        if unknown:
            errors.append("the plan has unknown keys: " + ", ".join(sorted(unknown)))
        if plan.get("version") != 1:
            errors.append("the plan is not version 1")
        mode = plan.get("mode")
        if not isinstance(mode, str) or mode not in MODES:
            errors.append("the mode is not erase, alongside or manual")
        elif mode not in system(self.os_name, self.detail)["modes"]:
            errors.append(f"{os_title(self.os_name)}: no {MODE_WORDS[mode]}")
        self.mode = mode
        self.sysinfo = system(self.os_name, self.detail)
        boot = plan.get("boot", "uefi")
        if not isinstance(boot, str) or boot not in self.sysinfo["boot"]:
            errors.append("the boot mode is not one this system supports")

    # The disks and their usage.
    def disks_and_usage(self) -> None:
        plan, errors, mode = self.plan, self.errors, self.mode
        disks = plan.get("disks", [])
        if not isinstance(disks, list):
            errors.append("disks is not a list")
            disks = []
        self.disks = disks
        if mode != "manual" and plan.get("partitions") not in (None, []):
            errors.append("partitions are for Manual only")
        if mode != "alongside" and plan.get("alongside") not in (None, {}):
            errors.append("alongside is for Install alongside only")
        self.usage()
        if mode in ("alongside", "manual") and disks:
            errors.append(f"disks is for Erase and install; it is empty for {mode}")

    def usage(self) -> None:
        usage = self.plan.get("usage")
        if usage is None:
            return
        if usage not in USAGES:
            self.errors.append("usage is not together or separate")
        elif usage not in self.sysinfo["usages"]:
            ways = " or ".join(USAGE_WORDS.get(u, u) for u in self.sysinfo["usages"])
            self.errors.append(f"{os_title(self.os_name)}: disks can only be used {ways}")
        elif self.mode != "erase":
            self.errors.append("usage is for Erase and install only")
        elif usage == "separate":
            self.separate()

    def separate(self) -> None:
        plan, errors = self.plan, self.errors
        if len(self.disks) != 1 or plan.get("layout") != "single":
            errors.append("disks used separately put the system on one disk")
        for pool in plan.get("data") or []:
            if isinstance(pool, dict) and (len(pool.get("disks") or []) != 1
                                           or pool.get("layout") != "single"):
                errors.append("disks used separately are each their own drive")

    # The disks Erase and install erases, and its layout.
    def erase_disks(self) -> None:
        if self.mode != "erase":
            return
        plan, errors, disks = self.plan, self.errors, self.disks
        if not disks:
            errors.append("no disk was chosen")
        for name in disks:
            if self.check_disk(name, "disks"):
                self.disk_size(name)
        item = layout(self.os_name, plan.get("layout", ""), self.detail) \
            if isinstance(plan.get("layout", ""), str) else None
        if item is None:
            errors.append(f"the layout '{plan.get('layout')}' is not one this system offers")
        else:
            reason = item.fits(len(disks))
            if reason:
                errors.append(f"the layout {item.title} {reason}")

    def disk_size(self, name: str) -> None:
        size = self.offered[name].get("size_bytes", 0)
        req = requirements(self.detail)
        swap_mb = self.swap_for_minimum()
        if is_int(size) and size < min_disk_mb(req, swap_mb) * MiB:
            self.errors.append(f"the disk {name} ({human(size)}) is smaller than the "
                               f"{min_disk_reason(req, swap_mb)}")

    # The filesystem, the encryption and the swap.
    def storage(self) -> None:
        plan, errors = self.plan, self.errors
        self.filesystem()
        enc = self.encryption()
        swap = plan.get("swap_mb", 0)
        if not is_int(swap) or not 0 <= swap <= 1048576:
            errors.append("the swap size is not between 0 and 1048576 MB")
            swap = 0
        self.encryption_offered(enc, swap)
        for key in ("sector_4k", "trim"):
            if key in plan and not isinstance(plan[key], bool):
                errors.append(f"{key} is not true or false")

    def encryption_offered(self, enc: dict, swap: int) -> None:
        """The encryption of the plan against what the system offers, in
        this order: the system (or home and data), the layout, the swap."""
        plan, errors = self.plan, self.errors
        # A layout that is an encryption (OpenBSD's CRYPTO, RAID 1C) is never
        # chosen without encryption: the install command would make it with
        # no passphrase to ask for.
        chosen = layout(self.os_name, plan.get("layout", ""), self.detail) \
            if self.mode == "erase" and isinstance(plan.get("layout", ""), str) else None
        # On illumos the plan's encryption is that of the home directories
        # and the data (home_encryption): the system itself is not.
        if enc.get("enabled") and not (self.sysinfo["encryption"] or
                                       self.sysinfo["home_encryption"]):
            errors.append(f"{os_title(self.os_name)}: no system encryption")
        if chosen is not None and chosen.encrypted and not enc.get("enabled"):
            errors.append(f"the layout {chosen.title} encrypts: encryption has to be on")
        if enc.get("swap") and swap == 0:
            errors.append("encrypted swap needs swap")
        if enc.get("swap") and not self.sysinfo["swap_encryption"]:
            errors.append(f"{os_title(self.os_name)}: no swap encryption")

    def filesystem(self) -> None:
        sysinfo = self.sysinfo
        fs_ids = [fs for fs, _title in sysinfo["filesystems"]]
        self.fs_ids = fs_ids
        fs = self.plan.get("filesystem", fs_ids[0])
        if not isinstance(fs, str) or fs not in fs_ids:
            self.errors.append(f"the filesystem '{fs}' is not one this system offers")
        elif fs in sysinfo["single_only"] and len(self.disks) > 1:
            self.errors.append(f"the filesystem {fs} takes a single disk")

    def encryption(self) -> dict:
        enc = self.plan.get("encryption", {"enabled": False, "swap": False})
        if not isinstance(enc, dict) or set(enc) - {"enabled", "swap"} or \
                not all(isinstance(v, bool) for v in enc.values()):
            self.errors.append("encryption is not {enabled, swap} of true or false")
            enc = {}
        return enc

    # The wipes and the typed confirmations, as read.
    def wipe_and_confirm(self) -> None:
        plan, errors = self.plan, self.errors
        wipe = plan.get("wipe", {})
        if not isinstance(wipe, dict):
            errors.append("wipe is not an object")
            wipe = {}
        for name, how in wipe.items():
            if how not in WIPES:
                errors.append(f"the wipe of {name} is not quick or secure")
            if not isinstance(name, str) or not DISK_RE.fullmatch(name):
                errors.append("a wipe names something that is not a disk")
        self.wipe = wipe
        confirm = plan.get("confirm_foreign", [])
        if not isinstance(confirm, list) or not all(isinstance(n, str) and DISK_RE.fullmatch(n)
                                                     for n in confirm):
            errors.append("confirm_foreign is not a list of disks")
            confirm = []
        self.confirm = confirm

    # Install alongside: the disk and its region.
    def alongside(self) -> None:
        if self.mode != "alongside":
            return
        along = self.plan.get("alongside")
        if not isinstance(along, dict) or set(along) - {"disk", "region"}:
            self.errors.append("alongside is not {disk, region}")
            return
        name = along.get("disk")
        if self.check_disk(name, "alongside"):
            self.region(name, along.get("region"))

    def region(self, name: str, region) -> None:
        if not isinstance(region, dict) or set(region) - {"start_mb", "size_mb"}:
            region = {}
        start, size = region.get("start_mb"), region.get("size_mb")
        ok = is_int(start) and is_int(size) and start >= 0 and size > 0
        fits = ok and any(
            start >= f.get("start_mb", 0) and
            start + size <= f.get("start_mb", 0) + f.get("size_mb", 0)
            for f in self.offered[name].get("free", []) or [])
        if not fits:
            self.errors.append("the region is not inside the free space of the disk")
        # The same minimum as a whole disk: the setting, never below
        # the image, 2 GB to spare and the swap.
        req = requirements(self.detail)
        swap_mb = self.swap_for_minimum()
        if ok and size < min_disk_mb(req, swap_mb):
            self.errors.append(f"the region of {name} ({human_mb(size)}) is smaller than the "
                               f"{min_disk_reason(req, swap_mb)}")

    # Manual: the partitions.
    def manual(self) -> None:
        if self.mode != "manual":
            return
        errors = self.errors
        parts = self.plan.get("partitions", [])
        if not isinstance(parts, list) or not parts:
            errors.append("a manual plan needs partitions")
            parts = []
        tally = _Partitions(mounts=[], per_disk={})
        for i, part in enumerate(parts, start=1):
            self.partition(i, part, tally)
        if tally.roots != 1:
            errors.append("a manual plan needs exactly one root partition")
        else:
            self.root_size(parts, tally.per_disk)
        if self.plan.get("boot", "uefi") == "uefi" and tally.efi == 0:
            errors.append("booting with UEFI needs an EFI partition")
        for name, total in tally.per_disk.items():
            disk = self.offered.get(name)
            if disk and total * MiB > int(disk.get("size_bytes", 0)):
                errors.append(f"the partitions do not fit on {name}")

    def partition(self, i: int, part, tally: _Partitions) -> None:
        errors = self.errors
        if not isinstance(part, dict) or set(part) - {"disk", "type", "size_mb", "mount", "label"}:
            errors.append(f"partition {i} is not {{disk, type, size_mb, mount}}")
            return
        name = part.get("disk")
        if not isinstance(name, str):
            errors.append(f"partition {i}: the disk is not a name")
            return
        if name not in self.used:
            self.check_disk(name, f"partition {i}")
        ptype = part.get("type")
        if not isinstance(ptype, str) or ptype not in PART_TYPES:
            errors.append(f"partition {i}: the type is not one of {', '.join(PART_TYPES)}")
        size = part.get("size_mb")
        if not is_int(size) or not 0 <= size <= 1 << 40:
            errors.append(f"partition {i}: the size is not a number of MB")
            size = 0
        tally.per_disk[name] = tally.per_disk.get(name, 0) + size
        mount = part.get("mount")
        if mount is not None:
            self.partition_mount(i, mount, tally.mounts)
        if ptype == "root":
            tally.roots += 1
            if mount != "/":
                errors.append(f"partition {i}: the root is mounted on /")
        if ptype == "efi":
            tally.efi += 1

    def partition_mount(self, i: int, mount, mounts: List[str]) -> None:
        if not mount_ok(mount):
            self.errors.append(f"partition {i}: the mount point is not an absolute path")
        elif mount in mounts:
            self.errors.append(f"partition {i}: the mount point {mount} is used twice")
        else:
            mounts.append(mount)

    def root_size(self, parts: list, per_disk: Dict[str, int]) -> None:
        # The root partition (size 0: the rest of its disk) holds at
        # least the minimum of the system, the swap being its own.
        root = next(p for p in parts if isinstance(p, dict) and p.get("type") == "root")
        rsize = root.get("size_mb") if is_int(root.get("size_mb")) else 0
        rdisk = self.offered.get(root.get("disk"), {}) if isinstance(root.get("disk"), str) else {}
        if rsize == 0 and is_int(rdisk.get("size_bytes", 0)):
            rsize = rdisk.get("size_bytes", 0) // MiB - per_disk.get(root.get("disk"), 0)
        req = requirements(self.detail)
        if rdisk and rsize < min_disk_mb(req, 0):
            self.errors.append(f"the root partition ({human_mb(rsize)}) is smaller than the "
                               f"{min_disk_reason(req, 0)}")

    # The data pools.
    def data_pools(self) -> None:
        errors = self.errors
        data = self.plan.get("data", [])
        if not isinstance(data, list):
            errors.append("data is not a list")
            data = []
        self.data = data
        if data and not system(self.os_name, self.detail)["data_pools"]:
            errors.append(f"{os_title(self.os_name)}: no data disks")
        data_mounts: List[str] = []
        for i, pool in enumerate(data, start=1):
            self.data_pool(i, pool, data_mounts)

    def data_pool(self, i: int, pool, data_mounts: List[str]) -> None:
        errors = self.errors
        if not isinstance(pool, dict) or set(pool) - {"name", "disks", "layout", "filesystem", "mount"}:
            errors.append(f"data pool {i} is not {{name, disks, layout, filesystem, mount}}")
            return
        if not NAME_RE.fullmatch(str(pool.get("name", ""))):
            errors.append(f"data pool {i}: the name cannot be used")
        pdisks = pool.get("disks") or []
        if not isinstance(pdisks, list):
            errors.append(f"data pool {i}: disks is not a list")
            pdisks = []
        for name in pdisks:
            self.check_disk(name, f"data pool {i}")
        item = layout(self.os_name, pool.get("layout", ""), self.detail) \
            if isinstance(pool.get("layout"), str) else None
        if item is None or item.fits(len(pdisks)):
            errors.append(f"data pool {i}: the layout does not fit its disks")
        if not isinstance(pool.get("filesystem"), str) or pool.get("filesystem") not in self.fs_ids:
            errors.append(f"data pool {i}: the filesystem is not one this system offers")
        mount = pool.get("mount")
        if not mount_ok(mount) or mount == "/" or mount in data_mounts:
            errors.append(f"data pool {i}: the mount point cannot be used")
        else:
            data_mounts.append(mount)

    # Across the parts: a disk used twice, and what the plan erases.
    def cross_checks(self) -> None:
        errors = self.errors
        if len(self.used) != len(set(self.used)):
            errors.append("a disk is used twice")
        erased = self.erased()
        # Every disk named anywhere in the plan is one the plan erases: a wipe
        # or a confirmation of any other disk (the running system, a disk left
        # alone) is refused, so the install command never hears of it.
        for name in sorted(n for n in self.wipe if isinstance(n, str)):
            if name not in erased:
                errors.append(f"wipe: {name} is not one the plan erases")
        for name in self.confirm:
            if name not in erased or name not in self.offered:
                errors.append(f"confirm_foreign: {name} is not one the plan erases")
        # A disk that holds another system is erased only with a typed
        # confirmation.
        for name in erased:
            disk = self.offered.get(name)
            if disk and foreign(disk) and name not in self.confirm:
                errors.append(f"{name} holds {', '.join(foreign(disk))}: erasing it needs the typed confirmation")

    def erased(self) -> List[str]:
        """Every disk the plan erases, sorted."""
        plan = self.plan
        erased = list(self.disks) if self.mode == "erase" else []
        for pool in self.data:
            if isinstance(pool, dict) and isinstance(pool.get("disks"), list):
                erased += pool["disks"]
        if self.mode == "manual" and isinstance(plan.get("partitions"), list):
            erased += [p.get("disk") for p in plan["partitions"] if isinstance(p, dict)]
        return sorted({n for n in erased if isinstance(n, str)})


# ----------------------------------------------------------------- views


def bar_before(disk: dict) -> List[dict]:
    """The segments of a disk as it is: its partitions and free space."""
    size = int(disk.get("size_bytes", 0)) or 1
    segs = []
    for part in disk.get("partitions", []) or []:
        segs.append({"kind": part.get("kind") or part.get("type") or "other",
                     "label": part.get("label") or part.get("type") or "",
                     "bytes": int(part.get("size_bytes", 0))})
    used = sum(s["bytes"] for s in segs)
    if used < size:
        label = "empty" if is_blank(disk) else "free"
        segs.append({"kind": "free", "label": label, "bytes": size - used})
    return segs


def bar_after(disk: dict, plan: dict, os_name: str, product: str,
              detail: Optional[dict] = None) -> List[dict]:
    """The segments of a disk after the installation of the plan."""
    name = disk.get("name")
    size = int(disk.get("size_bytes", 0)) or 1
    mode = plan.get("mode")
    swap = plan.get("swap_mb", 0) * MiB
    if mode == "erase" and name in plan.get("disks", []):
        return _after_erase(size, swap, plan, os_name, product, detail)
    if mode == "alongside" and (plan.get("alongside") or {}).get("disk") == name:
        return _after_alongside(disk, plan, product)
    if mode == "manual":
        parts = [p for p in plan.get("partitions", []) if p.get("disk") == name]
        if parts:
            return _after_manual(size, parts)
    for pool in plan.get("data", []):
        if name in pool.get("disks", []):
            return [{"kind": "data", "label": data_words(pool, os_name, detail), "bytes": size}]
    return bar_before(disk)


def _after_erase(size: int, swap: int, plan: dict, os_name: str, product: str,
                 detail: Optional[dict] = None) -> List[dict]:
    segs = [{"kind": "efi", "label": "EFI", "bytes": 260 * MiB}]
    if swap:
        segs.append({"kind": "swap", "label": "swap", "bytes": swap})
    fs = dict(filesystems(os_name, detail)).get(plan.get("filesystem", ""), "")
    segs.append({"kind": "new", "label": f"{product} ({fs})".strip(),
                 "bytes": max(size - sum(s["bytes"] for s in segs), 0)})
    return segs


def _after_alongside(disk: dict, plan: dict, product: str) -> List[dict]:
    region = plan["alongside"].get("region") or {}
    start = region.get("start_mb", 0) * MiB
    new = region.get("size_mb", 0) * MiB
    segs = []
    pos = 0
    for seg in bar_before(disk):
        if seg["kind"] == "free" and pos <= start < pos + seg["bytes"]:
            segs += _split_free(pos, seg["bytes"], start, new, product)
        else:
            segs.append(seg)
        pos += seg["bytes"]
    return segs


def _split_free(pos: int, length: int, start: int, new: int, product: str) -> List[dict]:
    """A free segment at pos with the new system put in it at start."""
    segs = []
    if start > pos:
        segs.append({"kind": "free", "label": "free", "bytes": start - pos})
    segs.append({"kind": "new", "label": product, "bytes": new})
    rest = pos + length - start - new
    if rest > 0:
        segs.append({"kind": "free", "label": "free", "bytes": rest})
    return segs


def _after_manual(size: int, parts: List[dict]) -> List[dict]:
    segs = []
    fixed = sum(p.get("size_mb", 0) * MiB for p in parts)
    for part in parts:
        b = part.get("size_mb", 0) * MiB or max(size - fixed, 0)
        kind = "new" if part.get("type") in ("root", "data") else part.get("type")
        segs.append({"kind": kind, "label": part.get("mount") or part.get("type"), "bytes": b})
    return segs


def actions(plan: dict, detail: dict, os_name: str, product: str) -> List[Tuple[str, str, bool]]:
    """What the installation does to every disk: (disk, text, destructive)."""
    offered = disk_index(detail)
    sysinfo = system(os_name, detail)
    out = []
    fs_title = dict(sysinfo["filesystems"]).get(plan.get("filesystem", ""), plan.get("filesystem", ""))
    enc = plan.get("encryption", {}) or {}
    swap = plan.get("swap_mb", 0)
    mode = plan.get("mode")
    if mode == "erase":
        out += _erase_actions(plan, (detail, os_name, offered, sysinfo), (fs_title, enc, swap))
    elif mode == "alongside":
        along = plan.get("alongside") or {}
        region = along.get("region") or {}
        out.append((along.get("disk", ""),
                    f"keep everything, add {product} in {human_mb(region.get('size_mb', 0))} "
                    "of free space, reuse the EFI partition", False))
    elif mode == "manual":
        out += _manual_actions(plan)
    for pool in plan.get("data", []):
        for name in pool.get("disks", []):
            out.append((name, f"erase, {data_words(pool, os_name, detail)}", True))
    return out


def data_words(pool: dict, os_name: str, detail: Optional[dict] = None) -> str:
    """A data disk in few words: "FFS on /data", or for ZFS "ZFS pool tank
    (Mirror) on /tank" (a pool only where there is one)."""
    fs = pool.get("filesystem", "")
    title = dict(filesystems(os_name, detail)).get(fs, fs)
    if fs == "zfs":
        item = layout(os_name, pool.get("layout", ""), detail)
        return (f"{title} pool {pool.get('name')} ({item.title if item else pool.get('layout')}) "
                f"on {pool.get('mount')}")
    return f"{title} on {pool.get('mount')}"


def _erase_actions(plan: dict, system_of: tuple, storage: tuple) -> List[Tuple[str, str, bool]]:
    """The actions of Erase and install.  system_of is (detail, os_name,
    the disks offered, the system); storage is (the title of the
    filesystem, the encryption, the swap)."""
    detail, os_name, offered, sysinfo = system_of
    out = []
    item = layout(os_name, plan.get("layout", ""), detail)
    usage = plan.get("usage")
    if usage == "separate":
        out.append(("", "the disks are used separately: the system on "
                    f"{plan.get('disks', ['?'])[0]}, every other disk its own drive or untouched",
                    False))
    elif len(plan.get("disks", [])) > 1:
        out.append(("", f"the disks {', '.join(plan.get('disks', []))} are used together "
                    f"({item.title if item else plan.get('layout')})", False))
    for name in plan.get("disks", []):
        disk = offered.get(name, {})
        enc_what = (sysinfo["encryption"] or
                    (f"home and data, {sysinfo['home_encryption']}" if sysinfo["home_encryption"] else ""))
        text = ", ".join(_erase_parts(plan, name, item, enc_what, storage))
        if foreign(disk):
            text += f" — this deletes {', '.join(foreign(disk))}"
        out.append((name, text, True))
    return out


def _erase_parts(plan: dict, name: str, item: Optional[Layout], encryption: str,
                 storage: tuple) -> List[str]:
    """What Erase and install makes on one disk, in order."""
    fs_title, enc, swap = storage
    how = "securely erase" if plan.get("wipe", {}).get(name) == "secure" else "erase"
    parts = [f"{how}", "GPT", "EFI 260 MB"]
    if swap:
        parts.append(f"swap {human_mb(swap)}" + (" (encrypted)" if enc.get("swap") else ""))
    parts.append(f"{fs_title}" + (f" {item.title.lower()}" if item and len(plan['disks']) > 1 else ""))
    if enc.get("enabled"):
        parts.append(f"encrypted ({encryption})")
    return parts


def _manual_actions(plan: dict) -> List[Tuple[str, str, bool]]:
    out = []
    for name in sorted({p.get("disk") for p in plan.get("partitions", [])}):
        parts = [p for p in plan.get("partitions", []) if p.get("disk") == name]
        desc = ", ".join(
            f"{p.get('type')} {human_mb(p.get('size_mb', 0)) if p.get('size_mb') else 'the rest'}"
            + (f" on {p['mount']}" if p.get("mount") else "") for p in parts)
        out.append((name, f"erase, GPT, {desc}", True))
    return out


class PlanError(ValueError):
    """A plan file that is not a plan."""


def _no_duplicates(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise PlanError(f"the key {key!r} is given twice")
        out[key] = value
    return out


def _no_constants(name):
    raise PlanError(f"{name} is not a number of a plan")


def _depth(value, level=0):
    if level > 8:
        raise PlanError("the plan is nested too deeply")
    if isinstance(value, dict):
        for item in value.values():
            _depth(item, level + 1)
    elif isinstance(value, list):
        if len(value) > 256:
            raise PlanError("a list of the plan is too long")
        for item in value:
            _depth(item, level + 1)
    elif isinstance(value, str) and len(value) > 256:
        raise PlanError("a text of the plan is too long")
    elif isinstance(value, float):
        raise PlanError("the plan holds a number that is not whole")


def parse(data: bytes) -> dict:
    """The plan in a file, read strictly: UTF-8 JSON of at most 64 KiB, one
    object, no key twice, no NaN or Infinity, no fractions, nested at most
    8 deep, lists of at most 256 items and texts of at most 256 characters.
    Anything else raises PlanError."""
    if len(data) > MAX_PLAN_BYTES:
        raise PlanError("the plan is larger than 64 KiB")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise PlanError("the plan is not UTF-8") from error
    if text.count("[") + text.count("{") > 2048:
        raise PlanError("the plan is nested too deeply")
    try:
        plan = json.loads(text, object_pairs_hook=_no_duplicates, parse_constant=_no_constants)
    except PlanError:
        raise
    except (ValueError, RecursionError) as error:
        raise PlanError(f"the plan is not JSON: {error}") from error
    if not isinstance(plan, dict):
        raise PlanError("the plan is not a JSON object")
    _depth(plan)
    return plan


CAPS_KEYS = ("modes", "data_pools", "boot", "encryption", "home_encryption", "swap_encryption",
             "usages",
             "not_offered", "filesystems", "layouts")
MAX_CAPS = 64 * 1024


def check_capabilities(text: str) -> Optional[dict]:
    """What an install command printed for --capabilities, kept when it is
    a JSON object in the shape of os_layouts with at least one layout;
    keys of another shape are left out.  None when it cannot be used."""
    if len(text) > MAX_CAPS:
        return None
    try:
        caps = json.loads(text)
    except ValueError:
        return None
    if not isinstance(caps, dict):
        return None
    try:
        _depth(caps)
    except PlanError:
        return None
    if not _caps_layouts(caps):
        return None
    return {k: caps[k] for k in CAPS_KEYS if k in caps}


CAPS_SECONDS = 10
CAPS_ENV = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C"}


def _trusted(st, uid: int, kind) -> bool:
    """A file or directory no one but its owner may change, owned by root,
    or (for a caller that is not root) by the caller."""
    if not kind(st.st_mode) or st.st_mode & 0o022:
        return False
    return st.st_uid == 0 or (uid != 0 and st.st_uid == uid)


def trusted_command(command: str) -> bool:
    """The install command may run: an absolute path to a regular file, not
    a symbolic link, executable, in a directory that is not one either;
    both owned by root and writable by their owner only.  A caller that is
    not root (the live user runs the probe) may also run its own file."""
    import os
    import stat
    if not command.startswith("/") or "\0" in command:
        return False
    uid = os.geteuid()
    try:
        st = os.lstat(command)
        dst = os.lstat(os.path.dirname(command) or "/")
    except OSError:
        return False
    return (_trusted(st, uid, stat.S_ISREG) and _trusted(dst, uid, stat.S_ISDIR)
            and os.access(command, os.X_OK))


def _read_bounded(proc, deadline: float):
    """Read proc's stdout until EOF, the deadline or MAX_CAPS + 1 bytes;
    (bytes read, True when it ended on its own with status 0)."""
    import os
    import selectors
    import subprocess
    import time
    out = b""
    sel = selectors.DefaultSelector()
    sel.register(proc.stdout, selectors.EVENT_READ)
    try:
        while len(out) <= MAX_CAPS:
            left = deadline - time.monotonic()
            if left <= 0 or not sel.select(left):
                return out, False
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                break
            out += chunk
        else:
            return out, False
    finally:
        sel.close()
    try:
        return out, proc.wait(max(0.0, deadline - time.monotonic())) == 0
    except subprocess.TimeoutExpired:
        return out, False


def run_capabilities(command: str, seconds: float = CAPS_SECONDS) -> str:
    """What "<command> --capabilities" prints: run without a shell, in a
    minimal environment and a process group of its own, at most `seconds`
    long and MAX_CAPS + 1 bytes read.  "" when it fails, is too slow (its
    group is killed) or prints too much."""
    import os
    import signal
    import subprocess
    import time
    # Checked right before it runs (the shell's check is a pre-filter).
    if not trusted_command(command):
        return ""
    try:
        proc = subprocess.Popen([command, "--capabilities"], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                env=dict(CAPS_ENV), close_fds=True, start_new_session=True)
    except OSError:
        return ""
    try:
        out, done = _read_bounded(proc, time.monotonic() + seconds)
    finally:
        if proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                pass
            proc.wait()
        proc.stdout.close()
    if not done or len(out) > MAX_CAPS:
        return ""
    return out.decode("utf-8", "replace")


def main(argv: List[str]) -> int:
    """--check-capabilities [COMMAND]: what COMMAND --capabilities prints
    (run here, bounded), else stdin, checked; the usable object on stdout."""
    import sys
    if not argv or argv[0] != "--check-capabilities" or len(argv) > 2:
        sys.stderr.write("usage: diskplan.py --check-capabilities [COMMAND] (< JSON)\n")
        return 2
    if len(argv) == 2:
        text = run_capabilities(argv[1])
    else:
        text = sys.stdin.read(MAX_CAPS + 1)
    caps = check_capabilities(text)
    if caps is None:
        return 1
    print(json.dumps(caps, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    import sys as _sys
    _sys.exit(main(_sys.argv[1:]))
