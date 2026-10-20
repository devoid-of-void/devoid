#!/usr/bin/env python3
"""Non-destructive checks: installer functions run only with mocked machine operations."""
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import unittest
import uuid

INSTALLER = Path(__file__).resolve().parents[1] / "devoid-alternative.sh"
SOURCE = INSTALLER.read_text()


def bash(code, **kwargs):
    return subprocess.run(
        ["bash", "-c", 'source "$1"\n' + code, "test", str(INSTALLER)],
        text=True, capture_output=True, **kwargs,
    )


class InstallerTests(unittest.TestCase):
    def test_sourcing_does_not_install(self):
        result = bash("printf loaded")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "loaded")

    def test_help_has_no_side_effects(self):
        result = subprocess.run(["bash", str(INSTALLER), "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("ERASES", result.stdout)

    def test_unknown_command_is_rejected(self):
        result = bash("main not-a-command")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown command", result.stderr)

    def test_pk_is_last(self):
        result = bash('''
require_setup_mode() { :; }
stage() { :; }
efi-updatevar() { printf '%s\n' "$*"; }
enroll_secure_boot
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        writes = result.stdout.splitlines()
        self.assertEqual([line.split()[-1] for line in writes], ["db", "db", "KEK", "PK"])
        self.assertTrue(writes[1].startswith("-a -e -f "))

    def test_failed_append_prevents_pk(self):
        result = bash('''
install_traps
require_setup_mode() { :; }
stage() { :; }
efi-updatevar() {
    printf '%s\n' "$*"
    if [[ $1 == -a ]]; then return 42; fi
}
enroll_secure_boot
''')
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(len(result.stdout.splitlines()), 2)
        self.assertNotIn(" PK", result.stdout)

    def test_setup_mode_failure_prevents_all_writes(self):
        result = bash('''
require_setup_mode() { return 9; }
stage() { :; }
efi-updatevar() { echo SHOULD-NOT-RUN; }
enroll_secure_boot
''')
        self.assertEqual(result.returncode, 9)
        self.assertEqual(result.stdout, "")

    def test_cleanup_order_and_exit_status(self):
        result = bash('''
install_traps
target_mounted=1
root_open=1
securityfs_mounted=1
sync() { echo sync; }
umount() { printf 'umount %s\n' "$*"; }
cryptsetup() { printf 'cryptsetup %s\n' "$*"; }
exit 37
''')
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "sync", "umount -R /mnt/target", "cryptsetup close devoid-root",
            "umount /sys/kernel/security",
        ])

    def test_cleanup_failure_is_not_success(self):
        result = bash('''
install_traps
target_mounted=1
sync() { :; }
umount() { return 12; }
exit 0
''')
        self.assertNotEqual(result.returncode, 0)

    def test_no_host_resources_released_by_target_cleanup(self):
        result = bash('''
install_traps
umount() { echo SHOULD-NOT-RUN; }
cryptsetup() { echo SHOULD-NOT-RUN; }
exit 0
''')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_error_report_does_not_print_command_secrets(self):
        result = bash('''
install_traps
phase=signing
secret_command() { return 7; }
secret_command super-secret-pin
''')
        self.assertEqual(result.returncode, 7)
        self.assertIn("signing", result.stderr)
        self.assertNotIn("super-secret-pin", result.stderr)

    def test_generated_shell_scripts_parse(self):
        # Render the real heredocs, without executing their destination writes.
        pattern = re.compile(r"<<('?)(SCRIPT|EOF)\1\n(.*?)\n\2\n", re.S)
        scripts = 0
        for match in pattern.finditer(SOURCE):
            quote, marker, body = match.groups()
            if not body.startswith(("#!/", "# Sourced")):
                continue
            render = subprocess.run(
                ["bash", "-c", f"cat <<{quote}{marker}{quote}\n{body}\n{marker}\n"],
                text=True, capture_output=True,
                env={**os.environ, "EFI_GLOBAL": "test-guid", "target_luks_uuid": "test-uuid"},
            )
            self.assertEqual(render.returncode, 0, render.stderr)
            check = subprocess.run(["bash", "-n"], input=render.stdout, text=True, capture_output=True)
            self.assertEqual(check.returncode, 0, check.stderr)
            scripts += 1
        self.assertEqual(scripts, 7)

    @unittest.skipUnless(shutil.which("yq"), "requires Debian/kislyuk yq")
    def test_driver_filter_excludes_applications_other_pcrs_and_sha1(self):
        filter_text = re.search(r"yq -r '(.*?)' \"\$work/tpm-eventlog.yaml\"", SOURCE, re.S)[1]
        # JSON is valid YAML; the actual yq executable performs the selection.
        import json
        def event(kind, pcr, digests):
            return {"EventType": kind, "PCRIndex": pcr, "Digests": digests}
        def digest(algorithm, value):
            return {"AlgorithmId": algorithm, "Digest": value}
        fixture = {"events": [
            event("EV_EFI_BOOT_SERVICES_DRIVER", 2, [digest("sha1", "c"*40), digest("sha256", "a"*64)]),
            event("EV_EFI_RUNTIME_SERVICES_DRIVER", 2, [digest("sha256", "b"*64)]),
            event("EV_EFI_BOOT_SERVICES_APPLICATION", 4, [digest("sha256", "c"*64)]),
            event("EV_EFI_BOOT_SERVICES_DRIVER", 0, [digest("sha256", "d"*64)]),
            event("EV_SEPARATOR", 2, [digest("sha256", "e"*64)]),
        ]}
        result = subprocess.run(["yq", "-r", filter_text], input=json.dumps(fixture), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["a"*64, "b"*64])

    @unittest.skipUnless(shutil.which("sbsiglist") and shutil.which("xxd"), "requires sbsiglist and xxd")
    def test_real_sbsiglist_packages_raw_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            digest = bytes.fromhex("a1" * 32)
            converted = subprocess.run(["xxd", "-r", "-p"], input=digest.hex().encode(), capture_output=True, check=True)
            (root / "hash").write_bytes(converted.stdout)
            owner = uuid.UUID("f772d71e-1d25-4fdc-85a6-fc43c265223c")
            subprocess.run(["sbsiglist", "--owner", str(owner), "--type", "sha256",
                            "--output", str(root / "hash.esl"), str(root / "hash")], check=True, capture_output=True)
            esl = (root / "hash.esl").read_bytes()
            self.assertEqual(uuid.UUID(bytes_le=esl[:16]), uuid.UUID("c1c41626-504c-4092-aca9-41f936934328"))
            self.assertEqual(struct.unpack("<III", esl[16:28]), (76, 0, 48))
            self.assertEqual(esl[28:44], owner.bytes_le)
            self.assertEqual(esl[44:], digest)


if __name__ == "__main__":
    unittest.main(verbosity=2)
