#!/usr/bin/env python3

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
MODULE_NAME = sys.argv[6]
REPLACE_REQUESTED_MANAGER = Path(sys.argv[7])
WRONG_IDENTITY_MANAGER = Path(sys.argv[8])


class ScalarManagerTest(unittest.TestCase):
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
        (TEST_ROOT / "control/uname").write_text("6.12.113\n", encoding="utf-8")
        self.set_scenario("stable")

    def set_scenario(self, scenario):
        (TEST_ROOT / "control/scenario").write_text(
            f"{scenario}\n", encoding="utf-8"
        )

    def run_manager(self, command="load", expected=0, manager=MANAGER):
        result = subprocess.run(
            [RUNTIME_SHELL, manager, command],
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

    def test_static_module_admission_refusals_precede_insertion(self):
        result = self.run_manager(expected=1, manager=REPLACE_REQUESTED_MANAGER)
        self.assertIn("was not built in additive mode", result.stderr)
        self.assertEqual(0, self.control_count("insmod-count"))
        self.assertFalse(self.release_link.exists())

        result = self.run_manager(expected=1, manager=WRONG_IDENTITY_MANAGER)
        self.assertIn("module identity mismatch", result.stderr)
        self.assertEqual(0, self.control_count("insmod-count"))
        self.assertFalse(self.release_link.exists())

    @property
    def patch_dir(self):
        return TEST_ROOT / "sys/kernel/livepatch" / MODULE_NAME

    @property
    def marker(self):
        return TEST_ROOT / "run/vpsadminos/livepatches" / f"{MODULE_NAME}.applied-at"

    @property
    def release_link(self):
        return TEST_ROOT / "lib/modules/6.12.113.1"

    @property
    def module_tree(self):
        return self.booted_store_tree

    @property
    def booted_store_tree(self):
        return TEST_ROOT / "nix/store/booted-modules-a/lib/modules/6.12.113"

    @property
    def current_store_tree(self):
        return TEST_ROOT / "nix/store/current-modules-a/lib/modules/6.12.113"

    @property
    def sys_module(self):
        return TEST_ROOT / "sys/module" / MODULE_NAME

    @property
    def uname_release(self):
        return (TEST_ROOT / "control/uname").read_text(encoding="utf-8").strip()

    def control_count(self, name):
        path = TEST_ROOT / "control" / name
        return int(path.read_text(encoding="utf-8")) if path.exists() else 0

    def assert_owned_link(self):
        self.assertTrue(self.release_link.is_symlink())
        self.assertEqual(str(self.module_tree), self.release_link.readlink().as_posix())

    def load_successfully(self):
        self.set_scenario("stable")
        self.run_manager()
        self.assertEqual("6.12.113.1", self.uname_release)
        self.assertTrue(self.marker.is_file())
        self.assert_owned_link()

    def test_identity_refusal_precedes_insertion(self):
        wrong_image = TEST_ROOT / "wrong-kernel-image"
        wrong_image.write_text("wrong\n", encoding="utf-8")
        (TEST_ROOT / "run/booted-system/kernel").unlink()
        (TEST_ROOT / "run/booted-system/kernel").symlink_to(wrong_image)
        result = self.run_manager(expected=1)
        self.assertIn("does not match the running boot kernel", result.stderr)
        self.assertFalse((TEST_ROOT / "control/insmod-count").exists())
        self.assertFalse(self.release_link.exists())

        (TEST_ROOT / "run/booted-system/kernel").unlink()
        (TEST_ROOT / "run/booted-system/kernel").symlink_to(KERNEL_IMAGE)
        (TEST_ROOT / "sys/kernel/notes").write_text("wrong\n", encoding="utf-8")
        result = self.run_manager(expected=1)
        self.assertIn("does not match the running boot kernel", result.stderr)
        self.assertFalse((TEST_ROOT / "control/insmod-count").exists())
        self.assertFalse(self.release_link.exists())

    def test_absent_inserted_stable_and_duplicate(self):
        self.run_manager()
        self.assertEqual("1\n", (self.patch_dir / "enabled").read_text())
        self.assertEqual("0\n", (self.patch_dir / "transition").read_text())
        self.assertEqual("0\n", (self.patch_dir / "replace").read_text())
        self.assertTrue(self.marker.exists())
        self.assertEqual("6.12.113.1", self.uname_release)
        self.assert_owned_link()
        marker = self.marker.read_text()
        marker_mtime = self.marker.stat().st_mtime_ns
        self.assertEqual("1\n", (TEST_ROOT / "control/insmod-count").read_text())
        self.assert_owned_link()

        (self.patch_dir / "replace").write_text("1\n", encoding="utf-8")
        result = self.run_manager(expected=1)
        self.assertIn("replace=1", result.stderr)
        self.assertEqual(marker_mtime, self.marker.stat().st_mtime_ns)
        self.assertEqual(1, self.control_count("insmod-count"))

        (self.patch_dir / "replace").write_text("0\n", encoding="utf-8")
        self.run_manager()
        self.assertEqual(marker, self.marker.read_text())
        self.assertEqual(marker_mtime, self.marker.stat().st_mtime_ns)
        self.assertEqual("1\n", (TEST_ROOT / "control/insmod-count").read_text())

    def test_delayed_transition_records_only_after_stable(self):
        self.set_scenario("delayed")
        self.run_manager()
        self.assertEqual("0\n", (self.patch_dir / "transition").read_text())
        self.assertTrue((TEST_ROOT / "control/date-called").exists())
        self.assertTrue(self.marker.exists())
        self.assertEqual("6.12.113.1", self.uname_release)

    def test_timeout_retains_partial_state(self):
        self.set_scenario("timeout")
        result = self.run_manager(expected=1)
        self.assertIn("did not converge", result.stderr)
        self.assertIn("transition=1", result.stderr)
        self.assertEqual("1\n", (self.patch_dir / "transition").read_text())
        self.assertFalse(self.marker.exists())
        self.assertEqual("6.12.113", self.uname_release)
        self.assert_owned_link()
        self.assertEqual(0, self.control_count("disable-count"))

    def test_replace_refusal_retains_state(self):
        self.set_scenario("replace")
        result = self.run_manager(expected=1)
        self.assertIn("replace=1", result.stderr)
        self.assertEqual("1\n", (self.patch_dir / "replace").read_text())
        self.assertFalse(self.marker.exists())
        self.assert_owned_link()

    def test_insertion_failure_does_not_unwind_partial_state(self):
        self.set_scenario("partial-failure")
        result = self.run_manager(expected=1)
        self.assertIn("FAILED", result.stderr)
        self.assertTrue(self.patch_dir.is_dir())
        self.assertEqual("1\n", (self.patch_dir / "transition").read_text())
        self.assertFalse(self.marker.exists())
        self.assert_owned_link()
        self.assertEqual(0, self.control_count("disable-count"))

    def test_malformed_and_missing_sysfs_fail_truthfully(self):
        for scenario, expected_text in (
            ("malformed", "invalid boolean state"),
            ("missing", "missing"),
        ):
            with self.subTest(scenario=scenario):
                self.setUp()
                self.set_scenario(scenario)
                result = self.run_manager(expected=1)
                self.assertIn(expected_text, result.stderr)
                self.assertTrue(self.patch_dir.is_dir())
                self.assertFalse(self.marker.exists())
                self.assert_owned_link()

    def test_missing_target_coverage_fails_before_marker(self):
        self.set_scenario("missing-coverage")
        result = self.run_manager(expected=1)
        self.assertIn("target object vmlinux is not patched", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_wrong_native_or_published_uname_fails_truthfully(self):
        (TEST_ROOT / "control/uname").write_text("6.12.113.9\n", encoding="utf-8")
        result = self.run_manager(expected=1)
        self.assertIn("does not match expected 6.12.113", result.stderr)
        self.assertEqual(0, self.control_count("insmod-count"))
        self.assertFalse(self.release_link.exists())

        self.setUp()
        self.set_scenario("wrong-uname")
        result = self.run_manager(expected=1)
        self.assertIn("does not match expected 6.12.113.1", result.stderr)
        self.assertTrue(self.patch_dir.is_dir())
        self.assert_owned_link()
        self.assertFalse(self.marker.exists())

    def test_boot_identity_is_revalidated_after_transition(self):
        self.set_scenario("boot-change")
        result = self.run_manager(expected=1)
        self.assertIn("does not match the running boot kernel", result.stderr)
        self.assertTrue(self.patch_dir.is_dir())
        self.assert_owned_link()
        self.assertFalse(self.marker.exists())

    def test_unmanaged_module_is_reported_but_never_mutated(self):
        unmanaged = TEST_ROOT / "sys/kernel/livepatch/livepatch_95"
        unmanaged.mkdir()
        (unmanaged / "enabled").write_text("1\n", encoding="utf-8")
        (unmanaged / "transition").write_text("0\n", encoding="utf-8")
        (unmanaged / "replace").write_text("1\n", encoding="utf-8")

        status = self.run_manager(command="status")
        self.assertIn(
            "unmanaged livepatch_95 state enabled=1 transition=0 replace=1",
            status.stderr,
        )

        result = self.run_manager(expected=1)
        self.assertIn("unsupported livepatch livepatch_95", result.stderr)
        self.assertIn("unmanaged livepatch_95", result.stderr)
        self.assertEqual(0, self.control_count("insmod-count"))
        self.assertEqual(0, self.control_count("disable-count"))
        self.assertEqual(0, self.control_count("rmmod-count"))

    def test_release_link_collision_refuses_before_insertion(self):
        self.release_link.parent.mkdir(parents=True)
        self.release_link.write_text("collision\n", encoding="utf-8")
        result = self.run_manager(expected=1)
        self.assertIn("is not the owned symlink", result.stderr)
        self.assertEqual(0, self.control_count("insmod-count"))
        self.assertEqual("collision\n", self.release_link.read_text(encoding="utf-8"))

    def test_release_link_wrong_target_refuses_before_insertion(self):
        wrong = TEST_ROOT / "wrong-module-tree"
        wrong.mkdir()
        self.release_link.parent.mkdir(parents=True)
        self.release_link.symlink_to(wrong)
        result = self.run_manager(expected=1)
        self.assertIn("is not owned by this batch", result.stderr)
        self.assertEqual(0, self.control_count("insmod-count"))

    def test_concurrent_loads_serialize_insertion(self):
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
        self.assertEqual("1\n", (TEST_ROOT / "control/insmod-count").read_text())
        self.assertTrue(self.marker.exists())

    def test_current_generation_retarget_does_not_change_owned_tree(self):
        self.load_successfully()
        replacement = TEST_ROOT / "nix/store/current-modules-b/lib/modules/6.12.113"
        replacement.mkdir(parents=True)
        current_link = TEST_ROOT / "run/current-system/kernel-modules"
        current_link.unlink()
        current_link.symlink_to(replacement.parents[2])

        self.run_manager()
        self.assert_owned_link()
        self.set_scenario("reverse-stable")
        self.run_manager(command="unload")
        self.assertFalse(self.release_link.exists())

    def test_booted_module_tree_retarget_refuses_without_mutation(self):
        self.load_successfully()
        replacement = TEST_ROOT / "nix/store/booted-modules-b/lib/modules/6.12.113"
        replacement.mkdir(parents=True)
        booted_link = TEST_ROOT / "run/booted-system/kernel-modules"
        booted_link.unlink()
        booted_link.symlink_to(replacement.parents[2])

        result = self.run_manager(expected=1)
        self.assertIn("not owned by this batch", result.stderr)
        self.set_scenario("reverse-stable")
        result = self.run_manager(command="unload", expected=1)
        self.assertIn("not owned by this batch", result.stderr)
        self.assertEqual(0, self.control_count("disable-count"))
        self.assertTrue(self.marker.is_file())

    def test_clean_root_unload_restores_native_and_cleans_owned_state(self):
        self.load_successfully()
        self.set_scenario("reverse-stable")
        self.run_manager(command="unload")
        self.assertEqual("6.12.113", self.uname_release)
        self.assertFalse(self.patch_dir.exists())
        self.assertFalse(self.sys_module.exists())
        self.assertFalse(self.marker.exists())
        self.assertFalse(self.release_link.exists())
        self.assertEqual(1, self.control_count("disable-count"))
        self.assertEqual(1, self.control_count("rmmod-count"))

        self.run_manager(command="unload")
        self.assertEqual(1, self.control_count("disable-count"))
        self.assertEqual(1, self.control_count("rmmod-count"))

    def test_reverse_timeout_retains_tip_and_never_forces_removal(self):
        self.load_successfully()
        self.set_scenario("reverse-timeout")
        result = self.run_manager(command="unload", expected=1)
        self.assertIn("did not finish reverse transition", result.stderr)
        self.assertEqual("6.12.113.1", self.uname_release)
        self.assertEqual("0\n", (self.patch_dir / "enabled").read_text())
        self.assertEqual("1\n", (self.patch_dir / "transition").read_text())
        self.assertTrue(self.sys_module.is_dir())
        self.assertTrue(self.marker.is_file())
        self.assert_owned_link()
        self.assertEqual(1, self.control_count("disable-count"))
        self.assertEqual(0, self.control_count("rmmod-count"))

        (TEST_ROOT / "control/uname").write_text("6.12.113\n", encoding="utf-8")
        shutil.rmtree(self.patch_dir)
        self.set_scenario("stable")
        self.run_manager(command="unload")
        self.assertFalse(self.sys_module.exists())
        self.assertFalse(self.marker.exists())
        self.assertFalse(self.release_link.exists())
        self.assertEqual(1, self.control_count("disable-count"))
        self.assertEqual(1, self.control_count("rmmod-count"))

    def test_disable_failure_preserves_published_state(self):
        self.load_successfully()
        self.set_scenario("disable-failure")
        result = self.run_manager(command="unload", expected=1)
        self.assertIn("disabling", result.stderr)
        self.assertEqual("6.12.113.1", self.uname_release)
        self.assertEqual("1\n", (self.patch_dir / "enabled").read_text())
        self.assertEqual("0\n", (self.patch_dir / "transition").read_text())
        self.assertTrue(self.sys_module.is_dir())
        self.assertTrue(self.marker.is_file())
        self.assert_owned_link()
        self.assertEqual(1, self.control_count("disable-count"))
        self.assertEqual(0, self.control_count("rmmod-count"))

    def test_unload_refuses_changed_link_without_disabling(self):
        self.load_successfully()
        self.release_link.unlink()
        wrong = TEST_ROOT / "wrong-module-tree"
        wrong.mkdir()
        self.release_link.symlink_to(wrong)
        self.set_scenario("reverse-stable")
        result = self.run_manager(command="unload", expected=1)
        self.assertIn("is not owned by this batch", result.stderr)
        self.assertEqual(0, self.control_count("disable-count"))
        self.assertTrue(self.marker.is_file())
        self.assertTrue(self.patch_dir.is_dir())

    def test_rmmod_failure_keeps_marker_and_owned_link(self):
        self.load_successfully()
        self.set_scenario("rmmod-failure")
        result = self.run_manager(command="unload", expected=1)
        self.assertIn("removing", result.stderr)
        self.assertEqual("6.12.113", self.uname_release)
        self.assertFalse(self.patch_dir.exists())
        self.assertTrue(self.sys_module.is_dir())
        self.assertTrue(self.marker.is_file())
        self.assert_owned_link()
        self.assertEqual(1, self.control_count("rmmod-count"))

        self.set_scenario("stable")
        self.run_manager(command="unload")
        self.assertFalse(self.sys_module.exists())
        self.assertFalse(self.marker.exists())
        self.assertFalse(self.release_link.exists())
        self.assertEqual(1, self.control_count("disable-count"))
        self.assertEqual(2, self.control_count("rmmod-count"))

    def test_interrupted_post_rmmod_cleanup_is_resumed(self):
        self.load_successfully()
        (TEST_ROOT / "control/uname").write_text("6.12.113\n", encoding="utf-8")
        shutil.rmtree(self.patch_dir)
        shutil.rmtree(self.sys_module)

        self.run_manager(command="unload")
        self.assertFalse(self.marker.exists())
        self.assertFalse(self.release_link.exists())
        self.assertEqual(0, self.control_count("disable-count"))
        self.assertEqual(0, self.control_count("rmmod-count"))

    def test_completed_reverse_with_unowned_link_fails_closed(self):
        self.load_successfully()
        (TEST_ROOT / "control/uname").write_text("6.12.113\n", encoding="utf-8")
        shutil.rmtree(self.patch_dir)
        shutil.rmtree(self.sys_module)
        self.release_link.unlink()
        wrong = TEST_ROOT / "wrong-module-tree"
        wrong.mkdir()
        self.release_link.symlink_to(wrong)

        result = self.run_manager(command="unload", expected=1)
        self.assertIn("is not owned by this batch", result.stderr)
        self.assertTrue(self.marker.is_file())
        self.assertTrue(self.release_link.is_symlink())
        self.assertEqual(0, self.control_count("rmmod-count"))


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
