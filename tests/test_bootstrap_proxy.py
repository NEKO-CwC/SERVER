import io
import json
from pathlib import Path
import shutil
import tarfile

from test_agent_proxy import SSHProxyFixture


class BootstrapProxyTests(SSHProxyFixture):
    def setUp(self):
        super().setUp()
        self.env.update(
            INSTALL_PROXY_MODE="ssh",
            INSTALL_SSH_HOST="127.0.0.1",
            INSTALL_SSH_USER="fixture-user",
            INSTALL_SSH_PASSWORD=self.ssh.password,
            INSTALL_SSH_PORT=str(self.ssh.server_address[1]),
            INSTALL_SSH_SOCKS_PORT=str(self.socks_port),
            INSTALL_SSH_HOST_KEY_CHECKING="yes",
            INSTALL_SSH_KNOWN_HOSTS_FILE=str(self.known_hosts),
            INSTALL_PROXY_STATE_DIR=str(self.root / "state"),
            # The shared settings must take precedence over these legacy values.
            AGENT_PROXY_MODE="env", AGENT_PROXY_URL="http://127.0.0.1:1",
            DOWNLOAD_PROXY="http://127.0.0.1:1",
            TEST_HTTP_PORT=str(self.http.server_port),
            TEST_REAL_CURL=shutil.which("curl"),
        )
        self.script("bin/curl", '''#!/usr/bin/env python3
import os, pathlib, sys
root = pathlib.Path(os.environ['TEST_ROOT'])
args = sys.argv[1:]
for i, value in enumerate(args):
    if value.startswith('https://github.com/SagerNet/sing-box/'):
        version = value.split('/download/v')[1].split('/')[0]
        args[i] = 'http://download.example.invalid:' + os.environ['TEST_HTTP_PORT'] + '/' + version + '.tar.gz'
with (root / 'events').open('a') as out: out.write('curl\\n')
os.execv(os.environ['TEST_REAL_CURL'], [os.environ['TEST_REAL_CURL'], *args])
''')
        for version in ("1.13.15", "1.13.13"):
            archive = io.BytesIO()
            binary = ("#!/usr/bin/env python3\nimport json,sys\n"
                      f"if sys.argv[1] == 'version': print('sing-box version {version}')\n"
                      "elif sys.argv[1] == 'check':\n"
                      "    with open(sys.argv[sys.argv.index('-c')+1]) as stream: json.load(stream)\n"
                      "else: sys.exit(1)\n").encode()
            with tarfile.open(fileobj=archive, mode="w:gz") as tar:
                entry = tarfile.TarInfo(f"sing-box-{version}-linux-amd64/sing-box")
                entry.mode = 0o755
                entry.size = len(binary)
                tar.addfile(entry, io.BytesIO(binary))
            self.http.payloads[f"/{version}.tar.gz"] = archive.getvalue()
        self.http.payloads["/config.json"] = b'{"fixture":"downloaded"}'
        self.env["SUBSCRIPTION_URL"] = f"http://download.example.invalid:{self.http.server_port}/config.json"
        self.env["SINGBOX_SERVER_CONFIG_URL"] = self.env["SUBSCRIPTION_URL"]

    def installer_setup(self, role):
        # Actual staging/file-install code runs, while host services and APT stay untouched.
        setup = f'''export PATH="$TEST_ROOT/bin:$PATH"
source VPS/singbox/{role}/install.sh
INSTALL_BIN="$TEST_ROOT/installed/sing-box"
CONFIG_DIR="$TEST_ROOT/config"
CONFIG_FILE="$CONFIG_DIR/config.json"
SINGBOX_UNIT="$TEST_ROOT/unit.service"
LOCK_FILE="$TEST_ROOT/install.lock"
'''
        if role == "client":
            setup += '''BYPASS_FILE="$CONFIG_DIR/bypass.sh"
BYPASS_UNIT="$TEST_ROOT/bypass.service"
require_root_and_systemd() { :; }
require_commands() { :; }
require_legacy_stopped() { :; }
command() {
  if [[ "$1" == -v && "$2" == nft ]]; then return 1; fi
  builtin command "$@"
}
apt-get() {
  [[ -n "$SSH_PROXY_PID" ]]
  [[ "$http_proxy" == "socks5h://127.0.0.1:$INSTALL_SSH_SOCKS_PORT" ]]
  if [[ "$*" == *update ]]; then printf 'dependencies\\n' >>"$TEST_ROOT/events"; fi
}
start_services() {
  [[ -z "$SSH_PROXY_PID" ]]
  printf 'start\\n' >>"$TEST_ROOT/events"
}
systemctl() { :; }
'''
        else:
            setup += '''require_environment() { :; }
start_service() {
  [[ -z "$SSH_PROXY_PID" ]]
  printf 'start\\n' >>"$TEST_ROOT/events"
}
'''
        return setup

    def test_client_downloads_before_service_without_existing_singbox(self):
        self.assertFalse((self.root / "installed/sing-box").exists())
        self.bash(self.installer_setup("client") + 'main --env')
        self.assertEqual(self.http.requests, ["/1.13.15.tar.gz", "/config.json"])
        self.assertEqual(self.http.user_agents["/config.json"], "sing-box")
        self.assertEqual((self.root / "events").read_text().splitlines(), ["dependencies", "curl", "curl", "start"])
        self.assertEqual(json.loads((self.root / "config/config.json").read_text()), {"fixture": "downloaded"})
        self.assertEqual(self.ssh.auth_attempts, 1)
        self.assert_tunnel_cleaned()

    def test_server_downloads_binary_and_remote_config_through_same_tunnel(self):
        self.bash(self.installer_setup("server") + 'main --env')
        self.assertEqual(self.http.requests, ["/1.13.13.tar.gz", "/config.json"])
        self.assertEqual((self.root / "events").read_text().splitlines(), ["curl", "curl", "start"])
        self.assertEqual(self.ssh.auth_attempts, 1)
        self.assert_tunnel_cleaned()

    def test_failed_ssh_never_installs_or_starts_client(self):
        self.env["INSTALL_SSH_PASSWORD"] = "fixture-wrong-password"
        self.bash(self.installer_setup("client") + 'main --env', ok=False)
        self.assertFalse((self.root / "installed/sing-box").exists())
        self.assertFalse((self.root / "events").exists())
        self.assertEqual(self.http.requests, [])
        self.assert_tunnel_cleaned()

    def test_invalid_downloaded_config_preserves_existing_server(self):
        (self.root / "config").mkdir()
        (self.root / "config/config.json").write_text('{"old":true}')
        self.http.payloads["/config.json"] = b'not-json'
        self.bash(self.installer_setup("server") + 'main --env', ok=False)
        self.assertEqual((self.root / "config/config.json").read_text(), '{"old":true}')
        self.assertNotIn("start", (self.root / "events").read_text().splitlines())
        self.assertFalse((self.root / "installed/sing-box").exists())
        self.assert_tunnel_cleaned()

    def test_wrapper_downloads_and_does_not_export_ssh_password(self):
        output = self.root / "downloaded.sh"
        env_file = self.root / "command.env"
        env_file.write_text("BOOTSTRAP_FIXTURE_VALUE='from-file'\n")
        self.bash('''bash with-proxy.sh --env "$3" -- python3 -c '
import os, subprocess, sys
assert "INSTALL_SSH_PASSWORD" not in os.environ
assert "AGENT_SSH_PASSWORD" not in os.environ
assert os.environ["BOOTSTRAP_FIXTURE_VALUE"] == "from-file"
subprocess.run(["curl", "-fsSL", sys.argv[1], "-o", sys.argv[2]], check=True)
' "$1" "$2"
''', f"http://download.example.invalid:{self.http.server_port}/install.sh", output, env_file)
        self.assertTrue(output.read_text().startswith("#!/bin/sh"))
        self.assertEqual(self.ssh.auth_attempts, 1)
        self.assert_tunnel_cleaned()
