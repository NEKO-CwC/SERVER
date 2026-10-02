import json
import os
from pathlib import Path
import subprocess
import tempfile
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


class AgentFixture(ShellTests):
    def setUp(self):
        super().setUp()
        self.env.update(
            AGENT_PROXY_MODE="env",
            AGENT_PROXY_URL="",
            AGENT_SSH_PASSWORD="",
            AGENT_INSTALL_STATE_DIR=str(self.root / "state"),
            AGENT_BASHRC=str(self.root / "bashrc"),
            CC_SWITCH_CONFIG_DIR=str(self.root / "config"),
            CC_SWITCH_WEBDAV_BASE_URL="https://dav.example.invalid/dav",
            CC_SWITCH_WEBDAV_USERNAME="fixture-user",
            CC_SWITCH_WEBDAV_PASSWORD="fixture-secret-only",
        )
        self.script("bin/curl", '''#!/usr/bin/env python3
import os, pathlib, sys
root = pathlib.Path(os.environ['TEST_ROOT'])
args = sys.argv[1:]
url = next(arg for arg in args if arg.startswith('https://'))
tool = 'cc-switch' if 'cc-switch-cli' in url else ('claude' if 'claude.ai' in url else 'codex')
with (root / 'calls').open('a') as out: out.write('download:' + tool + '\\n')
dest = pathlib.Path(args[args.index('-o') + 1])
dest.write_text('cp "$TEST_ROOT/payload/' + tool + '" "$TEST_ROOT/bin/' + tool + '"\\nchmod +x "$TEST_ROOT/bin/' + tool + '"\\n')
if os.environ.get('TEST_FAIL_DOWNLOAD') == tool: sys.exit(22)
''')
        self.script("payload/cc-switch", '''#!/usr/bin/env python3
import os, pathlib, sys
root = pathlib.Path(os.environ['TEST_ROOT'])
args = sys.argv[1:]
if args == ['--version']:
    print('cc-switch fixture')
    sys.exit(0)
event = ':'.join(args[:3]) if args[:2] == ['config', 'webdav'] else ':'.join(args[:2])
with (root / 'calls').open('a') as out: out.write(event + '\\n')
if os.environ.get('TEST_FAIL_CONFIG') == event:
    print(os.environ['CC_SWITCH_WEBDAV_PASSWORD'])
    sys.exit(1)
if event in ('config:import', 'config:webdav:download'):
    directory = pathlib.Path(os.environ['CC_SWITCH_CONFIG_DIR'])
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'cc-switch.db').write_text('fixture database')
''')
        for tool in ("claude", "codex"):
            self.script(f"payload/{tool}", f"#!/bin/sh\necho '{tool} fixture'\n")

    def run_agent(self, *args, ok=True):
        return self.bash('''source agent/install.sh
# Keep the process, PATH and target files inside this test sandbox.
check_root() { :; }
prepare_process_env() { export PATH="$TEST_ROOT/bin:$PATH"; }
main "$@"
''', *args, ok=ok)

    def calls(self):
        return (self.root / "calls").read_text().splitlines()


class AgentTests(AgentFixture):
    def test_resume_after_late_download_failure(self):
        self.env["TEST_FAIL_DOWNLOAD"] = "codex"
        self.run_agent(ok=False)
        self.assertFalse((self.root / "bin/codex").exists())
        self.assertTrue((self.root / "state/config-success").is_file())
        del self.env["TEST_FAIL_DOWNLOAD"]
        self.run_agent()
        calls = self.calls()
        self.assertEqual(calls.count("download:cc-switch"), 1)
        self.assertEqual(calls.count("download:claude"), 1)
        self.assertEqual(calls.count("download:codex"), 2)
        self.assertEqual(calls.count("config:webdav:download"), 1)
        self.run_agent()
        self.assertEqual(calls, self.calls())
        self.assertEqual((self.root / "bashrc").read_text().count("alias cc="), 1)

    def test_failed_sync_is_retried_and_credentials_stay_in_private_log(self):
        self.env["TEST_FAIL_CONFIG"] = "config:webdav:download"
        failed = self.run_agent(ok=False)
        self.assertNotIn(self.env["CC_SWITCH_WEBDAV_PASSWORD"], failed.stdout + failed.stderr)
        self.assertFalse((self.root / "state/config-success").exists())
        self.assertEqual((self.root / "state/config-last.log").stat().st_mode & 0o777, 0o600)
        del self.env["TEST_FAIL_CONFIG"]
        self.run_agent()
        self.assertEqual(self.calls().count("config:webdav:download"), 2)
        self.assertFalse((self.root / "state/config-last.log").exists())

    def test_refresh_force_source_change_and_missing_database(self):
        self.run_agent()
        self.run_agent("--force")
        self.assertEqual(self.calls().count("download:cc-switch"), 2)
        self.assertEqual(self.calls().count("config:webdav:download"), 1)
        self.run_agent("--refresh-config")
        self.env["CC_SWITCH_WEBDAV_BASE_URL"] = "https://dav2.example.invalid/dav"
        self.run_agent()
        (self.root / "config/cc-switch.db").unlink()
        self.run_agent()
        self.assertEqual(self.calls().count("config:webdav:download"), 4)

    def test_sql_change_and_broken_binary(self):
        sql = self.root / "config.sql"
        sql.write_text("select 1;\n")
        self.run_agent("--sql-file", sql)
        self.run_agent("--sql-file", sql)
        sql.write_text("select 2;\n")
        self.script("bin/claude", "#!/bin/sh\nexit 1\n")
        self.run_agent("--sql-file", sql)
        self.assertEqual(self.calls().count("config:import"), 2)
        self.assertEqual(self.calls().count("download:claude"), 2)
        self.assertNotIn("config:webdav:download", self.calls())

    def test_different_database_directory_requires_import(self):
        self.run_agent()
        other_config = self.root / "other-config"
        other_config.mkdir()
        (other_config / "cc-switch.db").write_text("unrelated database")
        self.env["CC_SWITCH_CONFIG_DIR"] = str(other_config)
        self.run_agent()
        self.assertEqual(self.calls().count("config:webdav:download"), 2)

    def test_missing_env_fails_before_download_and_skip_config_needs_no_secrets(self):
        self.env["CC_SWITCH_WEBDAV_PASSWORD"] = ""
        self.run_agent(ok=False)
        self.assertFalse((self.root / "calls").exists())
        self.run_agent("--skip-config")
        self.assertFalse((self.root / "state/config-success").exists())
        self.run_agent("--skip-config", "--refresh-config", ok=False)

    def test_failed_refresh_invalidates_previous_marker(self):
        self.run_agent()
        self.env["TEST_FAIL_CONFIG"] = "config:webdav:download"
        self.run_agent("--refresh-config", ok=False)
        self.assertFalse((self.root / "state/config-success").exists())
        del self.env["TEST_FAIL_CONFIG"]
        self.run_agent()
        self.assertEqual(self.calls().count("config:webdav:download"), 3)


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


class RepositoryTests(unittest.TestCase):
    def test_shell_syntax(self):
        scripts = list((REPO / "agent").rglob("*.sh")) + list((REPO / "VPS").rglob("*.sh"))
        for script in scripts:
            with self.subTest(script=str(script.relative_to(REPO))):
                result = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
