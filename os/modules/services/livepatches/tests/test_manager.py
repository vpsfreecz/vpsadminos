#!/usr/bin/env python3

import json
import shutil
import subprocess
import sys
import unittest
from pathlib import Path


RUNTIME_SHELL = Path(sys.argv[1])
MANAGER = Path(sys.argv[2])
TEST_ROOT = Path(sys.argv[3])
KERNEL_IMAGE = Path(sys.argv[4])
KERNEL_NOTES = Path(sys.argv[5])
MODULE_NAMES = json.loads(Path(sys.argv[6]).read_text(encoding="utf-8"))
ROOT_ONLY_MANAGER = Path(sys.argv[7])
REPLACE_REQUESTED_MANAGER = Path(sys.argv[8])
WRONG_IDENTITY_MANAGER = Path(sys.argv[9])
MISSING_ARTIFACT_MANAGER = Path(sys.argv[10])
WRONG_MANIFEST_MANAGER = Path(sys.argv[11])
WRONG_HASH_MANAGER = Path(sys.argv[12])
MALFORMED_INSPECTION_MANAGER = Path(sys.argv[13])
MALFORMED_CLOSURE_MANAGER = Path(sys.argv[14])
UNREADABLE_INSPECTION_MANAGER = Path(sys.argv[15])
UNREADABLE_CLOSURE_MANAGER = Path(sys.argv[16])
UNREADABLE_HASH_MANAGER = Path(sys.argv[17])
NATIVE_RELEASE = "6.12.113"


class StackManagerTest(unittest.TestCase):
    def setUp(self):
        shutil.rmtree(TEST_ROOT, ignore_errors=True)
        (TEST_ROOT / "control").mkdir(parents=True)
        (TEST_ROOT / "run/booted-system").mkdir(parents=True)
        (TEST_ROOT / "run/current-system").mkdir(parents=True)
        self.booted_store_tree.mkdir(parents=True)
        self.current_store_tree.mkdir(parents=True)
        (TEST_ROOT / "sys/kernel/livepatch").mkdir(parents=True)
        (TEST_ROOT / "sys/kernel").mkdir(parents=True, exist_ok=True)
        (TEST_ROOT / "sys/module").mkdir(parents=True)
        (TEST_ROOT / "run/booted-system/kernel").symlink_to(KERNEL_IMAGE)
        (TEST_ROOT / "run/booted-system/kernel-modules").symlink_to(
            self.booted_store_tree.parents[2]
        )
        (TEST_ROOT / "run/current-system/kernel-modules").symlink_to(
            self.current_store_tree.parents[2]
        )
        shutil.copyfile(KERNEL_NOTES, TEST_ROOT / "sys/kernel/notes")
        self.write_uname(NATIVE_RELEASE)
        self.set_scenario("stable")

    @property
    def booted_store_tree(self):
        return TEST_ROOT / "nix/store/booted-modules-a/lib/modules/6.12.113"

    @property
    def current_store_tree(self):
        return TEST_ROOT / "nix/store/current-modules-a/lib/modules/6.12.113"

    @property
    def uname_release(self):
        return (TEST_ROOT / "control/uname").read_text(encoding="utf-8").strip()

    def module_name(self, ordinal):
        return MODULE_NAMES[ordinal - 1]

    def patch_dir(self, ordinal):
        return TEST_ROOT / "sys/kernel/livepatch" / self.module_name(ordinal)

    def sys_module(self, ordinal):
        return TEST_ROOT / "sys/module" / self.module_name(ordinal)

    def marker(self, ordinal):
        return (
            TEST_ROOT
            / "run/vpsadminos/livepatches"
            / f"{self.module_name(ordinal)}.applied-at"
        )

    def release_link(self, ordinal):
        return TEST_ROOT / f"lib/modules/{NATIVE_RELEASE}.{ordinal}"

    def point_booted_kernel(self, target):
        booted_kernel = TEST_ROOT / "run/booted-system/kernel"
        booted_kernel.unlink()
        booted_kernel.symlink_to(target)

    def assert_owned_link(self, ordinal):
        link = self.release_link(ordinal)
        self.assertTrue(link.is_symlink())
        self.assertEqual(
            str(self.booted_store_tree),
            link.readlink().as_posix(),
        )

    def set_scenario(self, scenario):
        (TEST_ROOT / "control/scenario").write_text(
            f"{scenario}\n", encoding="utf-8"
        )

    def write_uname(self, release):
        (TEST_ROOT / "control/uname").write_text(
            f"{release}\n", encoding="utf-8"
        )

    def control_value(self, name):
        path = TEST_ROOT / "control" / name
        return path.read_text(encoding="utf-8").strip() if path.exists() else ""

    def run_manager(self, *arguments, expected=0, manager=MANAGER):
        result = subprocess.run(
            [RUNTIME_SHELL, manager, *arguments],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertEqual(
            expected,
            result.returncode,
            msg=f"stdout={result.stdout!r}\nstderr={result.stderr!r}",
        )
        return result

    def assert_prefix(self, tip):
        self.assertEqual(
            NATIVE_RELEASE if tip == 0 else f"{NATIVE_RELEASE}.{tip}",
            self.uname_release,
        )
        for ordinal in range(1, 4):
            expected = ordinal <= tip
            self.assertEqual(expected, self.patch_dir(ordinal).is_dir())
            self.assertEqual(expected, self.sys_module(ordinal).is_dir())
            self.assertEqual(expected, self.marker(ordinal).is_file())
            self.assertEqual(expected, self.release_link(ordinal).is_symlink())

    def assert_status_state(self, ordinal, state, *, expected=0, manager=MANAGER):
        result = self.run_manager("status", expected=expected, manager=manager)
        rows = [
            line
            for line in result.stdout.splitlines()
            if f"module={self.module_name(ordinal)} " in line
        ]
        self.assertEqual(
            1,
            len(rows),
            msg=f"expected one inventory row for ordinal {ordinal}: {result.stdout!r}",
        )
        self.assertIn("configured=yes present=yes ", rows[0])
        self.assertIn(f"state={state}", rows[0])
        return result

    def assert_status_states(self, states, *, expected=0, manager=MANAGER):
        result = self.run_manager("status", expected=expected, manager=manager)
        rows = {}
        for line in result.stdout.splitlines():
            fields = dict(field.split("=", 1) for field in line.split())
            if fields.get("configured") != "yes":
                continue
            ordinal = int(fields["ordinal"])
            self.assertNotIn(ordinal, rows)
            rows[ordinal] = fields

        self.assertEqual(set(states), set(rows), msg=result.stdout)
        for ordinal, state in states.items():
            self.assertEqual(state, rows[ordinal]["state"], msg=result.stdout)
        return result

    def assert_inventory_collection_error(self, diagnostic, *, manager=MANAGER):
        status = self.assert_status_state(
            1, "partial/inconsistent", expected=1, manager=manager
        )
        listing = self.run_manager("list", expected=1, manager=manager)
        self.assertEqual(status.stdout, listing.stdout)
        for result in (status, listing):
            self.assertIn(diagnostic, result.stderr)
            self.assertIn("inventory collection failed", result.stderr)

    def load_all(self):
        self.set_scenario("stable")
        self.run_manager("load")
        self.assert_prefix(3)

    def test_exact_command_arity_and_canonical_ordinals(self):
        for arguments in (
            (),
            ("load", "0"),
            ("load", "+1"),
            ("load", "01"),
            ("load", "6.12.113.1"),
            ("load", self.module_name(1)),
            ("load", "4"),
            ("load", "1", "extra"),
            ("unload", "1", "extra"),
            ("status", "extra"),
            ("unknown",),
        ):
            with self.subTest(arguments=arguments):
                result = self.run_manager(*arguments, expected=1)
                self.assertIn("usage:", result.stderr)
        self.assertEqual("", self.control_value("insmod-order"))
        status = self.run_manager("status")
        self.assertEqual(status.stdout, self.run_manager("list").stdout)
        for ordinal in range(1, 4):
            self.assertIn(
                f"ordinal={ordinal} release={NATIVE_RELEASE}.{ordinal} "
                f"module={self.module_name(ordinal)} configured=yes present=no "
                "enabled=missing transition=missing replace=missing "
                "state=configured-not-loaded",
                status.stdout,
            )

    def test_bare_load_and_unload_are_ordered_and_idempotent(self):
        self.load_all()
        self.assertEqual("123", self.control_value("insmod-order"))
        self.run_manager("load")
        self.assertEqual("123", self.control_value("insmod-order"))

        self.set_scenario("reverse-stable")
        self.run_manager("unload")
        self.assert_prefix(0)
        self.assertEqual("321", self.control_value("disable-order"))
        self.assertEqual("321", self.control_value("rmmod-order"))
        self.run_manager("unload")
        self.assertEqual("321", self.control_value("disable-order"))
        self.assertEqual("321", self.control_value("rmmod-order"))

    def test_active_prefix_is_idempotent_and_replace_state_refuses(self):
        self.run_manager("load", "1")
        marker = self.marker(1).read_text(encoding="utf-8")
        marker_mtime = self.marker(1).stat().st_mtime_ns
        self.assert_owned_link(1)

        (self.patch_dir(1) / "replace").write_text("1\n", encoding="utf-8")
        result = self.run_manager("load", "1", expected=1)
        self.assertIn("replace=1", result.stderr)
        self.assertEqual(marker, self.marker(1).read_text(encoding="utf-8"))
        self.assertEqual(marker_mtime, self.marker(1).stat().st_mtime_ns)
        self.assertEqual("1", self.control_value("insmod-order"))

        (self.patch_dir(1) / "replace").write_text("0\n", encoding="utf-8")
        self.run_manager("load", "1")
        self.assertEqual(marker_mtime, self.marker(1).stat().st_mtime_ns)
        self.assertEqual("1", self.control_value("insmod-order"))

    def test_delayed_convergence_records_markers_only_after_stable(self):
        self.set_scenario("delayed-2")
        self.run_manager("load")
        self.assert_prefix(3)
        self.assertEqual("3", self.control_value("date-count"))

    def test_marker_publication_failure_is_not_reported_active(self):
        self.set_scenario("marker-publication-failure-2")
        result = self.run_manager("load", expected=1)
        self.assertIn("cannot record", result.stderr)
        self.assertTrue(self.marker(1).is_file())
        self.assertFalse(self.marker(2).exists())
        self.assertTrue(self.patch_dir(2).is_dir())
        self.assertTrue(self.sys_module(2).is_dir())
        self.assertEqual("6.12.113.2", self.uname_release)

        status = self.assert_status_state(2, "partial/inconsistent")
        self.assertNotIn(
            f"module={self.module_name(2)} configured=yes present=yes "
            "enabled=1 transition=0 replace=0 state=active",
            status.stdout,
        )
        self.assertEqual(status.stdout, self.run_manager("list").stdout)
        result = self.run_manager("load", expected=1)
        self.assertIn("inconsistent state at ordinal 2", result.stderr)
        self.assertFalse(self.patch_dir(3).exists())

    def test_status_uses_one_whole_stack_release_authority(self):
        self.assert_status_states(
            {
                1: "configured-not-loaded",
                2: "configured-not-loaded",
                3: "configured-not-loaded",
            }
        )

        self.run_manager("load", "1")
        self.assert_status_states(
            {
                1: "active",
                2: "configured-not-loaded",
                3: "configured-not-loaded",
            }
        )
        self.run_manager("load", "2")
        self.assert_status_states(
            {
                1: "active",
                2: "active",
                3: "configured-not-loaded",
            }
        )
        self.run_manager("load", "3")
        self.assert_status_states({1: "active", 2: "active", 3: "active"})

        self.set_scenario("rmmod-failure-3")
        self.run_manager("unload", "3", expected=1)
        self.assert_status_states(
            {1: "active", 2: "active", 3: "disabled-present"}
        )
        self.set_scenario("stable")
        self.run_manager("unload", "3")
        self.assert_status_states(
            {
                1: "active",
                2: "active",
                3: "configured-not-loaded",
            }
        )
        self.set_scenario("reverse-stable")
        self.run_manager("unload")
        self.assert_status_states(
            {
                1: "configured-not-loaded",
                2: "configured-not-loaded",
                3: "configured-not-loaded",
            }
        )

    def test_status_global_release_mismatch_is_one_readable_disagreement(self):
        for tip in range(4):
            with self.subTest(tip=tip):
                self.setUp()
                for ordinal in range(1, tip + 1):
                    self.run_manager("load", str(ordinal))
                self.write_uname(f"{NATIVE_RELEASE}.9")
                result = self.assert_status_states(
                    {
                        ordinal: (
                            "partial/inconsistent"
                            if ordinal <= tip
                            else "configured-not-loaded"
                        )
                        for ordinal in range(1, 4)
                    }
                )
                self.assertEqual(
                    1,
                    result.stderr.count("does not match expected"),
                    msg=result.stderr,
                )

    def test_status_uname_collection_failure_keeps_complete_partial_rows(self):
        self.run_manager("load", "1")
        self.run_manager("load", "2")
        (TEST_ROOT / "control/uname").unlink()
        status = self.assert_status_states(
            {
                1: "partial/inconsistent",
                2: "partial/inconsistent",
                3: "configured-not-loaded",
            },
            expected=1,
        )
        listing = self.run_manager("list", expected=1)
        self.assertEqual(status.stdout, listing.stdout)
        for result in (status, listing):
            self.assertEqual(1, result.stderr.count("cannot read uname release"))
            self.assertIn("inventory collection failed", result.stderr)

    def test_status_does_not_invent_a_tip_for_transition_or_gap(self):
        self.set_scenario("timeout-2")
        self.run_manager("load", expected=1)
        transition = self.assert_status_states(
            {
                1: "active",
                2: "transitioning",
                3: "configured-not-loaded",
            }
        )
        self.assertNotIn("does not match expected", transition.stderr)

        self.setUp()
        self.load_all()
        shutil.rmtree(self.patch_dir(2))
        shutil.rmtree(self.sys_module(2))
        self.marker(2).unlink()
        self.release_link(2).unlink()
        gap = self.assert_status_states(
            {
                1: "active",
                2: "configured-not-loaded",
                3: "partial/inconsistent",
            }
        )
        self.assertNotIn("does not match expected", gap.stderr)

    def test_selective_order_tip_and_completed_removal_rules(self):
        self.run_manager("load", "1")
        self.assert_prefix(1)
        self.run_manager("load", "1")
        self.assertEqual("1", self.control_value("insmod-order"))
        result = self.run_manager("load", "3", expected=1)
        self.assertIn("not the next configured batch", result.stderr)
        self.run_manager("load", "2")
        self.assert_prefix(2)

        result = self.run_manager("unload", "1", expected=1)
        self.assertIn("not the active tip", result.stderr)
        self.run_manager("unload", "3")
        self.assert_prefix(2)
        self.run_manager("load", "3")
        self.set_scenario("reverse-stable")
        self.run_manager("unload", "3")
        self.assert_prefix(2)
        self.run_manager("unload", "3")
        result = self.run_manager("unload", "1", expected=1)
        self.assertIn("not the active tip", result.stderr)
        self.run_manager("unload", "2")
        self.run_manager("unload", "1")
        self.assert_prefix(0)

    def test_bare_load_skips_verified_prefix(self):
        self.run_manager("load", "1")
        self.run_manager("load", "2")
        self.assertEqual("12", self.control_value("insmod-order"))
        self.run_manager("load")
        self.assertEqual("123", self.control_value("insmod-order"))
        self.assert_prefix(3)

    def test_forward_timeout_retains_truthful_prefix_and_partial_tip(self):
        self.set_scenario("timeout-2")
        result = self.run_manager("load", expected=1)
        self.assertIn("did not converge", result.stderr)
        self.assertEqual("12", self.control_value("insmod-order"))
        self.assertTrue(self.marker(1).is_file())
        self.assertFalse(self.marker(2).exists())
        self.assertEqual("6.12.113.1", self.uname_release)
        self.assertEqual("1", (self.patch_dir(2) / "transition").read_text().strip())
        result = self.run_manager("unload", expected=1)
        self.assertIn("cannot unload", result.stderr)
        self.assertEqual("", self.control_value("disable-order"))

    def test_replace_malformed_and_missing_forward_states_refuse_truthfully(self):
        cases = (
            ("replace-2", "replace=1"),
            ("malformed-2", "invalid boolean state"),
            ("missing-state-2", "missing state file"),
        )
        for scenario, expected_text in cases:
            with self.subTest(scenario=scenario):
                self.setUp()
                self.set_scenario(scenario)
                result = self.run_manager("load", expected=1)
                self.assertIn(expected_text, result.stderr)
                self.assertTrue(self.patch_dir(2).is_dir())
                self.assertFalse(self.marker(2).exists())
                self.assert_owned_link(2)
                self.assertEqual("12", self.control_value("insmod-order"))

    def test_insertion_failure_keeps_successful_prefix_without_rollback(self):
        self.set_scenario("insmod-failure-3")
        result = self.run_manager("load", expected=1)
        self.assertIn("FAILED", result.stderr)
        self.assertEqual("123", self.control_value("insmod-order"))
        self.assertTrue(self.marker(1).is_file())
        self.assertTrue(self.marker(2).is_file())
        self.assertFalse(self.marker(3).exists())
        self.assertEqual("", self.control_value("disable-order"))

    def test_reverse_timeout_preserves_tip_and_never_forces_removal(self):
        self.load_all()
        self.set_scenario("reverse-timeout-3")
        result = self.run_manager("unload", expected=1)
        self.assertIn("did not finish reverse transition", result.stderr)
        self.assertTrue(self.patch_dir(3).is_dir())
        self.assertTrue(self.sys_module(3).is_dir())
        self.assertTrue(self.marker(3).is_file())
        self.assertEqual("3", self.control_value("disable-order"))
        self.assertEqual("", self.control_value("rmmod-order"))

    def test_failed_removal_is_visible_and_resumable_by_exact_generation(self):
        self.load_all()
        self.set_scenario("rmmod-failure-3")
        result = self.run_manager("unload", "3", expected=1)
        self.assertIn("removing", result.stderr)
        self.assertFalse(self.patch_dir(3).exists())
        self.assertTrue(self.sys_module(3).is_dir())
        self.assertTrue(self.marker(3).is_file())
        status = self.run_manager("status")
        self.assertIn(
            f"module={self.module_name(3)} configured=yes present=yes "
            "enabled=0 transition=0 replace=0 state=disabled-present",
            status.stdout,
        )
        self.set_scenario("stable")
        self.run_manager("unload", "3")
        self.assert_prefix(2)
        self.assertEqual("3", self.control_value("disable-order"))
        self.assertEqual("33", self.control_value("rmmod-order"))

    def test_unknown_runtime_is_reported_but_never_mutated(self):
        unmanaged = TEST_ROOT / "sys/kernel/livepatch/external_patch"
        unmanaged.mkdir()
        for name, value in (("enabled", "1"), ("transition", "0"), ("replace", "0")):
            (unmanaged / name).write_text(f"{value}\n", encoding="utf-8")

        status = self.run_manager("status")
        self.assertIn(
            "ordinal=unavailable release=unavailable module=external_patch "
            "configured=no present=yes enabled=1 transition=0 replace=0 "
            "state=loaded-not-configured",
            status.stdout,
        )
        result = self.run_manager("load", expected=1)
        self.assertIn("unsupported livepatch external_patch", result.stderr)
        self.assertEqual("", self.control_value("insmod-order"))
        self.assertEqual("", self.control_value("disable-order"))

    def test_generation_rollback_reports_unknown_exact_modules_and_refuses(self):
        self.load_all()
        status = self.run_manager("status", manager=ROOT_ONLY_MANAGER)
        self.assertIn(
            f"module={self.module_name(1)} configured=yes present=yes "
            "enabled=1 transition=0 replace=0 state=active",
            status.stdout,
        )
        for ordinal in (2, 3):
            self.assertIn(
                f"ordinal=unavailable release=unavailable "
                f"module={self.module_name(ordinal)} configured=no present=yes",
                status.stdout,
            )

        for command in ("load", "unload"):
            result = self.run_manager(command, expected=1, manager=ROOT_ONLY_MANAGER)
            self.assertIn("unsupported livepatch", result.stderr)
        self.assertEqual("123", self.control_value("insmod-order"))
        self.assertEqual("", self.control_value("disable-order"))

        self.set_scenario("reverse-stable")
        self.run_manager("unload")
        self.assert_prefix(0)

    def test_rollback_sees_manager_state_after_livepatch_directory_disappears(self):
        self.run_manager("load", "1")
        self.run_manager("load", "2")
        self.set_scenario("rmmod-failure-2")
        self.run_manager("unload", "2", expected=1)
        self.assertFalse(self.patch_dir(2).exists())
        status = self.run_manager("status", manager=ROOT_ONLY_MANAGER)
        self.assertIn(
            f"module={self.module_name(2)} configured=no present=yes "
            "enabled=0 transition=0 replace=0 state=disabled-present",
            status.stdout,
        )
        result = self.run_manager("unload", expected=1, manager=ROOT_ONLY_MANAGER)
        self.assertIn("manager-owned module", result.stderr)
        self.set_scenario("stable")
        self.run_manager("unload", "2")
        self.assert_prefix(1)

    def test_status_returns_partial_inventory_error_for_unreadable_state(self):
        unmanaged = TEST_ROOT / "sys/kernel/livepatch/unreadable_patch"
        unmanaged.mkdir()
        (unmanaged / "enabled").mkdir()
        (unmanaged / "transition").write_text("0\n", encoding="utf-8")
        (unmanaged / "replace").write_text("0\n", encoding="utf-8")
        result = self.run_manager("status", expected=1)
        self.assertIn("module=unreadable_patch", result.stdout)
        self.assertIn("inventory collection failed", result.stderr)

        self.setUp()
        malformed = TEST_ROOT / "sys/kernel/livepatch/malformed_patch"
        malformed.mkdir()
        (malformed / "enabled").write_text("invalid\n", encoding="utf-8")
        (malformed / "transition").write_text("0\n", encoding="utf-8")
        (malformed / "replace").write_text("0\n", encoding="utf-8")
        result = self.run_manager("status", expected=1)
        self.assertIn("module=malformed_patch", result.stdout)
        self.assertIn("inventory collection failed", result.stderr)

    def test_active_inventory_requires_runtime_and_owned_metadata(self):
        cases = (
            ("missing marker", lambda: self.marker(1).unlink(), "applied marker"),
            (
                "malformed marker",
                lambda: (
                    self.marker(1).unlink(),
                    self.marker(1).symlink_to(TEST_ROOT / "control/uname"),
                ),
                "applied marker",
            ),
            (
                "missing sys module",
                lambda: shutil.rmtree(self.sys_module(1)),
                "kernel module",
            ),
            (
                "missing release link",
                lambda: self.release_link(1).unlink(),
                "module-tree path",
            ),
            (
                "wrong release link",
                lambda: (
                    self.release_link(1).unlink(),
                    self.release_link(1).symlink_to(TEST_ROOT / "wrong-module-tree"),
                ),
                "not owned by this batch",
            ),
            (
                "wrong release",
                lambda: self.write_uname(f"{NATIVE_RELEASE}.9"),
                "does not match expected",
            ),
        )
        for label, mutate, diagnostic in cases:
            with self.subTest(label=label):
                self.setUp()
                self.run_manager("load", "1")
                if label == "wrong release link":
                    (TEST_ROOT / "wrong-module-tree").mkdir()
                mutate()
                status = self.assert_status_state(1, "partial/inconsistent")
                self.assertIn(diagnostic, status.stderr)

    def test_active_inventory_requires_configured_artifact_identity(self):
        self.run_manager("load", "1")
        cases = (
            (MISSING_ARTIFACT_MANAGER, "module evidence is incomplete"),
            (WRONG_MANIFEST_MANAGER, "manifest identity mismatch"),
            (WRONG_HASH_MANAGER, "module identity mismatch"),
            (WRONG_IDENTITY_MANAGER, "module identity mismatch"),
        )
        for manager, diagnostic in cases:
            with self.subTest(manager=manager.name):
                status = self.assert_status_state(
                    1, "partial/inconsistent", manager=manager
                )
                self.assertIn(diagnostic, status.stderr)

    def test_inventory_collection_errors_are_nonzero(self):
        self.run_manager("load", "1")
        manager_cases = (
            (MALFORMED_INSPECTION_MANAGER, "cannot read or parse inspection evidence"),
            (MALFORMED_CLOSURE_MANAGER, "cannot read or parse closure evidence"),
            (UNREADABLE_INSPECTION_MANAGER, "cannot read or parse inspection evidence"),
            (UNREADABLE_CLOSURE_MANAGER, "cannot read or parse closure evidence"),
            (UNREADABLE_HASH_MANAGER, "cannot hash configured module"),
        )
        for manager, diagnostic in manager_cases:
            with self.subTest(manager=manager.name):
                self.assert_inventory_collection_error(diagnostic, manager=manager)

        runtime_cases = (
            (
                "malformed nested coverage",
                lambda: (self.patch_dir(1) / "vmlinux/patched").write_text(
                    "invalid\n", encoding="utf-8"
                ),
                "invalid boolean state",
            ),
            (
                "module-tree authority loop",
                lambda: self.replace_with_self_link(
                    TEST_ROOT / "run/booted-system/kernel-modules"
                ),
                "cannot resolve booted module-tree authority",
            ),
            (
                "unreadable uname",
                lambda: (TEST_ROOT / "control/uname").unlink(),
                "cannot read uname release",
            ),
        )
        for label, mutate, diagnostic in runtime_cases:
            with self.subTest(label=label):
                self.setUp()
                self.run_manager("load", "1")
                mutate()
                self.assert_inventory_collection_error(diagnostic)

    def replace_with_self_link(self, path):
        path.unlink()
        path.symlink_to(path)

    def replace_with_directory(self, path):
        path.unlink()
        path.mkdir()

    def test_static_identity_refusals_precede_insertion(self):
        result = self.run_manager(
            "load", "1", expected=1, manager=REPLACE_REQUESTED_MANAGER
        )
        self.assertIn("was not built in additive mode", result.stderr)
        result = self.run_manager("load", "1", expected=1, manager=WRONG_IDENTITY_MANAGER)
        self.assertIn("module identity mismatch", result.stderr)
        self.assertEqual("", self.control_value("insmod-order"))

    def test_boot_image_path_bytes_and_notes_do_not_gate_a_valid_stack(self):
        booted_image = TEST_ROOT / "different-boot-image"
        booted_image.write_bytes(b"different boot image\n")
        self.assertNotEqual(KERNEL_IMAGE, booted_image)
        self.assertNotEqual(KERNEL_IMAGE.read_bytes(), booted_image.read_bytes())
        self.point_booted_kernel(booted_image)

        running_notes = TEST_ROOT / "sys/kernel/notes"
        running_notes.write_text("different boot notes\n", encoding="utf-8")
        self.assertNotEqual(KERNEL_NOTES.read_bytes(), running_notes.read_bytes())

        self.run_manager("load")
        self.assertEqual("123", self.control_value("insmod-order"))
        self.assert_prefix(3)
        self.assert_status_states({1: "active", 2: "active", 3: "active"})

        self.set_scenario("reverse-stable")
        self.run_manager("unload")
        self.assertEqual("321", self.control_value("disable-order"))
        self.assertEqual("321", self.control_value("rmmod-order"))
        self.assert_prefix(0)

    def test_native_and_post_transition_release_checks_refuse(self):
        self.write_uname(f"{NATIVE_RELEASE}.9")
        result = self.run_manager("load", expected=1)
        self.assertIn(f"does not match expected {NATIVE_RELEASE}", result.stderr)
        self.assertEqual("", self.control_value("insmod-order"))

        self.setUp()
        self.set_scenario("wrong-uname-2")
        result = self.run_manager("load", expected=1)
        self.assertIn(f"does not match expected {NATIVE_RELEASE}.2", result.stderr)
        self.assertFalse(self.marker(2).exists())

    def test_missing_coverage_refuses_before_marker_and_next_member(self):
        self.set_scenario("missing-coverage-2")
        result = self.run_manager("load", expected=1)
        self.assertIn("target object vmlinux is not patched", result.stderr)
        self.assertEqual("12", self.control_value("insmod-order"))
        self.assertFalse(self.marker(2).exists())
        self.assertFalse(self.patch_dir(3).exists())

    def test_release_link_collision_refuses_before_insertion(self):
        self.release_link(1).parent.mkdir(parents=True)
        self.release_link(1).write_text("collision\n", encoding="utf-8")
        result = self.run_manager("load", expected=1)
        self.assertIn("inconsistent state", result.stderr)
        self.assertEqual("", self.control_value("insmod-order"))

    def test_release_link_wrong_target_and_booted_tree_retarget_refuse(self):
        wrong = TEST_ROOT / "wrong-module-tree"
        wrong.mkdir()
        self.release_link(1).parent.mkdir(parents=True)
        self.release_link(1).symlink_to(wrong)
        result = self.run_manager("load", expected=1)
        self.assertIn("inconsistent state", result.stderr)
        self.assertEqual("", self.control_value("insmod-order"))

        self.setUp()
        self.run_manager("load", "1")
        replacement = TEST_ROOT / "nix/store/booted-modules-b/lib/modules/6.12.113"
        replacement.mkdir(parents=True)
        booted_link = TEST_ROOT / "run/booted-system/kernel-modules"
        booted_link.unlink()
        booted_link.symlink_to(replacement.parents[2])
        result = self.run_manager("load", "1", expected=1)
        self.assertIn("not owned by this batch", result.stderr)
        self.set_scenario("reverse-stable")
        result = self.run_manager("unload", "1", expected=1)
        self.assertIn("not owned by this batch", result.stderr)
        self.assertEqual("", self.control_value("disable-order"))

    def test_current_generation_retarget_does_not_change_owned_tree(self):
        self.run_manager("load", "1")
        replacement = TEST_ROOT / "nix/store/current-modules-b/lib/modules/6.12.113"
        replacement.mkdir(parents=True)
        current_link = TEST_ROOT / "run/current-system/kernel-modules"
        current_link.unlink()
        current_link.symlink_to(replacement.parents[2])
        self.run_manager("load", "1")
        self.assert_owned_link(1)
        self.set_scenario("reverse-stable")
        self.run_manager("unload", "1")
        self.assert_prefix(0)

    def test_disable_and_changed_link_failures_preserve_active_tip(self):
        self.load_all()
        self.set_scenario("disable-failure-3")
        result = self.run_manager("unload", "3", expected=1)
        self.assertIn("disabling", result.stderr)
        self.assert_prefix(3)
        self.assertEqual("3", self.control_value("disable-order"))
        self.assertEqual("", self.control_value("rmmod-order"))

        self.setUp()
        self.load_all()
        link = self.release_link(3)
        link.unlink()
        wrong = TEST_ROOT / "wrong-module-tree"
        wrong.mkdir()
        link.symlink_to(wrong)
        self.set_scenario("reverse-stable")
        result = self.run_manager("unload", "3", expected=1)
        self.assertIn("not owned by this batch", result.stderr)
        self.assertEqual("", self.control_value("disable-order"))
        self.assertTrue(self.marker(3).is_file())

    def test_interrupted_cleanup_resumes_but_unowned_link_refuses(self):
        self.run_manager("load", "1")
        self.write_uname(NATIVE_RELEASE)
        shutil.rmtree(self.patch_dir(1))
        shutil.rmtree(self.sys_module(1))
        self.run_manager("unload", "1")
        self.assertFalse(self.marker(1).exists())
        self.assertFalse(self.release_link(1).exists())
        self.assertEqual("", self.control_value("disable-order"))
        self.assertEqual("", self.control_value("rmmod-order"))

        self.setUp()
        self.run_manager("load", "1")
        self.write_uname(NATIVE_RELEASE)
        shutil.rmtree(self.patch_dir(1))
        shutil.rmtree(self.sys_module(1))
        link = self.release_link(1)
        link.unlink()
        wrong = TEST_ROOT / "wrong-module-tree"
        wrong.mkdir()
        link.symlink_to(wrong)
        result = self.run_manager("unload", "1", expected=1)
        self.assertIn("not owned by this batch", result.stderr)
        self.assertTrue(self.marker(1).is_file())
        self.assertTrue(link.is_symlink())

    def test_concurrent_aggregate_loads_share_one_lock(self):
        self.set_scenario("serialized")
        first = subprocess.Popen(
            [RUNTIME_SHELL, MANAGER, "load"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        second = subprocess.Popen(
            [RUNTIME_SHELL, MANAGER, "load"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        first_out, first_err = first.communicate()
        second_out, second_err = second.communicate()
        self.assertEqual(0, first.returncode, msg=f"{first_out!r} {first_err!r}")
        self.assertEqual(0, second.returncode, msg=f"{second_out!r} {second_err!r}")
        self.assertEqual("123", self.control_value("insmod-order"))
        self.assert_prefix(3)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
