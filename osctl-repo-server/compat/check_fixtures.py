"""Quick integrity/sanity checks for independently generated native oracles."""

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "osctl-repo-server/testdata/native"


def load(name):
    return json.loads((FIXTURES / f"{name}.json").read_text())


def versions(snapshot, distribution, variant="minimal", vendor="vpsadminos", arch="x86_64"):
    return [i["version"] for i in snapshot["index"]["images"]
            if (i["vendor"], i["variant"], i["arch"], i["distribution"])
            == (vendor, variant, arch, distribution)]


class NativeFixtures(unittest.TestCase):
    def test_provenance_and_exact_bytes(self):
        for name in ("catalog", "gc", "subset", "mixed_failure"):
            oracle = load(name)
            for source, digest in oracle["provenance"]["sources"].items():
                self.assertEqual(hashlib.sha256((ROOT / source).read_bytes()).hexdigest(), digest)
            for phase in ("baseline", "before_gc", "after_gc"):
                snapshot = oracle[phase]
                self.assertEqual(json.loads(snapshot["index_bytes"]), snapshot["index"])
                tuples = [tuple(i[k] for k in ("vendor", "variant", "arch", "distribution", "version"))
                          for i in snapshot["index"]["images"]]
                self.assertEqual(tuples, sorted(tuples))
                for path, payload in snapshot["files"].items():
                    raw = payload["contents"].encode()
                    self.assertEqual(hashlib.sha256(raw).hexdigest(), payload["sha256"], path)
                    self.assertEqual(len(raw), payload["size"], path)

    def test_native_alias_winner_and_stream_only(self):
        state = load("catalog")["after_gc"]
        self.assertEqual(state["aliases"]["v1/vpsadminos/minimal/x86_64/debian/oldstable"], "11")
        self.assertEqual(state["aliases"]["v1/default"], "vpsadminos")
        stream = next(i for i in state["index"]["images"] if i["variant"] == "impermanence")
        self.assertEqual(list(stream["image"]), ["zfs"])

    def test_native_gc_lexical_order_first_match_and_groups(self):
        state = load("gc")["after_gc"]
        self.assertEqual(versions(state, "arch"), ["11", "12", "13", "9"])
        self.assertEqual(versions(state, "arch", variant="full"), ["2", "3", "4", "5"])
        self.assertEqual(versions(state, "arch", arch="aarch64"), ["1"])
        self.assertEqual(versions(state, "arch", vendor="other"), ["1"])
        self.assertIn("26.05", versions(state, "nixos"))
        self.assertEqual(versions(state, "nixos", variant="impermanence"),
                         ["unstable-2", "unstable-3", "unstable-4", "unstable-5"])

    def test_subset_and_mixed_failure_do_not_disable_full_gc(self):
        subset = load("subset")["after_gc"]
        mixed = load("mixed_failure")["after_gc"]
        self.assertEqual(versions(subset, "arch"), ["11", "12", "13", "9"])
        self.assertEqual(versions(subset, "alpine"), ["3.21", "3.22"])
        self.assertEqual(versions(mixed, "arch"), ["11", "12", "13", "9"])
        self.assertEqual(versions(mixed, "centos"), [f"9-stream-{n}" for n in range(1, 5)])
        self.assertEqual(versions(mixed, "debian"), ["12", "13"])


if __name__ == "__main__":
    unittest.main()
