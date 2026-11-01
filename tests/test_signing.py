"""Exercise generated signing helpers without tokens, mounts or disk operations."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'devoid.sh').read_text()


def heredoc(destination):
    pattern = r'cat <<- EOF > ' + re.escape(destination) + r'\n(.*?)\n\tEOF'
    return re.search(pattern, SOURCE, re.S).group(1)


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        LOG=str(self.root / 'calls'))

    def script(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\nset -eu\n' + body)
        path.chmod(0o755)
        return path

    def render(self, backend, destination='"$SIGNING_EXEC"'):
        variables = dict(l_signing_backend=backend, SIGNING_OPENSSL_CONF=str(self.root/'openssl.cnf'),
                         g_p11_module='/test/module.so', SIGNING_GNUPGHOME=str(self.root/'gnupg'),
                         SIGNING_P11_CONFIG=str(self.root/'pkcs11'), SIGNING_EXEC=str(self.bin/'signing-exec'),
                         PIV_PIN_KEY_NAME='devoid:piv-pin')
        # Replace only the fixed installed helper pathname for this isolated test.
        template = heredoc(destination).replace('/etc/kernel/scripts/piv_pin_helper.sh', str(self.bin/'pin'))
        result = subprocess.run(['bash', '-eu', '-c', 'cat <<- EOF\n'+template+'\nEOF'],
                                env=dict(self.env, **variables), capture_output=True, text=True, check=True)
        path = self.bin / ('signing-exec' if destination == '"$SIGNING_EXEC"' else 'helper')
        path.write_text(result.stdout)
        path.chmod(0o755)
        subprocess.run(['bash', '-n', str(path)], check=True)
        return path

    def probe(self):
        return self.script('probe', '''printf '%s\\n' "$OPENSSL_CONF" "$PKCS11_PROVIDER_MODULE" "${GNUPGHOME-unset}" "${PKCSPIN-unset}" "${KBUILD_SIGN_PIN-unset}" "$@"
exit "${PROBE_STATUS:-0}"
''')

    def mock_namespace(self):
        self.script('unshare', '''printf 'unshare\\n' >> "$LOG"
[[ $1 == --mount && $2 == --propagation && $3 == private && $4 == -- ]]
shift 4
exec "$@"
''')
        self.script('mount', '''printf 'mount %s\\n' "$*" >> "$LOG"
exit "${MOUNT_STATUS:-0}"
''')

    def test_piv_environment_arguments_and_exit_status(self):
        self.script('pin', "printf 'test-pin'")
        wrapper = self.render('yubikey-piv')
        r = subprocess.run([str(wrapper), str(self.probe()), 'a b', '$(not-a-command)', ''],
                           env=dict(self.env, PROBE_STATUS='23'), capture_output=True, text=True)
        self.assertEqual(r.returncode, 23)
        self.assertEqual(r.stdout.splitlines()[-5:], ['test-pin', 'test-pin', 'a b', '$(not-a-command)', ''])
        self.assertFalse((self.root/'calls').exists())

    def test_openpgp_namespace_and_no_piv_pin(self):
        self.mock_namespace()
        self.script('pin', 'exit 99')
        wrapper = self.render('token2-openpgp')
        r = subprocess.run([str(wrapper), str(self.probe()), 'a b'],
                           env=dict(self.env, PKCSPIN='wrong', KBUILD_SIGN_PIN='wrong'),
                           capture_output=True, text=True, check=True)
        self.assertEqual(r.stdout.splitlines()[2:], [str(self.root/'gnupg'), 'unset', 'unset', 'a b'])
        calls = (self.root/'calls').read_text().splitlines()
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[0], 'unshare')
        self.assertTrue(calls[1].endswith(' /etc/pkcs11'))
        self.assertTrue(calls[2].endswith(' /usr/share/p11-kit/modules'))

    def test_namespace_failure_never_runs_signer(self):
        self.mock_namespace()
        wrapper = self.render('token2-openpgp')
        r = subprocess.run([str(wrapper), str(self.probe())], env=dict(self.env, MOUNT_STATUS='31'),
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 31)
        self.assertEqual(r.stdout, '')

    def test_pin_failure_never_runs_signer(self):
        self.script('pin', 'exit 29')
        wrapper = self.render('yubikey-piv')
        r = subprocess.run([str(wrapper), str(self.probe())], env=self.env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 29)
        self.assertEqual(r.stdout, '')

    def test_generated_hooks_parse(self):
        for dest in ['/etc/dkms/sign_helper.sh', '/etc/kernel/postinst.d/90-kernel-install',
                     '/etc/kernel/scripts/piv_pin_helper.sh']:
            with self.subTest(dest=dest):
                self.render('yubikey-piv', dest)

    def test_uri_rejects_ambiguous_and_shell_injection(self):
        lines = '\n'.join(line.strip() for line in SOURCE.splitlines()
                          if line.strip().startswith('[[ $l_signing_private_key_uri'))
        for uri, valid in [('pkcs11:token=T;object=Scute;type=private', True), ('', False),
                           ('pkcs11:a\npkcs11:b', False), ('pkcs11:$HOME', False),
                           ('pkcs11:`id`', False), ('pkcs11:"', False), ('pkcs11:\\', False)]:
            with self.subTest(uri=uri):
                r = subprocess.run(['bash', '-eu', '-c', lines], env=dict(self.env, l_signing_private_key_uri=uri))
                self.assertEqual(r.returncode == 0, valid)

    def test_host_backend_selection_precedes_partitioning(self):
        self.assertLess(SOURCE.index('l_signing_backend=$(dialog'), SOURCE.index('sgdisk --zap-all'))
        self.assertIn('-- /devoid.sh target "$l_physical_root_partition" "$l_signing_backend"', SOURCE)


if __name__ == '__main__':
    unittest.main()
