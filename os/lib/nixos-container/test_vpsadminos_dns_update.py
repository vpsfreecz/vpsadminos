import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SOURCE = Path(__file__).with_name("vpsadminos-dns-update.py")


def load_helper():
    spec = importlib.util.spec_from_file_location(
        "vpsadminos_dns_update",
        SOURCE,
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DnsUpdateTest(unittest.TestCase):
    def setUp(self):
        self.helper = load_helper()
        self.tmpdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tmpdir.name)
        self.run = self.root / "run"
        self.systemd = self.run / "systemd"
        self.run.mkdir()
        self.systemd.mkdir()

        self.helper.RUNTIME_PARENT = str(self.run)
        self.helper.RESOLVED_PARENT = str(self.systemd)
        self.helper.RESOLVCONF = "/test/resolvconf"
        self.helper.SYSTEMCTL = "/test/systemctl"
        self.payload = (
            b"nameserver 192.0.2.53\n"
            b"nameserver 2001:db8::53\n"
            b"options edns0\n"
        )

    def tearDown(self):
        self.tmpdir.cleanup()

    def runtime_file(self):
        return self.run / "vpsadminos" / "resolv.conf"

    def resolved_file(self):
        return (
            self.systemd
            / "resolved.conf.d"
            / "50-vpsadminos.conf"
        )

    def test_validate_payload_accepts_ordered_ipv4_and_ipv6(self):
        self.assertEqual(
            self.helper.validate_payload(self.payload),
            ["192.0.2.53", "2001:db8::53"],
        )

    def test_validate_payload_rejects_untrusted_grammar(self):
        invalid = [
            b"",
            b"nameserver 192.0.2.53",
            b"nameserver resolver.example\noptions edns0\n",
            b"nameserver 192.0.2.53 extra\noptions edns0\n",
            b"nameserver 192.0.2.53\nsearch example\noptions edns0\n",
            b"nameserver 192.0.2.53\r\noptions edns0\n",
            b"nameserver fe80::1%eth0\noptions edns0\n",
            b"options edns0\n",
            b"x" * (self.helper.MAX_PAYLOAD_BYTES + 1),
        ]

        for payload in invalid:
            with self.subTest(payload=payload):
                with self.assertRaises(self.helper.ResolverInputError):
                    self.helper.validate_payload(payload)

    def test_openresolv_applies_exact_exclusive_entry(self):
        self.helper.BACKEND = "openresolv"

        with mock.patch.object(self.helper.subprocess, "run") as run:
            self.helper.apply(self.payload)

        self.assertEqual(self.runtime_file().read_bytes(), self.payload)
        run.assert_called_once_with(
            [
                "/test/resolvconf",
                "-x",
                "-m",
                "0",
                "-a",
                "vpsadminos",
            ],
            input=self.payload,
            check=True,
        )

    def test_resolved_applies_exact_dropin_and_preserves_input(self):
        self.helper.BACKEND = "resolved"

        with mock.patch.object(self.helper.subprocess, "run") as run:
            self.helper.apply(self.payload)

        self.assertEqual(self.runtime_file().read_bytes(), self.payload)
        self.assertEqual(
            self.resolved_file().read_text(),
            "[Resolve]\n"
            "DNS=192.0.2.53 2001:db8::53\n"
            "FallbackDNS=\n",
        )
        run.assert_called_once_with(
            [
                "/test/systemctl",
                "reload-or-restart",
                "systemd-resolved.service",
            ],
            check=True,
        )

    def test_openresolv_clear_removes_only_managed_runtime_state(self):
        self.helper.BACKEND = "openresolv"
        self.runtime_file().parent.mkdir()
        self.runtime_file().write_bytes(self.payload)
        unrelated = self.runtime_file().parent / "unrelated"
        unrelated.write_text("keep")

        with mock.patch.object(self.helper.subprocess, "run") as run:
            self.helper.clear()

        self.assertFalse(self.runtime_file().exists())
        self.assertEqual(unrelated.read_text(), "keep")
        run.assert_called_once_with(
            ["/test/resolvconf", "-f", "-d", "vpsadminos"],
            check=True,
        )

    def test_resolved_clear_removes_only_managed_dropin_and_input(self):
        self.helper.BACKEND = "resolved"
        self.runtime_file().parent.mkdir()
        self.runtime_file().write_bytes(self.payload)
        self.resolved_file().parent.mkdir()
        self.resolved_file().write_text("[Resolve]\nDNS=192.0.2.53\n")
        unrelated = self.resolved_file().parent / "unrelated.conf"
        unrelated.write_text("[Resolve]\n")

        with mock.patch.object(self.helper.subprocess, "run") as run:
            self.helper.clear()

        self.assertFalse(self.runtime_file().exists())
        self.assertFalse(self.resolved_file().exists())
        self.assertEqual(unrelated.read_text(), "[Resolve]\n")
        run.assert_called_once()

    def test_clear_does_not_create_missing_managed_directories(self):
        for backend in ("openresolv", "resolved"):
            with self.subTest(backend=backend):
                self.helper.BACKEND = backend

                with mock.patch.object(self.helper.subprocess, "run"):
                    self.helper.clear()

                self.assertFalse(self.runtime_file().parent.exists())
                self.assertFalse(self.resolved_file().parent.exists())

    def test_apply_refuses_symlinked_runtime_directory(self):
        self.helper.BACKEND = "openresolv"
        outside = self.root / "outside"
        outside.mkdir()
        os.symlink(outside, self.run / "vpsadminos")

        with mock.patch.object(self.helper.subprocess, "run") as run:
            with self.assertRaises(OSError):
                self.helper.apply(self.payload)

        self.assertEqual(list(outside.iterdir()), [])
        run.assert_not_called()

    def test_apply_refuses_symlinked_runtime_target(self):
        self.helper.BACKEND = "openresolv"
        managed = self.run / "vpsadminos"
        managed.mkdir()
        outside = self.root / "outside"
        outside.write_text("untouched")
        os.symlink(outside, managed / "resolv.conf")

        with mock.patch.object(self.helper.subprocess, "run") as run:
            with self.assertRaises(OSError):
                self.helper.apply(self.payload)

        self.assertEqual(outside.read_text(), "untouched")
        run.assert_not_called()

    def test_apply_refuses_precreated_temporary_path(self):
        self.helper.BACKEND = "openresolv"
        managed = self.run / "vpsadminos"
        managed.mkdir()
        temporary = managed / f".resolv.conf.{os.getpid()}.deadbeef"
        temporary.write_text("attacker")

        with (
            mock.patch.object(
                self.helper.secrets,
                "token_hex",
                return_value="deadbeef",
            ),
            mock.patch.object(self.helper.subprocess, "run") as run,
        ):
            with self.assertRaises(FileExistsError):
                self.helper.apply(self.payload)

        self.assertEqual(temporary.read_text(), "attacker")
        run.assert_not_called()

    def test_backend_failure_is_reported_and_leaves_retryable_input(self):
        self.helper.BACKEND = "openresolv"
        failure = subprocess.CalledProcessError(1, ["/test/resolvconf"])

        with mock.patch.object(
            self.helper.subprocess,
            "run",
            side_effect=failure,
        ):
            with self.assertRaises(subprocess.CalledProcessError):
                self.helper.apply(self.payload)

        self.assertEqual(self.runtime_file().read_bytes(), self.payload)

    def test_clear_backend_failure_cannot_reapply_stale_runtime_input(self):
        self.helper.BACKEND = "openresolv"
        self.runtime_file().parent.mkdir()
        self.runtime_file().write_bytes(self.payload)
        failure = subprocess.CalledProcessError(1, ["/test/resolvconf"])

        with mock.patch.object(
            self.helper.subprocess,
            "run",
            side_effect=failure,
        ):
            with self.assertRaises(subprocess.CalledProcessError):
                self.helper.clear()

        self.assertFalse(self.runtime_file().exists())


if __name__ == "__main__":
    unittest.main()
