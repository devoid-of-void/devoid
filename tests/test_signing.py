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

    def test_backend_container_transport(self):
        block = SOURCE.split('local -a l_hidraw_binds=() l_card_access=()\n', 1)[1].split('\tfor l_hidraw', 1)[0]
        for backend in ['token2-openpgp', 'yubikey-piv']:
            r = subprocess.run(['bash', '-eu', '-c', 'l_card_access=()\n'+block+'\nprintf "%s\\n" "${l_card_access[@]}"'],
                               env=dict(self.env, l_signing_backend=backend), capture_output=True, text=True, check=True)
            if backend == 'token2-openpgp':
                self.assertEqual(r.stdout.strip(), '--property=DeviceAllow=char-usb_device rw')
            else:
                self.assertEqual(r.stdout.strip(), '--bind=/run/pcscd/pcscd.comm')

    def test_card_probe_failure_stops_before_disk_and_restores_host(self):
        self.check_card_probe(42)

    def test_card_probe_success_releases_agent_and_restores_host(self):
        self.check_card_probe(0)

    def check_card_probe(self, status):
        block = SOURCE.split('#region Check Token2 direct CCID access before destructive operations\n', 1)[1].split('\t#endregion', 1)[0]
        cleanup = 'cleanup()\n{' + SOURCE.split('cleanup()\n{', 1)[1].split('\n#endregion', 1)[0]
        self.script('gpg', 'printf "probe\\n" >> "$LOG"\nexit "${PROBE_STATUS}"')
        self.script('gpgconf', 'printf "agent-release\\n" >> "$LOG"')
        self.script('systemctl', 'printf "systemctl %s\\n" "$*" >> "$LOG"')
        script = ('set -euo pipefail\n'+cleanup+\
                  '\nl_root_opened=false; l_target_mounted=false; l_card_probe_dir=""\n' +
                  'l_pcsc_stopped=true; l_pcsc_restore_units=(pcscd.socket)\n' +
                  'trap cleanup EXIT\n'+block+'\nprintf "disk-phase\\n" >> "$LOG"\n')
        r = subprocess.run(['bash', '-c', script],
                           env=dict(self.env, TMPDIR=str(self.root), PROBE_STATUS=str(status),
                                    l_signing_backend='token2-openpgp'), capture_output=True, text=True)
        self.assertEqual(r.returncode, status, r.stderr)
        log = (self.root/'calls').read_text().splitlines()
        self.assertEqual('disk-phase' in log, status == 0)
        self.assertEqual(log.count('agent-release'), 1)
        self.assertEqual(log[-1], 'systemctl start pcscd.socket')
        self.assertFalse(list(self.root.glob('tmp.*')))

    def test_target_direct_ccid_configuration(self):
        block = SOURCE.split('# Use the same direct CCID path as the tested Token2 setup.\n', 1)[1].split("\t\tprintf 'pinentry-program", 1)[0]
        self.script('install', 'exit 0')
        gnupg = self.root / 'gnupg'
        gnupg.mkdir()
        (gnupg/'scdaemon.conf').write_text('disable-ccid\n')
        rule = self.root/'token2.rules'
        subprocess.run(['bash', '-eu', '-c', block], env=dict(self.env,
                       SIGNING_GNUPGHOME=str(gnupg), TOKEN2_USB_ID='349e:0014',
                       TOKEN2_UDEV_RULE=str(rule)), check=True)
        active = [line for line in (gnupg/'scdaemon.conf').read_text().splitlines()
                  if line.strip() and not line.startswith('#')]
        self.assertEqual(active, [])
        self.assertIn('ATTR{idVendor}=="349e", ATTR{idProduct}=="0014"', rule.read_text())
        self.assertIn('ENV{PCSCLITE_IGNORE}="1"', rule.read_text())


if __name__ == '__main__':
    unittest.main()
