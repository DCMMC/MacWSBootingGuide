"""Production defaults, diagnostic inventory and transport-config regressions."""

from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

import audit_runtime_switches as audit

ROOT = audit.ROOT


class RuntimeGateInventory(unittest.TestCase):
    def test_discovers_multiline_macro_variable_and_objc_consumers(self):
        source = r'''
// getenv("MACWS_COMMENT_ONLY")
const char *flag = "/tmp/macws_variable_gate";
const char *split = getenv(
    "MACWS_SPLIT_" "ENV");
if (access(flag, F_OK) == 0) run();
MACWS_DEFINE_STARTUP_FLAG(test_gate, "/tmp/macws_macro_gate")
if ([files fileExistsAtPath:@"/tmp/com.macwsguide.test"]) run();
environment[@"MACWS_CHILD_CONTRACT"] = @"1";
'''
        env, flags = audit.discovered_switches({Path('test.m'): source})
        self.assertEqual(env, {'MACWS_SPLIT_ENV', 'MACWS_CHILD_CONTRACT'})
        self.assertEqual(flags, {'/tmp/macws_variable_gate',
                                '/tmp/macws_macro_gate',
                                '/tmp/com.macwsguide.test'})

    def test_shell_config_and_presence_gate_are_included(self):
        source = '''
GATE="$ROOTFS/private/tmp/macws_test_gate"
if [ -e "$GATE" ]; then work; fi
device="${MACWS_TEST_DEVICE:-localhost}"
echo "$MACWS_LOCAL_OUTPUT"
'''
        env, flags = audit.discovered_switches({Path('test.sh'): source})
        self.assertEqual(env, {'MACWS_TEST_DEVICE'})
        self.assertEqual(flags, {'/private/tmp/macws_test_gate'})

    def test_all_file_flags_are_debug_or_obsolete_and_cleanup_is_complete(self):
        manifest = audit.load_manifest()
        for (kind, name), (production, _, _) in manifest.items():
            if kind == 'flag':
                self.assertIn(production, {'off', 'transient'}, name)
        expected = audit.diagnostic_cleanup_script(manifest)
        self.assertEqual(audit.CLEANUP_HELPER.read_text(), expected)
        result = subprocess.run(['bash', '-c',
                                 'source "$1"; macws_diagnostic_flag_paths',
                                 'cleanup-test', str(audit.CLEANUP_HELPER)],
                                check=True, capture_output=True, text=True)
        self.assertEqual(set(result.stdout.splitlines()),
                         {name for kind, name in manifest if kind == 'flag'})
        self.assertNotIn('/tmp/macws_audio_ring', result.stdout)
        self.assertNotIn('/tmp/macws_capture_done', result.stdout)
        self.assertNotIn('/tmp/macws_final_composite.state', result.stdout)

    def test_cleanup_generator_rejects_broad_or_persistent_targets(self):
        for path in ('/tmp/*', '/var/mobile/macws_debug', '/tmp/../var', '/tmp/'):
            with self.subTest(path=path):
                with self.assertRaises(ValueError):
                    audit.diagnostic_cleanup_script({('flag', path):
                        ('off', 'diagnostic', 'test')})

    def test_obsolete_production_files_have_no_consumers(self):
        files = {ROOT / path: (ROOT / path).read_text() for path in
                 ('libmachook/mac_hooks.m', 'libmachook/Metal_hooks.x',
                  'macwshostd/main.m')}
        _, flags = audit.discovered_switches(files)
        for name in ('macws_kcmd_fix', 'macws_kcmd_wrapped_fix',
                     'macws_cancel_completion', 'macws_owned_scanout',
                     'macws_final_composite', 'macws_vnc_share', 'ws_headless'):
            self.assertNotIn('/tmp/' + name, flags)
        self.assertNotIn('getenv("MACWS_AGX_NATIVE")',
                         files[ROOT / 'libmachook/Metal_hooks.x'])

    def test_audio_is_not_an_environment_opt_in(self):
        bridge = (ROOT / 'libmachook/AudioRenderBridge.m').read_text()
        self.assertNotIn('getenv("MACWS_AUDIO_RENDER_BRIDGE")', bridge)
        with (ROOT / 'misc/com.macwsguide.vscode.plist').open('rb') as stream:
            job = plistlib.load(stream)
        self.assertNotIn('MACWS_AUDIO_RENDER_BRIDGE',
                         job.get('EnvironmentVariables', {}))

    def test_native_video_production_policies_do_not_require_opt_in(self):
        hooks = (ROOT / 'libmachook/mac_hooks.m').read_text()
        metal = (ROOT / 'libmachook/Metal_hooks.x').read_text()
        self.assertIn('MacWSProductionDefaultEnabled(getenv("MACWS_CHROMIUM_COMPOSITE_OVERLAYS"))', hooks)
        self.assertEqual(metal.count('MacWSProductionDefaultEnabled(getenv("MACWS_SDR_SCANOUT"))'), 2)
        self.assertIn('MacWSDiagnosticSwitchEnabled(getenv("MACWS_PIN_FALLBACK"))', hooks)
        for path in list((ROOT / 'layout').rglob('*.plist')) + list((ROOT / 'misc').glob('com.macwsguide.*.plist')):
            with path.open('rb') as stream:
                job = plistlib.load(stream)
            self.assertNotIn('MACWS_PIN_FALLBACK', job.get('EnvironmentVariables', {}), str(path))

    @unittest.skipUnless(shutil.which('clang'), 'C compiler required')
    def test_compiled_clean_environment_production_default(self):
        fixture = r'''
#include "macws_production_policy.h"
#include <assert.h>
#include <stdlib.h>
int main(void) {
    unsetenv("MACWS_POLICY_TEST");
    assert(MacWSProductionDefaultEnabled(getenv("MACWS_POLICY_TEST")));
    setenv("MACWS_POLICY_TEST", "1", 1);
    assert(MacWSProductionDefaultEnabled(getenv("MACWS_POLICY_TEST")));
    setenv("MACWS_POLICY_TEST", "0", 1);
    assert(!MacWSProductionDefaultEnabled(getenv("MACWS_POLICY_TEST")));
    unsetenv("MACWS_POLICY_TEST");
    assert(MacWSProductionDefaultEnabled(getenv("MACWS_POLICY_TEST")));
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'production-policy-test'
            subprocess.run(['clang', '-x', 'c', '-', '-O2', '-I',
                            str(ROOT / 'include'), '-o', str(binary)],
                           input=fixture, text=True, capture_output=True,
                           check=True)
            subprocess.run([str(binary)], check=True)

    def test_vnc_choice_updates_job_environment_without_flag_files(self):
        script = (ROOT / 'layout/usr/macOS/bin/macos_gui.sh').read_text()
        body = script.split('"$WINDOWSERVER_PLIST" "$WANT_VNC" <<\'PY\'', 1)[1]
        body = body.split('\n', 1)[1].split('\nPY\n', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'windowserver.plist'
            path.write_bytes(plistlib.dumps({'Label': 'WindowServer',
                'EnvironmentVariables': {'CA_VSYNC_OFF': '1'}}))
            for choice in ('0', '1', '0'):
                subprocess.run([sys.executable, '-', str(path), choice],
                               input=body, text=True, capture_output=True,
                               check=True)
                job = plistlib.loads(path.read_bytes())
                self.assertEqual(job['EnvironmentVariables']['MACWS_VNC_SHARE'], choice)
                self.assertEqual(job['EnvironmentVariables']['CA_VSYNC_OFF'], '1')
                self.assertEqual(list(Path(directory).iterdir()), [path])


if __name__ == '__main__':
    unittest.main()
