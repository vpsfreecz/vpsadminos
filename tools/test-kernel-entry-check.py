"""Exercise the CLI on synthetic Git trees and a staged index (requires Nix)."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CHECKER = Path(__file__).with_name("kernel-entry-check.py").resolve()
CATALOG = Path("os/packages/linux/available-kernels.nix")
ENTRY = 'dateAdded = "2024-02-29"; rev = "rev"; sha256 = "hash"; zfs = { rev = "rev"; sha256 = "hash"; };'
CATALOG_TEXT = '''{ lib }:
let
  entry = import ./entry.nix;
in {
  stableKernelVersion = "6.12.10";
  unstableKernelVersion = "6.12.10";
  kernels."6.12.10" = entry;
}
'''


class CheckTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="test-kernel-entry-")
        self.addCleanup(directory.cleanup)
        self.repo = Path(directory.name)
        self.git("init", "--quiet")
        self.git("config", "user.name", "Metadata fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        (self.repo / CATALOG.parent).mkdir(parents=True)
        self.write(CATALOG, CATALOG_TEXT)
        self.entry = CATALOG.with_name("entry.nix")
        self.write(self.entry, f"{{ {ENTRY} }}")
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True).strip()

    def write(self, path, text):
        (self.repo / path).write_text(text, encoding="utf-8")

    def commit(self):
        self.git("add", "--all")
        # Build local fixture commits without touching the project index or hooks.
        tree = self.git("write-tree")
        parents = ["-p", self.base] if hasattr(self, "base") else []
        return self.git("commit-tree", tree, *parents, "-m", "test snapshot")

    def check(self, *snapshot, base=None, day="2024-03-30", error=None):
        result = subprocess.run(
            [sys.executable, CHECKER, "check", "--as-of", day, "--base", base or self.base, *snapshot],
            cwd=self.repo, capture_output=True, text=True, check=False,
        )
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertIn(error, result.stderr)

    def test_docs_only_candidate_and_inclusive_calendar_day(self):
        self.write(Path("README.md"), "docs only\n")
        tree = self.commit()
        for day in ("2024-02-29", "2024-03-30", "2024-03-31"):
            with self.subTest(day=day):
                self.check("--tree", tree, day=day)

    def test_new_key_on_candidate_tree(self):
        for fields, error in [
            (ENTRY.replace('dateAdded = "2024-02-29"; ', ''), "missing field(s): dateAdded"),
            (ENTRY.replace('"2024-02-29"', '"2023-02-29"'), "Gregorian date"),
            (ENTRY.replace('"2024-02-29"', '"2024-04-31"'), "Gregorian date"),
            (ENTRY.replace('"2024-02-29"', '"2024-2-29"'), "Gregorian date"),
            (ENTRY.replace('"2024-02-29"', '"2024-02-２９"'), "Gregorian date"),
            (ENTRY.replace('"2024-02-29"', '"0000-01-01"'), "Gregorian date"),
            (ENTRY.replace('"2024-02-29"', 'null'), "Gregorian date"),
            (ENTRY.replace('"2024-02-29"', '"2024-04-01"'), "later than the evaluation date"),
            (ENTRY + ' keepUntil = "2024-02-28";', "before dateAdded"),
            (ENTRY + ' keepUntil = null;', "Gregorian date"),
            (ENTRY + ' keepUntill = "2024-05-29";', "unknown field(s): keepUntill"),
            (ENTRY + ' keepUntil = "2024-05-29";', None),
        ]:
            with self.subTest(fields=fields):
                text = CATALOG_TEXT.replace('  kernels."6.12.10" = entry;',
                                            f'  kernels."6.12.10" = entry;\n  kernels."6.12.11" = {{ {fields} }};')
                self.write(CATALOG, text)
                self.check("--tree", self.commit(), error=error)

    def test_staged_companion_wins_over_unstaged_content(self):
        self.write(self.entry, f"{{ {ENTRY} keepUntil = null; }}")
        self.git("add", self.entry)
        self.write(self.entry, f"{{ {ENTRY} }}")
        self.check("--index", error="keepUntil must be a Gregorian date")
        self.git("add", self.entry)
        self.write(self.entry, "throw \"unstaged content must not be read\"")
        self.check("--index")

    def test_selector_and_immutable_date(self):
        self.write(CATALOG, CATALOG_TEXT.replace('unstableKernelVersion = "6.12.10"',
                                                'unstableKernelVersion = "6.12.11"'))
        self.check("--tree", self.commit(), error="unstableKernelVersion must select")
        self.write(CATALOG, CATALOG_TEXT)
        self.write(self.entry, f"{{ {ENTRY.replace('2024-02-29', '2024-02-28')} }}")
        self.check("--tree", self.commit(), error="dateAdded cannot change")

    def test_companion_rename_repin_retirement_and_restoration(self):
        self.git("mv", self.entry, self.entry.with_name("new-name.nix"))
        text = CATALOG_TEXT.replace('./entry.nix', './new-name.nix')
        self.write(CATALOG, text)
        repinned = ENTRY.replace('rev = "rev"', 'rev = "new-revision"', 1)
        self.write(self.entry.with_name("new-name.nix"), f"{{ {repinned} }}")
        self.check("--tree", self.commit())
        self.write(CATALOG, text.replace("6.12.10", "6.12.11"))
        self.base = self.commit()
        self.write(CATALOG, text.replace('  kernels."6.12.10" = entry;',
                                         '  kernels."6.12.10" = entry;\n  kernels."6.12.11" = entry;'))
        self.check("--tree", self.commit())

    def test_only_regular_version_files_are_catalog_records(self):
        self.write(CATALOG, CHECKER.parents[1].joinpath(CATALOG).read_text())
        records = CATALOG.with_name("catalog")
        (self.repo / records).mkdir()
        (self.repo / self.entry).unlink()
        for key in ("6.12.118", "6.18.49"):
            self.write(records / f"{key}.nix", f"{{ lib }}: {{ {ENTRY} }}")
        self.check("--tree", self.commit())
        self.write(records / "2024-02-29.nix", f"{{ lib }}: {{ {ENTRY} }}")
        self.check("--tree", self.commit(), error="Invalid kernel catalog record")
        (self.repo / records / "2024-02-29.nix").unlink()
        (self.repo / records / "6.12.10.nix").symlink_to("6.12.118.nix")
        self.check("--tree", self.commit(), error="Invalid kernel catalog record")

    def test_missing_tree_and_eval_error_fail_closed(self):
        self.check("--tree", "a" * 40, error="kernel entry check:")
        self.write(self.entry, 'throw "bad companion"')
        self.check("--tree", self.commit(), error="bad companion")


if __name__ == "__main__":
    unittest.main()
