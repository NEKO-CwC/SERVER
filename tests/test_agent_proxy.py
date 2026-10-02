import functools
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import select
import shutil
import socket
import socketserver
import threading
import unittest

from test_installers import AgentFixture, ShellTests

try:
    import paramiko
except ImportError:
    paramiko = None


PROXY_KEYS = ("http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")
PROXY_SETUP = '''source agent/install.sh
umask 077
install -d -m 0700 "$STATE_DIR"
trap cleanup_proxy EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
prepare_process_env
'''


class ProxyEnvironmentTests(AgentFixture):
    def test_explicit_url_sets_all_proxy_variables_without_exporting_password(self):
        self.env.update(AGENT_PROXY_MODE="env", AGENT_PROXY_URL="socks5h://127.0.0.1:18080", AGENT_SSH_PASSWORD="fixture-ssh-password")
        result = self.bash(PROXY_SETUP + '''python3 -c 'import os,json; print(json.dumps(dict(os.environ)))' ''')
        exported = json.loads(result.stdout.splitlines()[-1])
        for key in PROXY_KEYS:
            self.assertEqual(exported[key], self.env["AGENT_PROXY_URL"])
        self.assertNotIn("AGENT_SSH_PASSWORD", exported)
        self.assertNotIn("SSH_PROXY_PASSWORD", exported)

    def test_empty_url_preserves_existing_environment(self):
        self.env.update(AGENT_PROXY_MODE="env", AGENT_PROXY_URL="", http_proxy="http://127.0.0.1:18081", ALL_PROXY="socks5h://127.0.0.1:18082")
        result = self.bash(PROXY_SETUP + '''python3 -c 'import os,json; print(json.dumps(dict(os.environ)))' ''')
        exported = json.loads(result.stdout.splitlines()[-1])
        self.assertEqual(exported["http_proxy"], self.env["http_proxy"])
        self.assertEqual(exported["ALL_PROXY"], self.env["ALL_PROXY"])

    def test_completed_install_never_starts_ssh(self):
        self.env.update(AGENT_PROXY_MODE="ssh", AGENT_SSH_HOST="", AGENT_SSH_USER="", AGENT_SSH_PASSWORD="")
        for tool in ("cc-switch", "claude", "codex"):
            shutil.copy(self.root / "payload" / tool, self.root / "bin" / tool)
        self.bash('''export PATH="$TEST_ROOT/bin:$PATH"
source agent/install.sh
check_root() { :; }
main --skip-config
''')
        self.assertFalse((self.root / "calls").exists())
        self.assertFalse((self.root / "state/ssh-proxy.log").exists())

    def test_invalid_mode_and_missing_ssh_env_stop_before_download(self):
        self.env["AGENT_PROXY_MODE"] = "invalid"
        self.bash(PROXY_SETUP, ok=False)
        self.env.update(AGENT_PROXY_MODE="ssh", AGENT_SSH_HOST="", AGENT_SSH_PASSWORD="")
        self.bash(PROXY_SETUP + 'run_installer https://example.invalid/install.sh sh', ok=False)
        self.assertFalse((self.root / "calls").exists())


class ForwardingOnlyServer(paramiko.ServerInterface if paramiko else object):
    def __init__(self, owner):
        self.owner = owner
        self.destinations = {}

    def get_allowed_auths(self, username):
        return "password"

    def check_auth_password(self, username, password):
        self.owner.auth_attempts += 1
        if username == "fixture-user" and password == self.owner.password:
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def check_channel_request(self, kind, chanid):
        self.owner.session_requests.append(kind)
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_direct_tcpip_request(self, chanid, origin, destination):
        self.owner.destinations.append(destination)
        if destination != ("download.example.invalid", self.owner.http_port):
            return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        self.destinations[chanid] = ("127.0.0.1", self.owner.http_port)
        return paramiko.OPEN_SUCCEEDED


class SSHHandler(socketserver.BaseRequestHandler):
    def handle(self):
        transport = paramiko.Transport(self.request)
        self.server.transports.append(transport)
        transport.add_server_key(self.server.host_key)
        interface = ForwardingOnlyServer(self.server)
        try:
            transport.start_server(server=interface)
            while transport.is_active():
                channel = transport.accept(timeout=0.2)
                if channel is None:
                    continue
                with channel, socket.create_connection(interface.destinations[channel.get_id()], timeout=5) as upstream:
                    while transport.is_active():
                        readable, _, _ = select.select([channel, upstream], [], [], 0.2)
                        finished = False
                        for source in readable:
                            data = source.recv(65536)
                            if not data:
                                finished = True
                                break
                            (upstream if source is channel else channel).sendall(data)
                        if finished:
                            break
        except (EOFError, paramiko.SSHException) as error:
            # Host-key rejection deliberately closes SSH during key exchange.
            self.server.closed_during_handshake.append(type(error).__name__)
        finally:
            transport.close()


class SSHFixture(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


class DownloadHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/install.sh":
            self.send_error(404)
            return
        payload = b'''#!/bin/sh
python3 -c 'import json,os,pathlib; pathlib.Path(os.environ["TEST_ROOT"],"installer-env.json").write_text(json.dumps(dict(os.environ)))'
'''
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        self.server.requests.append(self.path)


@unittest.skipUnless(paramiko is not None and shutil.which("ssh"), "requires paramiko and OpenSSH for isolated SSH integration tests")
class SSHProxyTests(ShellTests):
    def setUp(self):
        super().setUp()
        self.http = ThreadingHTTPServer(("127.0.0.1", 0), DownloadHandler)
        self.http.requests = []
        self.ssh = SSHFixture(("127.0.0.1", 0), SSHHandler)
        self.ssh.http_port = self.http.server_port
        self.ssh.host_key = paramiko.RSAKey.generate(2048)
        self.ssh.password = "fixture-only-$-password"
        self.ssh.auth_attempts = 0
        self.ssh.destinations = []
        self.ssh.transports = []
        self.ssh.session_requests = []
        self.ssh.closed_during_handshake = []
        self.threads = []
        for server in (self.http, self.ssh):
            thread = threading.Thread(target=functools.partial(server.serve_forever, poll_interval=0.05), daemon=True)
            thread.start()
            self.threads.append(thread)
        self.addCleanup(self.close_servers)
        self.known_hosts = self.root / "trusted hosts"
        self.write_host_key(self.ssh.host_key)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            self.socks_port = sock.getsockname()[1]
        self.env.update(
            AGENT_INSTALL_STATE_DIR=str(self.root / "state"),
            AGENT_PROXY_MODE="ssh",
            AGENT_PROXY_URL="http://127.0.0.1:1",
            AGENT_SSH_HOST="127.0.0.1",
            AGENT_SSH_USER="fixture-user",
            AGENT_SSH_PASSWORD=self.ssh.password,
            AGENT_SSH_PORT=str(self.ssh.server_address[1]),
            AGENT_SSH_SOCKS_PORT=str(self.socks_port),
            AGENT_SSH_KNOWN_HOSTS_FILE=str(self.known_hosts),
            NO_PROXY="", no_proxy="",
        )

    def write_host_key(self, key):
        self.known_hosts.write_text(f"[127.0.0.1]:{self.ssh.server_address[1]} {key.get_name()} {key.get_base64()}\n")

    def close_servers(self):
        for transport in self.ssh.transports:
            transport.close()
        for server in (self.ssh, self.http):
            server.shutdown()
            server.server_close()
        for thread in self.threads:
            thread.join(timeout=3)

    def assert_tunnel_cleaned(self):
        with socket.socket() as sock:
            self.assertNotEqual(sock.connect_ex(("127.0.0.1", self.socks_port)), 0)
        if (self.root / "runtime-dir").exists():
            self.assertFalse(Path((self.root / "runtime-dir").read_text().strip()).exists())

    def test_real_ssh_download_remote_dns_child_env_and_cleanup(self):
        result = self.bash(PROXY_SETUP + '''ensure_download_proxy
printf '%s' "$SSH_PROXY_DIR" >"$TEST_ROOT/runtime-dir"
run_installer "http://download.example.invalid:$1/install.sh" sh
ensure_download_proxy
''', self.http.server_port)
        exported = json.loads((self.root / "installer-env.json").read_text())
        for key in PROXY_KEYS:
            self.assertEqual(exported[key], f"socks5h://127.0.0.1:{self.socks_port}")
        self.assertNotIn("AGENT_SSH_PASSWORD", exported)
        self.assertNotIn("SSH_PROXY_PASSWORD", exported)
        self.assertNotIn(self.ssh.password, result.stdout + result.stderr + (self.root / "state/ssh-proxy.log").read_text())
        self.assertEqual(self.ssh.auth_attempts, 1)
        self.assertEqual(self.ssh.session_requests, [])
        self.assertIn(("download.example.invalid", self.http.server_port), self.ssh.destinations)
        self.assertEqual((self.root / "state/ssh-proxy.log").stat().st_mode & 0o777, 0o600)
        self.assert_tunnel_cleaned()

    def test_wrong_password_and_untrusted_host_stop_without_downloading(self):
        self.env["AGENT_SSH_PASSWORD"] = "fixture-wrong-password"
        self.bash(PROXY_SETUP + 'ensure_download_proxy', ok=False)
        self.assertEqual(self.http.requests, [])
        self.assert_tunnel_cleaned()
        self.env["AGENT_SSH_PASSWORD"] = self.ssh.password
        self.write_host_key(paramiko.RSAKey.generate(2048))
        self.bash(PROXY_SETUP + 'ensure_download_proxy', ok=False)
        self.assertEqual(self.http.requests, [])
        self.assertEqual(self.ssh.auth_attempts, 1)
        self.assert_tunnel_cleaned()

    def test_occupied_port_is_preserved(self):
        with socket.socket() as occupied:
            occupied.bind(("127.0.0.1", self.socks_port))
            occupied.listen()
            self.bash(PROXY_SETUP + 'ensure_download_proxy', ok=False)
            with socket.socket() as probe:
                self.assertEqual(probe.connect_ex(("127.0.0.1", self.socks_port)), 0)
        self.assertEqual(self.http.requests, [])

    def test_failed_download_and_termination_close_tunnel(self):
        self.bash(PROXY_SETUP + '''ensure_download_proxy
printf '%s' "$SSH_PROXY_DIR" >"$TEST_ROOT/runtime-dir"
run_installer "http://download.example.invalid:$1/missing" sh
''', self.http.server_port, ok=False)
        self.assert_tunnel_cleaned()
        result = self.bash(PROXY_SETUP + '''ensure_download_proxy
printf '%s' "$SSH_PROXY_DIR" >"$TEST_ROOT/runtime-dir"
kill -TERM $$
''', ok=False)
        self.assertEqual(result.returncode, 143)
        self.assert_tunnel_cleaned()
