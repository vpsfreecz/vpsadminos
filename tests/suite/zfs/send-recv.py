"""Private deterministic payload and block-pointer checks for send-recv.nix."""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


CANDIDATES = (2048, 2560, 3072)


def random_bytes(seed, size):
    return b"".join(
        hashlib.sha256(f"zfs-send-recv:{seed}:{i}".encode()).digest()
        for i in range((size + 31) // 32)
    )[:size]


def updated(files):
    result = dict(files)
    for prefix in CANDIDATES:
        name = f"nested/partial-{prefix}.bin"
        data = bytearray(result[name])
        data[4096:8192] = random_bytes(f"updated:{prefix}", 4096)
        data[700003:700067] = b"incremental-change".ljust(64, b"!")
        result[name] = bytes(data)
    del result["deleted.txt"]
    result["added.txt"] = b"Added in s1, absent from s0.\n"
    return result


def generate(root):
    files = {}
    for prefix in CANDIDATES:
        files[f"nested/partial-{prefix}.bin"] = b"".join(
            random_bytes(f"{prefix}:{record}", prefix)
            + (b"ZFS-compressed-send:" * 256)[:4096 - prefix]
            for record in range(256)
        )
    files["entropy.bin"] = random_bytes("entropy", 1024 * 1024)
    files["exact.txt"] = b"Independent original bytes for both receive hops.\n"
    files["deleted.txt"] = b"Deleted only from the incremental snapshot.\n"
    files["empty"] = b""
    for snapshot, contents in (("s0", files), ("s1", updated(files))):
        # Compute expectations from constructed buffers before writing any copy.
        manifest = {
            name: {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
            for name, data in sorted(contents.items())
        }
        print(f"{snapshot}: {json.dumps(manifest, sort_keys=True)}")
        root.mkdir(parents=True, exist_ok=True)
        (root / f"{snapshot}.json").write_text(json.dumps(manifest, sort_keys=True))
        for name, data in contents.items():
            path = root / snapshot / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)


def update(root):
    files = {str(p.relative_to(root)): p.read_bytes() for p in root.rglob("*") if p.is_file()}
    for name, data in updated(files).items():
        (root / name).write_bytes(data)
    (root / "deleted.txt").unlink()


def verify(oracle, snapshot, root):
    manifest = json.loads((oracle / f"{snapshot}.json").read_text())
    expected_paths = set(manifest)
    for name in manifest:
        expected_paths.update(str(p) for p in Path(name).parents if str(p) != ".")
    actual = sorted(str(p.relative_to(root)) for p in root.rglob("*"))
    assert actual == sorted(expected_paths), f"{root}: paths {actual}, expected {sorted(expected_paths)}"
    assert not any(p.is_symlink() for p in root.rglob("*")), f"{root}: unexpected symlink"
    for name, expected in manifest.items():
        path = root / name
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        assert path.stat().st_size == expected["size"], (
            f"{path}: size {path.stat().st_size}, expected {expected['size']}; "
            f"SHA256 {digest}, expected {expected['sha256']}"
        )
        assert digest == expected["sha256"], (
            f"{path}: SHA256 {digest}, expected {expected['sha256']}"
        )
        subprocess.run(["cmp", "--", str(oracle / snapshot / name), str(path)], check=True)
    print(f"Verified {root}: {snapshot}, {len(manifest)} paths, sizes, SHA256 and cmp")


def blocks(dataset, path, log):
    obj = path.stat().st_ino
    # Six -b flags select the full blkptr printer, including compression.
    result = subprocess.run(
        ["zdb", "-e", "-p", "/tank/zfs-send-recv/backing", "-dddddd", "-bbbbbb", dataset, str(obj)],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False
    )
    output = result.stdout
    log.write_text(output)
    assert result.returncode == 0, f"zdb failed for {path} ({result.returncode}):\n{output[:12000]}"
    result = {}
    for line in output.splitlines():
        match = re.match(
            r"^\s*([0-9a-f]+)\s+L0\s*(DVA\[.*\[L0 ZFS plain file\] "
            r"\S+ (\S+) .* size=([0-9a-f]+)L/([0-9a-f]+)P\b.*)$", line
        )
        if match:
            result[int(match[1], 16)] = (match[3], int(match[4], 16), int(match[5], 16))
    assert result, f"No ordinary L0 block pointers parsed for {path}:\n{output[:12000]}"
    return result


def trigger(scratch, snapshot, second=False):
    # Match the same file and logical offset, never allocation size or a property.
    for prefix in CANDIDATES:
        relative = f"nested/partial-{prefix}.bin"
        source = blocks(f"ashift-src/source@{snapshot}",
                        Path(f"/mnt/ashift-src/source/.zfs/snapshot/{snapshot}/{relative}"),
                        scratch / f"{snapshot}-{prefix}-source.zdb")
        first = blocks(f"ashift-dst/first@{snapshot}",
                       Path(f"/mnt/ashift-dst/first/.zfs/snapshot/{snapshot}/{relative}"),
                       scratch / f"{snapshot}-{prefix}-first.zdb")
        for offset, (compression, logical, physical) in source.items():
            if (compression == "lz4" and logical == 4096 and physical < logical
                    and first.get(offset) == ("lz4", 4096, 4096)):
                print(f"#12762 trigger {snapshot}: {relative} offset={offset:#x}, "
                      f"source={source[offset]}, first={first[offset]}")
                if second:
                    received = blocks(f"ashift-dst/second@{snapshot}",
                                      Path(f"/mnt/ashift-dst/second/.zfs/snapshot/{snapshot}/{relative}"),
                                      scratch / f"{snapshot}-{prefix}-second.zdb")
                    assert received.get(offset) == ("lz4", 4096, 4096), (
                        f"Second-hop compression metadata lost at {relative}:{offset:#x}: "
                        f"{received.get(offset)}"
                    )
                return
    details = "\n".join(f"{p.name}:\n{p.read_text()[:4000]}" for p in sorted(scratch.glob(f"{snapshot}-*.zdb")))
    raise AssertionError(f"Fixture did not reach compressed psize=lsize=4096; no skip permitted\n{details}")


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    if command == "generate":
        generate(Path(args[0]))
    elif command == "update":
        update(Path(args[0]))
    elif command == "verify":
        verify(Path(args[0]), args[1], Path(args[2]))
    elif command == "trigger":
        trigger(Path(args[0]), args[1], second=len(args) == 3 and args[2] == "second")
    else:
        raise ValueError(command)
