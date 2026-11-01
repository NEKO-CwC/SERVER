import json
import errno
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import termios
import time
import unittest


REPO = Path(__file__).resolve().parents[1]


class ShellTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="neko-install-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ, TEST_ROOT=str(self.root))

    def script(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)
        return path

    def bash(self, body, *args, ok=True):
        result = subprocess.run(
            ["bash", "-c", 'set -euo pipefail\n' + body, "test", *map(str, args)],
            cwd=REPO, env=self.env, text=True, capture_output=True, timeout=15,
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def bash_tty(self, body, conversation, *args, ok=True):
        master, slave = pty.openpty()
        process = subprocess.Popen(
            ["bash", "-c", 'set -euo pipefail\n' + body, "test", *map(str, args)],
            cwd=REPO, env=self.env, stdin=slave, stdout=slave, stderr=slave,
            start_new_session=True,
        )
        os.close(slave)
        output = bytearray()
        cursor = 0
        deadline = time.monotonic() + 15

        def receive():
            if time.monotonic() >= deadline:
                self.fail("Interactive test exceeded deadline: " + output.decode(errors="replace"))
            if select.select([master], [], [], 0.1)[0]:
                try:
                    output.extend(os.read(master, 65536))
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise

        try:
            for prompt, answer in conversation:
                token = prompt.encode()
                while output.find(token, cursor) < 0:
                    receive()
                    if process.poll() is not None:
                        self.fail("Exited before prompt: " + output.decode(errors="replace"))
                cursor = output.index(token, cursor) + len(token)
                # Send passwords only after read -s has disabled terminal echo.
                if "密码" in prompt or "口令" in prompt:
                    while termios.tcgetattr(master)[3] & termios.ECHO:
                        receive()
                os.write(master, b"\x04" if answer is None else (answer + "\n").encode())
            while process.poll() is None:
                receive()
            receive()
            text = output.decode(errors="replace")
            if ok:
                self.assertEqual(process.returncode, 0, text)
            else:
                self.assertNotEqual(process.returncode, 0, text)
            return text
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=3)
            os.close(master)


class AgentFixture(ShellTests):
    def setUp(self):
        super().setUp()
        self.env.update(
            AGENT_PROXY_MODE="env",
            AGENT_PROXY_URL="",
            AGENT_SSH_PASSWORD="",
            MAGPIE_CONFIG_SOURCE="dav",
            MAGPIE_BACKUP_FILE="",
            AGENT_INSTALL_STATE_DIR=str(self.root / "state"),
            AGENT_BASHRC=str(self.root / "bashrc"),
            XDG_CONFIG_HOME=str(self.root / "config"),
            MAGPIE_WEBDAV_BASE_URL="https://dav.example.invalid/dav/magpie-sync",
            MAGPIE_WEBDAV_USERNAME="fixture-user",
            MAGPIE_WEBDAV_PASSWORD="fixture-secret-only",
            MAGPIE_PASSPHRASE="fixture-encryption-only",
        )
        self.script("bin/curl", '''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['TEST_ROOT'])
args = sys.argv[1:]
url = next(arg for arg in args if arg.startswith('https://'))
tool = 'magpie' if 'usemagpie.ai' in url else ('claude' if 'claude.ai' in url else 'codex')
with (root / 'calls').open('a') as out: out.write('download:' + tool + '\\n')
(root / 'download-env.json').write_text(json.dumps({key: os.environ.get(key) for key in ('http_proxy', 'https_proxy', 'all_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')}))
(root / 'download-secret-env.json').write_text(json.dumps({key: value for key, value in os.environ.items() if key in ('MAGPIE_WEBDAV_PASSWORD', 'MAGPIE_PASSPHRASE', 'WEBDAV_PASSWORD', 'BACKUP_PASSPHRASE')}))
dest = pathlib.Path(args[args.index('-o') + 1])
dest.write_text('cp "$TEST_ROOT/payload/' + tool + '" "$TEST_ROOT/bin/' + tool + '"\\nchmod +x "$TEST_ROOT/bin/' + tool + '"\\n')
if os.environ.get('TEST_FAIL_DOWNLOAD') == tool: sys.exit(22)
''')
        self.script("payload/magpie", '''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['TEST_ROOT'])
args = sys.argv[1:]
if args == ['--version']:
    print('magpie fixture')
    sys.exit(0)
event = 'restore' if args[0] == 'restore' else ':'.join(args[:2])
with (root / 'calls').open('a') as out: out.write(event + '\\n')
secrets = []
if event == 'webdav:on':
    (root / 'dav-args.json').write_text(json.dumps(args))
    secrets = [sys.stdin.readline().rstrip('\\n'), sys.stdin.readline().rstrip('\\n')]
    assert all(secrets), 'Both secrets must arrive on stdin'
    (root / 'dav-stdin.json').write_text(json.dumps(secrets))
if event == 'restore':
    (root / 'backup-path').write_text(args[1])
    secrets = [sys.stdin.readline().rstrip('\\n')]
    assert secrets[0], 'Restore passphrase must arrive on stdin'
    (root / 'backup-stdin.json').write_text(json.dumps(secrets))
if os.environ.get('TEST_FAIL_CONFIG') == event:
    print(' '.join(secrets))
    sys.exit(1)
if event in ('restore', 'webdav:on'):
    assert (root / 'bin/claude').exists() and (root / 'bin/codex').exists(), 'Install agents before restoring their settings'
    if os.environ.get('TEST_MISSING_CONFIG') != '1':
        directory = pathlib.Path(os.environ['XDG_CONFIG_HOME']) / 'magpie'
        directory.mkdir(parents=True, exist_ok=True)
        (directory / 'providers.json').write_text('{"providers":[]}')
''')
        for tool in ("claude", "codex"):
            self.script(f"payload/{tool}", f"#!/bin/sh\necho '{tool} fixture'\n")

    def run_agent(self, *args, ok=True):
        return self.bash('''source agent/install.sh
# Keep the process, PATH and target files inside this test sandbox.
check_root() { :; }
prepare_process_env() { export PATH="$TEST_ROOT/bin:$PATH"; }
main --env "$@"
''', *args, ok=ok)

    def calls(self):
        return (self.root / "calls").read_text().splitlines()


class AgentTests(AgentFixture):
    def test_resume_after_late_download_failure(self):
        self.env["TEST_FAIL_DOWNLOAD"] = "codex"
        self.run_agent(ok=False)
        self.assertFalse((self.root / "bin/codex").exists())
        self.assertFalse((self.root / "state/config-success").exists())
        del self.env["TEST_FAIL_DOWNLOAD"]
        self.run_agent()
        calls = self.calls()
        self.assertEqual(calls.count("download:magpie"), 1)
        self.assertEqual(calls.count("download:claude"), 1)
        self.assertEqual(calls.count("download:codex"), 2)
        self.assertEqual(calls.count("webdav:on"), 1)
        self.run_agent()
        self.assertEqual(calls, self.calls())
        self.assertEqual((self.root / "bashrc").read_text().count("alias cc="), 1)

    def test_failed_sync_is_retried_and_credentials_stay_in_private_log(self):
        self.env["TEST_FAIL_CONFIG"] = "webdav:on"
        failed = self.run_agent(ok=False)
        for key in ("MAGPIE_WEBDAV_PASSWORD", "MAGPIE_PASSPHRASE"):
            self.assertNotIn(self.env[key], failed.stdout + failed.stderr)
        self.assertFalse((self.root / "state/config-success").exists())
        self.assertEqual((self.root / "state/config-last.log").stat().st_mode & 0o777, 0o600)
        self.assertIn("webdav:auto", self.calls())
        del self.env["TEST_FAIL_CONFIG"]
        self.run_agent()
        self.assertEqual(self.calls().count("webdav:on"), 2)
        self.assertFalse((self.root / "state/config-last.log").exists())

    def test_refresh_force_source_change_and_missing_config(self):
        self.run_agent()
        self.run_agent("--force")
        self.assertEqual(self.calls().count("download:magpie"), 2)
        self.assertEqual(self.calls().count("webdav:on"), 1)
        self.run_agent("--refresh-config")
        self.env["MAGPIE_WEBDAV_BASE_URL"] = "https://dav2.example.invalid/dav"
        self.run_agent()
        (self.root / "config/magpie/providers.json").unlink()
        self.run_agent()
        self.assertEqual(self.calls().count("webdav:on"), 4)

    def test_backup_change_and_broken_binary(self):
        backup = self.root / "config.magpie-backup"
        backup.write_text("sealed fixture one")
        self.run_agent("--backup-file", backup)
        self.run_agent("--backup-file", backup)
        backup.write_text("sealed fixture two")
        self.script("bin/claude", "#!/bin/sh\nexit 1\n")
        self.run_agent("--backup-file", backup)
        self.assertEqual(self.calls().count("restore"), 2)
        self.assertEqual(self.calls().count("download:claude"), 2)
        self.assertNotIn("webdav:on", self.calls())

    def test_different_config_directory_requires_import(self):
        self.run_agent()
        other_config = self.root / "other-config/magpie"
        other_config.mkdir(parents=True)
        (other_config / "providers.json").write_text("unrelated config")
        self.env["XDG_CONFIG_HOME"] = str(other_config.parent)
        self.run_agent()
        self.assertEqual(self.calls().count("webdav:on"), 2)

    def test_missing_env_fails_before_download_and_skip_config_needs_no_secrets(self):
        self.env["MAGPIE_WEBDAV_PASSWORD"] = ""
        self.env["MAGPIE_PASSPHRASE"] = ""
        self.run_agent(ok=False)
        self.assertFalse((self.root / "calls").exists())
        self.run_agent("--skip-config")
        self.assertFalse((self.root / "state/config-success").exists())
        self.run_agent("--skip-config", "--refresh-config", ok=False)

    def test_failed_refresh_invalidates_previous_marker(self):
        self.run_agent()
        self.env["TEST_FAIL_CONFIG"] = "webdav:on"
        self.run_agent("--refresh-config", ok=False)
        self.assertFalse((self.root / "state/config-success").exists())
        del self.env["TEST_FAIL_CONFIG"]
        self.run_agent()
        self.assertEqual(self.calls().count("webdav:on"), 3)

    def test_secrets_use_stdin_and_are_not_exported_to_installers(self):
        self.run_agent()
        args = json.loads((self.root / "dav-args.json").read_text())
        secrets = json.loads((self.root / "dav-stdin.json").read_text())
        for key in ("MAGPIE_WEBDAV_PASSWORD", "MAGPIE_PASSPHRASE"):
            self.assertNotIn(self.env[key], args)
            self.assertIn(self.env[key], secrets)
        self.assertEqual(json.loads((self.root / "download-secret-env.json").read_text()), {})
        self.assertEqual((self.root / "state/config-success").stat().st_mode & 0o777, 0o600)

    def test_missing_config_or_library_failure_never_marks_success(self):
        self.env["TEST_MISSING_CONFIG"] = "1"
        self.run_agent(ok=False)
        self.assertFalse((self.root / "state/config-success").exists())
        del self.env["TEST_MISSING_CONFIG"]
        self.env["TEST_FAIL_CONFIG"] = "library:sync"
        self.run_agent(ok=False)
        self.assertFalse((self.root / "state/config-success").exists())

    def test_passphrase_change_resyncs_and_invalid_secrets_fail_before_download(self):
        self.env["MAGPIE_PASSPHRASE"] = self.env["MAGPIE_WEBDAV_PASSWORD"]
        self.run_agent(ok=False)
        self.assertFalse((self.root / "calls").exists())
        self.env["MAGPIE_PASSPHRASE"] = "fixture-first"
        self.run_agent()
        self.env["MAGPIE_PASSPHRASE"] = "fixture-second"
        self.run_agent()
        self.assertEqual(self.calls().count("webdav:on"), 2)
        self.env["MAGPIE_PASSPHRASE"] = "line-one\nline-two"
        self.run_agent(ok=False)
        self.assertEqual(self.calls().count("webdav:on"), 2)


class SingBoxTests(ShellTests):
    def setUp(self):
        super().setUp()
        self.binary = self.script("binary", '''#!/usr/bin/env python3
import json, sys
if sys.argv[1] == 'version': print('sing-box version 1.13.13')
elif sys.argv[1] == 'check':
    with open(sys.argv[sys.argv.index('-c') + 1]) as stream: json.load(stream)
else: sys.exit(1)
''')
        (self.root / "stage").mkdir()
        (self.root / "config").mkdir()
        (self.root / "config/config.json").write_text('{"old":true}')
        (self.root / "source.json").write_text('{"new":true}')
        self.server_setup = '''source VPS/singbox/server/install.sh
TMP_DIR="$TEST_ROOT/stage"
CONFIG_DIR="$TEST_ROOT/config"
CONFIG_FILE="$CONFIG_DIR/config.json"
INSTALL_BIN="$TEST_ROOT/installed/sing-box"
SINGBOX_UNIT="$TEST_ROOT/server.service"
STAGED_BIN="$TEST_ROOT/binary"
CONFIG_URL=""
CONFIG_SOURCE="$TEST_ROOT/source.json"
'''

    def test_server_file_install_and_isolated_unit(self):
        self.bash(self.server_setup + 'stage_config\ninstall_files')
        self.assertEqual(json.loads((self.root / "config/config.json").read_text()), {"new": True})
        self.assertEqual(len(list((self.root / "config").glob("*.bak-*"))), 1)
        self.assertEqual((self.root / "config/config.json").stat().st_mode & 0o777, 0o600)
        unit = (self.root / "server.service").read_text()
        self.assertIn("/usr/local/lib/sing-box-server/sing-box", unit)
        self.assertNotIn("bypass", unit)
        self.assertNotIn("sing-box-client", unit)

    def test_invalid_local_config_preserves_files(self):
        (self.root / "source.json").write_text("invalid-json")
        self.bash(self.server_setup + 'stage_config\ninstall_files', ok=False)
        self.assertEqual((self.root / "config/config.json").read_text(), '{"old":true}')
        self.assertFalse((self.root / "installed").exists())

    def test_failed_remote_download_preserves_files(self):
        self.bash(self.server_setup + '''CONFIG_URL=https://config.example.invalid/private
download_file() { printf 'partial' >"$1"; return 22; }
stage_config
install_files
''', ok=False)
        self.assertEqual((self.root / "config/config.json").read_text(), '{"old":true}')

    def test_server_remote_and_installed_config_reuse(self):
        self.bash(self.server_setup + '''CONFIG_URL=https://config.example.invalid/private
download_file() { cp "$TEST_ROOT/source.json" "$1"; }
stage_config
install_files
CONFIG_URL=""
CONFIG_SOURCE=""
parse_args
resolve_config_source
stage_config
''')
        self.assertEqual((self.root / "stage/config.json").read_text(), '{"new":true}')

    def test_matching_binary_is_reused_without_network(self):
        self.bash(self.server_setup + '''INSTALL_BIN="$TEST_ROOT/binary"
download_file() { echo unexpected-network >&2; return 99; }
stage_singbox amd64
[[ "$STAGED_BIN" == "$INSTALL_BIN" ]]
install_binary
''')

    def test_client_reuses_installed_binary_when_cronet_library_is_present(self):
        self.script("installed/sing-box", "#!/usr/bin/env python3\nimport sys\nprint('sing-box version 1.13.13')\n")
        (self.root / "installed/libcronet.so").write_text("installed-libcronet")
        self.bash('''source VPS/singbox/client/install.sh
SINGBOX_VERSION=1.13.13
TMP_DIR="$TEST_ROOT/stage"
INSTALL_BIN="$TEST_ROOT/installed/sing-box"
download_file() { echo unexpected-network >&2; return 99; }
stage_singbox amd64
[[ "$STAGED_BIN" == "$INSTALL_BIN" ]]
[[ -z "$SINGBOX_LIB_SOURCE" ]]
install_binary
[[ "$(cat "$TEST_ROOT/installed/libcronet.so")" == installed-libcronet ]]
''')

    def test_client_downloads_archive_again_to_add_missing_cronet_library(self):
        self.script("installed/sing-box", "#!/usr/bin/env python3\nimport sys\nprint('sing-box version 1.13.13')\n")
        self.script("stage/sing-box-1.13.13-linux-amd64/sing-box",
                    "#!/usr/bin/env python3\nimport sys\nprint('sing-box version 1.13.13')\n")
        (self.root / "stage/sing-box-1.13.13-linux-amd64/libcronet.so").write_text("downloaded-libcronet")
        result = self.bash('''source VPS/singbox/client/install.sh
SINGBOX_VERSION=1.13.13
TMP_DIR="$TEST_ROOT/stage"
INSTALL_BIN="$TEST_ROOT/installed/sing-box"
download_file() {
  printf 'GET %s\\n' "$2" >>"$TEST_ROOT/requests"
  tar -czf "$1" -C "$TEST_ROOT/stage" sing-box-1.13.13-linux-amd64
}
stage_singbox amd64
[[ "$STAGED_BIN" == "$TEST_ROOT/stage/sing-box-1.13.13-linux-amd64/sing-box" ]]
[[ "$SINGBOX_LIB_SOURCE" == "$TEST_ROOT/stage/sing-box-1.13.13-linux-amd64/libcronet.so" ]]
install_binary
[[ "$(cat "$TEST_ROOT/installed/libcronet.so")" == downloaded-libcronet ]]
[[ "$(stat -c '%a' "$TEST_ROOT/installed/libcronet.so")" == 644 ]]
''')
        self.assertIn("missing libcronet.so", result.stdout)
        self.assertEqual((self.root / "requests").read_text().strip().count("GET"), 1)

    def test_server_reuses_installed_binary_without_the_cronet_library(self):
        self.bash(self.server_setup + '''INSTALL_BIN="$TEST_ROOT/binary"
SINGBOX_LIB_SOURCE=""
download_file() { echo unexpected-network >&2; return 99; }
stage_singbox amd64
[[ "$STAGED_BIN" == "$INSTALL_BIN" ]]
''')

    def test_install_binary_leaves_no_library_when_the_archive_had_none(self):
        (self.root / "old-binary").write_text("old-version")
        self.bash('''source VPS/singbox/client/install.sh
INSTALL_BIN="$TEST_ROOT/installed/sing-box"
STAGED_BIN="$TEST_ROOT/old-binary"
SINGBOX_LIB_SOURCE=""
install_binary
[[ "$(cat "$INSTALL_BIN")" == old-version ]]
[[ ! -e "$TEST_ROOT/installed/libcronet.so" ]]
''')

    def test_install_binary_removes_stale_library_when_the_archive_ships_none(self):
        # Upgrading onto a release whose archive has no library must not leave the old one.
        installed = self.root / "installed"
        installed.mkdir()
        (installed / "libcronet.so").write_text("stale-libcronet")
        (self.root / "new-binary").write_text("new-version")
        self.bash('''source VPS/singbox/client/install.sh
INSTALL_BIN="$TEST_ROOT/installed/sing-box"
STAGED_BIN="$TEST_ROOT/new-binary"
SINGBOX_LIB_SOURCE=""
SINGBOX_FROM_ARCHIVE=1
install_binary
[[ "$(cat "$INSTALL_BIN")" == new-version ]]
[[ ! -e "$TEST_ROOT/installed/libcronet.so" ]]
''')

    def test_reused_install_does_not_touch_the_installed_library(self):
        installed = self.root / "installed"
        installed.mkdir()
        (installed / "libcronet.so").write_text("installed-libcronet")
        self.bash('''source VPS/singbox/client/install.sh
INSTALL_BIN="$TEST_ROOT/installed/sing-box"
STAGED_BIN="$INSTALL_BIN"
SINGBOX_FROM_ARCHIVE=0
install_binary
[[ "$(cat "$TEST_ROOT/installed/libcronet.so")" == installed-libcronet ]]
''')

    def test_legacy_active_service_is_rejected(self):
        self.bash(self.server_setup + '''systemctl() { [[ "$1" == is-active && "$3" == sing-box.service ]]; }
require_legacy_stopped
''', ok=False)

    def test_client_invalid_subscription_preserves_files(self):
        self.bash('''source VPS/singbox/client/install.sh
TMP_DIR="$TEST_ROOT/stage"
CONFIG_FILE="$TEST_ROOT/config/config.json"
download_file() { printf 'invalid' >"$1"; }
stage_config "$TEST_ROOT/binary" https://subscription.example.invalid
''', ok=False)
        self.assertEqual((self.root / "config/config.json").read_text(), '{"old":true}')

    def test_client_reports_old_validator_and_preserves_installation(self):
        old_binary = self.script("old-client", '''#!/usr/bin/env python3
import sys
if sys.argv[1] == 'version': print('sing-box version 1.13.15')
else:
    print('route.default_http_client: json: unknown field "default_http_client"', file=sys.stderr)
    sys.exit(1)
''')
        result = self.bash('''source VPS/singbox/client/install.sh
SINGBOX_VERSION=1.13.15
TMP_DIR="$TEST_ROOT/stage"
CONFIG_FILE="$TEST_ROOT/config/config.json"
INSTALL_BIN="$TEST_ROOT/old-client"
download_file() { printf '{"route":{"default_http_client":"rules"},"http_clients":[{"tag":"rules"}]}' >"$1"; }
stage_config "$INSTALL_BIN" https://subscription.example.invalid
''', ok=False)
        self.assertIn("Validating the downloaded configuration with sing-box version 1.13.15", result.stdout)
        self.assertIn("require sing-box 1.14.0 or newer", result.stderr)
        self.assertIn("SINGBOX_VERSION override", result.stderr)
        self.assertEqual((self.root / "config/config.json").read_text(), '{"old":true}')
        self.assertIn("1.13.15", old_binary.read_text())

    def test_client_generic_validation_failure_does_not_report_version_mismatch(self):
        result = self.bash('''source VPS/singbox/client/install.sh
TMP_DIR="$TEST_ROOT/stage"
download_file() { printf 'invalid' >"$1"; }
stage_config "$TEST_ROOT/binary" https://subscription.example.invalid
''', ok=False)
        self.assertIn("Configuration validation failed", result.stderr)
        self.assertNotIn("require sing-box 1.14.0", result.stderr)


class RepositoryTests(unittest.TestCase):
    def test_shell_syntax(self):
        scripts = (list((REPO / "agent").rglob("*.sh")) + list((REPO / "VPS").rglob("*.sh"))
                   + list((REPO / "lib").rglob("*.sh")) + [REPO / "with-proxy.sh"])
        for script in scripts:
            with self.subTest(script=str(script.relative_to(REPO))):
                result = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
