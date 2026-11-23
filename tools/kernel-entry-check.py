"""Offline validation of a Git snapshot's available-kernels.nix."""

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


CATALOG = "os/packages/linux/available-kernels.nix"
# The exact pre-backfill catalog blob at b86287c105b7. Only the base may
# lack dates, and only when its catalog is this known migration input.
LEGACY_BLOB = "b8947c21a64a3c33d12d3f5b79b7ad069351aeca"

# These are the lib.kernel values used by the catalog. Keep evaluation
# independent of flake inputs and package instantiation.
CATALOG_EXPR = f'''
  import (<catalog-root> + "/{CATALOG}") {{
    lib.kernel = rec {{
      yes = {{ tristate = "y"; optional = false; }};
      no = {{ tristate = "n"; optional = false; }};
      module = {{ tristate = "m"; optional = false; }};
      unset = {{ tristate = null; optional = false; }};
      freeform = value: {{ freeform = value; optional = false; }};
      option = x: x // {{ optional = true; }};
    }};
  }}
'''


GIT_ENV = {**os.environ, "GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1"}


def git(*args):
    return subprocess.check_output(["git", *args], env=GIT_ENV).decode().rstrip("\n")


def unpack_tree(tree, root):
    # Read raw blobs: checkout filters and archive export rules must not change
    # what is checked. Use one cat-file process for all companion files.
    entries = subprocess.check_output(["git", "ls-tree", "-rz", tree], env=GIT_ENV)
    with subprocess.Popen(["git", "cat-file", "--batch"], env=GIT_ENV,
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE) as blobs:
        for row in entries.split(b"\0")[:-1]:
            spec, path = row.split(b"\t", 1)
            mode, kind, oid = spec.split()
            if kind != b"blob":  # submodule contents are not part of this tree
                continue
            name = Path(os.fsdecode(path))
            if name.is_absolute() or ".." in name.parts:
                raise ValueError(f"unsafe Git tree path: {name!r}")
            dest = root / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            blobs.stdin.write(oid + b"\n")
            blobs.stdin.flush()
            header = blobs.stdout.readline().split()
            if len(header) != 3 or header[:2] != [oid, b"blob"]:
                raise ValueError(f"unreadable Git blob for {name!r}")
            size = int(header[2])
            data = blobs.stdout.read(size)
            if len(data) != size or blobs.stdout.read(1) != b"\n":
                raise ValueError(f"truncated Git blob for {name!r}")
            if mode == b"120000":
                dest.symlink_to(os.fsdecode(data))
            else:
                dest.write_bytes(data)
        blobs.stdin.close()
        if blobs.wait():
            raise ValueError("git cat-file failed")


def evaluate(tree):
    with tempfile.TemporaryDirectory(prefix="kernel-entry-") as directory:
        root = Path(directory)
        unpack_tree(tree, root)
        catalog = root / CATALOG
        if catalog.is_symlink() or not catalog.is_file():
            raise ValueError(f"{CATALOG} must be a tracked regular file")

        # A recipe may import companion files in the snapshot. Don't allow it
        # to fetch inputs, read the caller's NIX_PATH, or instantiate a build.
        return json.loads(subprocess.check_output(
            [
                "nix", "--extra-experimental-features", "nix-command", "eval",
                "--json", "--impure", "--offline",
                "--option", "restrict-eval", "true",
                "--option", "allowed-uris", "",
                "--option", "allow-import-from-derivation", "false",
                "-I", f"catalog-root={root}", "--expr", CATALOG_EXPR,
            ],
            env={**os.environ, "NIX_PATH": ""},
        ))


def date(value, label):
    if isinstance(value, str) and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value):
        try:
            return dt.date.fromisoformat(value)
        except ValueError:
            pass
    raise ValueError(f"{label} must be a Gregorian date (YYYY-MM-DD)")


def fields(value, label, required, optional=()):
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an attribute set")
    missing = sorted(set(required) - value.keys())
    extra = sorted(value.keys() - set(required) - set(optional))
    if missing:
        raise ValueError(f"{label}: missing field(s): {', '.join(missing)}")
    if extra:
        raise ValueError(f"{label}: unknown field(s): {', '.join(extra)}")


def check_pins(entry, label):
    for field in ("rev", "sha256"):
        if not isinstance(entry[field], str) or not entry[field]:
            raise ValueError(f"{label}.{field} must be a nonempty string")


def check_patches(patches, label):
    if not isinstance(patches, list) or not all(isinstance(p, str) and p for p in patches):
        raise ValueError(f"{label} must be a list of patch paths")


def check_catalog(catalog, as_of):
    selectors = ("stableKernelVersion", "unstableKernelVersion")
    fields(catalog, "catalog", (*selectors, "kernels"))
    kernels = catalog["kernels"]
    if not isinstance(kernels, dict) or not kernels:
        raise ValueError("kernels must be a nonempty attribute set")
    for selector in selectors:
        key = catalog[selector]
        if not isinstance(key, str) or key not in kernels:
            raise ValueError(f"{selector} must select an existing kernel key")

    dates = {}
    for key, entry in kernels.items():
        if not re.fullmatch(r"(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}", key):
            raise ValueError(f"kernel {key!r}: expected a version key in X.Y.Z form")
        fields(entry, key, ("dateAdded", "rev", "sha256", "zfs"),
               ("keepUntil", "structuredExtraConfig", "features", "postConfigPatches"))
        added = date(entry["dateAdded"], f"{key}.dateAdded")
        if added > as_of:
            raise ValueError(f"{key}.dateAdded is later than the evaluation date")
        if "keepUntil" in entry and date(entry["keepUntil"], f"{key}.keepUntil") < added:
            raise ValueError(f"{key}.keepUntil is before dateAdded")
        dates[key] = added
        check_pins(entry, key)
        zfs = entry["zfs"]
        fields(zfs, f"{key}.zfs", ("rev", "sha256"), ("patches",))
        check_pins(zfs, f"{key}.zfs")
        if "patches" in zfs:
            check_patches(zfs["patches"], f"{key}.zfs.patches")
        if "postConfigPatches" in entry:
            check_patches(entry["postConfigPatches"], f"{key}.postConfigPatches")
        if not isinstance(entry.get("structuredExtraConfig", {}), dict):
            raise ValueError(f"{key}.structuredExtraConfig must be an attribute set")
        features = entry.get("features", {})
        if not isinstance(features, dict) or not all(isinstance(v, bool) for v in features.values()):
            raise ValueError(f"{key}.features must be an attribute set of booleans")
    return dates


def commit_sha(value):
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value):
        raise ValueError("expected a full commit SHA")
    if git("cat-file", "-t", value) != "commit":
        raise ValueError(f"{value} is not a commit")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(required=True)
    check = subcommands.add_parser("check")
    check.add_argument("--as-of", required=True, help="UTC date (YYYY-MM-DD)")
    check.add_argument("--base", required=True, help="base commit SHA")
    candidate = check.add_mutually_exclusive_group(required=True)
    candidate.add_argument("--tree", help="candidate commit SHA")
    candidate.add_argument("--index", action="store_true", help="use the staged index")
    args = parser.parse_args()

    try:
        as_of = date(args.as_of, "--as-of")
        base = commit_sha(args.base)
        if args.tree:
            tree = commit_sha(args.tree)
            git("merge-base", "--is-ancestor", base, tree)
        else:
            tree = git("write-tree")
        current = check_catalog(evaluate(tree), as_of)
        if git("rev-parse", f"{base}:{CATALOG}") != LEGACY_BLOB:
            previous = check_catalog(evaluate(base), as_of)
            for key in sorted(current.keys() & previous.keys()):
                if current[key] != previous[key]:
                    raise ValueError(f"{key}.dateAdded cannot change from {previous[key]} to {current[key]}")
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f"kernel entry check: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
