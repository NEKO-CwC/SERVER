import json
import base64
import shutil
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from test_installers import AgentFixture


class AgentPreflightTests(AgentFixture):
    def test_real_head_request_preserves_escaped_credentials_and_does_not_download(self):
        if not shutil.which("curl"):
            self.skipTest("curl required")
        requests = []
        password = 'special"slash\\password'
        expected = 'Basic ' + base64.b64encode(('fixture-user:' + password).encode()).decode()

        class Handler(BaseHTTPRequestHandler):
            def do_HEAD(self):
                requests.append((self.path, self.headers.get('Authorization')))
                self.send_response(200 if self.headers.get('Authorization') == expected else 401)
                self.end_headers()

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.env['MAGPIE_WEBDAV_BASE_URL'] = f'http://127.0.0.1:{server.server_port}/dav/sync/'
        self.env['MAGPIE_WEBDAV_PASSWORD'] = password
        self.bash('''source agent/install.sh
parse_args --env
collect_configuration
PROXY_MODE=none
proxy_prepare_env
prepare_config
install -d -m 0700 "$STATE_DIR"
preflight_config_source
''')
        self.assertEqual(requests, [('/dav/sync/magpie/magpie.magpie-backup', expected)])

    def test_dav_status_errors_stop_before_install_with_specific_guidance(self):
        for status, message in (("401", "用户名"), ("403", "权限"), ("404", "父目录"), ("503", "反向代理")):
            with self.subTest(status=status):
                self.env["TEST_DAV_HTTP_STATUS"] = status
                result = self.run_agent(ok=False)
                self.assertIn(message, result.stderr)
        self.assertEqual(self.calls(), ["dav:preflight"] * 4)
        self.assertFalse((self.root / "config/magpie/providers.json").exists())

    def test_head_unsupported_continues_to_real_magpie_sync(self):
        self.env["TEST_DAV_HTTP_STATUS"] = "405"
        self.run_agent()
        self.assertIn("webdav:on", self.calls())

    def test_preflight_uses_proxy_and_stdin_credentials_without_passphrase(self):
        self.env["MAGPIE_WEBDAV_PASSWORD"] = 'secret"with\\characters'
        self.env["AGENT_PROXY_URL"] = "socks5h://127.0.0.1:28487"
        result = self.bash('''source agent/install.sh
check_root() { :; }
prepare_process_env() { export PATH="$TEST_ROOT/bin:$PATH"; proxy_prepare_env; }
main --env
''')
        arguments = (self.root / "preflight-args.json").read_text()
        private_input = (self.root / "preflight-stdin").read_text()
        self.assertIn('secret\\"with\\\\characters', private_input)
        self.assertNotIn(self.env["MAGPIE_WEBDAV_PASSWORD"], arguments + result.stdout + result.stderr)
        self.assertNotIn(self.env["MAGPIE_PASSPHRASE"], private_input)
        exported = json.loads((self.root / "preflight-env.json").read_text())
        self.assertTrue(all(value == self.env["AGENT_PROXY_URL"] for value in exported.values()))

    def test_successful_rerun_skips_preflight_and_local_backup_needs_no_dav(self):
        self.run_agent()
        self.env["TEST_FAIL_PREFLIGHT"] = "7"
        self.run_agent()
        self.assertEqual(self.calls().count("dav:preflight"), 1)
        backup = self.root / "native.magpie-backup"
        backup.write_text("encrypted fixture")
        self.run_agent("--backup-file", backup)
        self.assertEqual(self.calls().count("dav:preflight"), 1)

    def test_service_environment_is_checked_before_install(self):
        self.script("bin/systemctl", "#!/bin/sh\nexit 1\n")
        self.script("bin/loginctl", "#!/bin/sh\nexit 0\n")
        result = self.run_agent("--start-gateway", ok=False)
        self.assertIn("systemd", result.stderr)
        self.assertFalse((self.root / "calls").exists())

    def test_gateway_setup_and_verification_use_eof_on_nonterminal_stdin(self):
        self.script("bin/systemctl", "#!/bin/sh\nexit 0\n")
        self.script("bin/loginctl", "#!/bin/sh\nexit 0\n")
        for agent in ("claude", "codex"):
            self.script(f"payload/{agent}", '''#!/usr/bin/env python3
import os, pathlib, select, sys
args = sys.argv[1:]
if args == ['--version']:
    print('fixture version')
    sys.exit(0)
assert select.select([sys.stdin], [], [], 0)[0], 'verification stdin must already be EOF'
assert sys.stdin.read() == ''
assert '127.0.0.1' in os.environ.get('NO_PROXY', '').split(',')
assert 'localhost' in os.environ.get('no_proxy', '').split(',')
with (pathlib.Path(os.environ['TEST_ROOT']) / 'calls').open('a') as out:
    out.write('verify:' + pathlib.Path(sys.argv[0]).name + '\\n')
if '--output-last-message' in args:
    pathlib.Path(args[args.index('--output-last-message') + 1]).write_text('MAGPIE_OK')
else:
    print('MAGPIE_OK')
''')
        self.run_agent("--verify")
        self.assertIn("daemon:install", self.calls())
        self.assertEqual(self.calls()[-2:], ["verify:claude", "verify:codex"])

    def test_skip_config_cannot_be_verified(self):
        self.run_agent("--skip-config", "--verify", ok=False)
        self.assertFalse((self.root / "calls").exists())
