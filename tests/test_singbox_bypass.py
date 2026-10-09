"""Exercise real netfilter and routing in disposable Linux network namespaces."""

import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
BYPASS = REPO / "VPS/singbox/client/bypass.sh"
SERVER = """
import http.server, socket, threading
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'ok')
    def log_message(self, *args): pass
class IPv6Server(http.server.HTTPServer):
    address_family = socket.AF_INET6
    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        super().server_bind()
for port in PORTS:
    for cls, address in ((http.server.HTTPServer, '0.0.0.0'), (IPv6Server, '::')):
        server = cls((address, port), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
print('ready', flush=True)
threading.Event().wait()
"""
REQUEST = """
import http.client, sys
connection = http.client.HTTPConnection(sys.argv[1], int(sys.argv[2]),
    source_address=(sys.argv[3], 0), timeout=2)
try:
    connection.request('GET', '/')
    response = connection.getresponse()
    assert response.status == 200 and response.read() == b'ok'
finally:
    connection.close()
"""


class SingBoxBypassLifecycleTests(unittest.TestCase):
    """Check failure handling without touching host networking."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="neko-bypass-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state_file = self.root / "state.json"
        self.state_file.write_text(json.dumps({"rules": [], "table": None, "events": []}))
        mock = self.root / "network-command"
        mock.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
path = pathlib.Path(os.environ['MOCK_STATE'])
state = json.loads(path.read_text())
args = sys.argv[1:]
name = pathlib.Path(sys.argv[0]).name
state['events'].append([name, *args])
code = 0
if name == 'nft':
    if args[:2] == ['-f', '-']:
        batch = sys.stdin.read()
        if os.environ.get('MOCK_FAIL_NFT') == '1':
            code = 1
        else:
            state['table'] = batch
    elif args[:2] == ['list', 'table']:
        if state['table'] is None: code = 1
        else: print(state['table'])
    elif args[:2] == ['delete', 'table']:
        state['table'] = None
else:
    family = args.pop(0)
    if args[:2] == ['addr', 'show']:
        print('    inet 192.0.2.1/24 scope global wan0')
    elif args[0] == 'rule':
        operation, values = args[1], args[2:]
        selectors = dict(zip(values[::2], values[1::2]))
        matches = [rule for rule in state['rules'] if rule['family'] == family
                   and all(rule.get(key) == value for key, value in selectors.items())]
        if operation == 'show':
            if 'suppress_prefixlength' in selectors:
                sys.exit('ip rule show does not accept suppress_prefixlength')
            for rule in matches:
                text = rule['priority'] + ': from all'
                if 'to' in rule: text += ' to ' + rule['to']
                if 'fwmark' in rule: text += ' fwmark ' + rule['fwmark']
                text += ' lookup ' + rule['table']
                if 'suppress_prefixlength' in rule: text += ' suppress_prefixlength ' + rule['suppress_prefixlength']
                print(text)
        elif operation == 'add':
            state['rules'].append(dict(family=family, **selectors))
        elif operation == 'del':
            if matches: state['rules'].remove(matches[0])
            else: code = 1
path.write_text(json.dumps(state))
sys.exit(code)
''')
        mock.chmod(0o755)
        for command in ("ip", "nft"):
            (self.root / command).symlink_to(mock)
        self.env = dict(os.environ, MOCK_STATE=str(self.state_file), IFACE_PUBLIC="wan0",
                        PATH=str(self.root) + os.pathsep + os.environ["PATH"])
        self.env.pop("SSH_PORT", None)
        self.env.pop("INGRESS_TCP_PORTS", None)

    def run_bypass(self, action="apply", check=True, **environment):
        result = subprocess.run(["bash", str(BYPASS), action], env=dict(self.env, **environment),
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode == 0, check, result.stdout + result.stderr)
        return json.loads(self.state_file.read_text())

    def test_dual_stack_policy_is_idempotent_and_cleanup_is_complete(self):
        first = self.run_bypass()
        second = self.run_bypass()
        self.assertEqual(first["rules"], second["rules"])
        self.assertEqual(len(second["rules"]), 4)
        for family in ("-4", "-6"):
            self.assertIn({"family": family, "priority": "5000", "fwmark": "0x100/0x100", "table": "main"}, second["rules"])
        self.assertIn("delete table inet singbox_client_bypass", second["table"])
        self.assertEqual(self.run_bypass("cleanup")["rules"], [])
        cleaned = self.run_bypass("cleanup")
        self.assertEqual(cleaned["rules"], [])
        self.assertIsNone(cleaned["table"])

    def test_failed_reload_keeps_previous_rules_and_table(self):
        first = self.run_bypass()
        failed = self.run_bypass(check=False, MOCK_FAIL_NFT="1", INGRESS_TCP_PORTS="8443")
        self.assertEqual(first["rules"], failed["rules"])
        self.assertEqual(first["table"], failed["table"])
        self.assertFalse(any(event[:3] == ["nft", "delete", "table"] for event in failed["events"]))

    def test_legacy_exact_mark_rules_migrate_to_masked_rules(self):
        state = json.loads(self.state_file.read_text())
        state["rules"] = [{"family": family, "priority": "5000", "fwmark": "0x100/0xffffffff", "table": "main"}
                          for family in ("-4", "-6")]
        self.state_file.write_text(json.dumps(state))
        migrated = self.run_bypass()
        self.assertEqual(len(migrated["rules"]), 4)
        self.assertFalse(any(rule.get("fwmark") == "0x100/0xffffffff" for rule in migrated["rules"]))

    def test_bad_ports_fail_before_network_changes(self):
        first = self.run_bypass()
        for value in ("0", "65536", "80,", "80;443", "999999999999999999999"):
            with self.subTest(value=value):
                failed = self.run_bypass(check=False, INGRESS_TCP_PORTS=value)
                self.assertEqual(first, failed)
        failed = self.run_bypass(check=False, SSH_PORT="0")
        self.assertEqual(first, failed)


class SingBoxBypassRoutingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not hasattr(os, "geteuid") or os.geteuid() != 0:
            raise unittest.SkipTest("routing integration requires Linux root")
        for command in ("unshare", "nsenter", "ip", "nft", "python3"):
            if not shutil.which(command):
                raise unittest.SkipTest(f"routing integration requires {command}")
        probe = subprocess.run(["unshare", "-n", "true"], capture_output=True)
        if probe.returncode:
            raise unittest.SkipTest("network namespaces require CAP_SYS_ADMIN")
        for command in (("nft", "list", "ruleset"), ("ip", "link", "add", "test0", "type", "veth", "peer", "name", "test1")):
            probe = subprocess.run(["unshare", "-n", *command], capture_output=True, text=True)
            if probe.returncode:
                raise unittest.SkipTest(f"kernel lacks netfilter/veth support: {probe.stderr.strip()}")
        cls.processes = []
        cls.addClassCleanup(cls.stop_processes)
        cls.node, cls.client, cls.pod = [cls.namespace() for _ in range(3)]
        # Every network operation targets a child namespace, never the host.
        cls.run_in(cls.node, "ip", "link", "add", "wan0", "type", "veth", "peer", "name", "outside0")
        cls.run_in(cls.node, "ip", "link", "set", "outside0", "netns", str(cls.client))
        cls.run_in(cls.node, "ip", "link", "add", "pod0", "type", "veth", "peer", "name", "inside0")
        cls.run_in(cls.node, "ip", "link", "set", "inside0", "netns", str(cls.pod))
        for pid, iface, addresses in (
            (cls.node, "wan0", ("192.0.2.1/24", "192.0.2.10/24", "2001:db8:1::1/64", "2001:db8:1::10/64")),
            (cls.client, "outside0", ("192.0.2.2/24", "2001:db8:1::2/64")),
            (cls.node, "pod0", ("10.90.0.1/24", "fd90::1/64")),
            (cls.pod, "inside0", ("10.90.0.2/24", "fd90::2/64")),
            (cls.client, "lo", ("198.51.100.2/32", "2001:db8:2::2/128")),
        ):
            cls.run_in(pid, "ip", "link", "set", "lo", "up")
            cls.run_in(pid, "ip", "link", "set", iface, "up")
            for address in addresses:
                cls.run_in(pid, "ip", "addr", "add", address, "dev", iface, "nodad")
        for pid, gateway4, gateway6 in (
            (cls.node, "192.0.2.2", "2001:db8:1::2"),
            (cls.pod, "10.90.0.1", "fd90::1"),
        ):
            for family, gateway in (("-4", gateway4), ("-6", gateway6)):
                cls.run_in(pid, "ip", family, "route", "add", "default", "via", gateway)
        cls.run_in(cls.node, "sysctl", "-qw", "net.ipv4.ip_forward=1", "net.ipv6.conf.all.forwarding=1",
                   "net.ipv4.conf.all.rp_filter=0", "net.ipv4.conf.wan0.rp_filter=0")
        cls.run_in(cls.node, "ip", "link", "add", "tun-test", "type", "dummy")
        cls.run_in(cls.node, "ip", "link", "set", "tun-test", "up")
        # Connected destinations still work, but unprotected Internet replies
        # hit this table before the ordinary main-table default route.
        for family in ("-4", "-6"):
            cls.run_in(cls.node, "ip", family, "route", "add", "default", "dev", "tun-test", "table", "200")
            cls.run_in(cls.node, "ip", family, "rule", "add", "priority", "8999", "table", "main", "suppress_prefixlength", "0")
            cls.run_in(cls.node, "ip", family, "rule", "add", "priority", "9000", "table", "200")
        cls.run_in(cls.node, "nft", "-f", "-", input="""
table ip test_dnat4 {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip daddr 192.0.2.10 tcp dport 80 dnat to 10.90.0.2:8080
    ip daddr 192.0.2.10 tcp dport 443 dnat to 10.90.0.2:8443
  }
}
table ip6 test_dnat6 {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip6 daddr 2001:db8:1::10 tcp dport 80 dnat to [fd90::2]:8080
    ip6 daddr 2001:db8:1::10 tcp dport 443 dnat to [fd90::2]:8443
  }
}
""")
        for pid, ports in ((cls.node, [22, 80, 443, 2222, 8443]), (cls.pod, [8080, 8443]),
                           (cls.client, [22, 80, 443])):
            cls.start_ready(["nsenter", "-t", str(pid), "-n", "python3", "-u", "-c",
                             f"PORTS = {ports!r}\n" + SERVER])

    @classmethod
    def stop_processes(cls):
        for process in reversed(cls.processes):
            process.terminate()
        for process in reversed(cls.processes):
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
            process.stdout.close()
            process.stderr.close()

    @classmethod
    def start_ready(cls, command):
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        cls.processes.append(process)
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=5) or process.stdout.readline().strip() != "ready":
                process.terminate()
                _, error = process.communicate(timeout=3)
                raise AssertionError(f"fixture did not start: {error}")
        return process.pid

    @classmethod
    def namespace(cls):
        return cls.start_ready(["unshare", "-n", "python3", "-u", "-c",
                                "import time; print('ready', flush=True); time.sleep(300)"])

    @classmethod
    def run_in(cls, pid, *command, check=True, **kwargs):
        result = subprocess.run(["nsenter", "-t", str(pid), "-n", *command],
                                capture_output=True, text=True, timeout=10, **kwargs)
        if check and result.returncode:
            raise AssertionError(f"{command}: {result.stdout}{result.stderr}")
        return result

    def bypass(self, action="apply", check=True, **environment):
        return self.run_in(self.node, "bash", str(BYPASS), action, check=check,
                           env=dict(os.environ, IFACE_PUBLIC="wan0", **environment))

    def setUp(self):
        self.addCleanup(self.bypass, "cleanup")

    def request(self, address, port, source, success=True, pid=None):
        result = self.run_in(pid or self.client, "python3", "-c", REQUEST, address, str(port), source, check=False)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)

    def test_host_and_forwarded_ingress_dual_stack(self):
        self.request("192.0.2.1", 80, "198.51.100.2", success=False)
        self.request("2001:db8:1::10", 443, "2001:db8:2::2", success=False)
        self.bypass()
        for address, source in (("192.0.2.1", "198.51.100.2"), ("192.0.2.10", "198.51.100.2"),
                                ("2001:db8:1::1", "2001:db8:2::2"), ("2001:db8:1::10", "2001:db8:2::2")):
            for port in (80, 443):
                with self.subTest(address=address, port=port):
                    self.request(address, port, source)
        self.request("192.0.2.1", 22, "198.51.100.2")

    def test_outbound_http_still_uses_proxy_policy(self):
        self.bypass()
        for address, source, family in (("198.51.100.2", "192.0.2.1", "-4"),
                                        ("2001:db8:2::2", "2001:db8:1::1", "-6")):
            for port in (80, 443):
                self.request(address, port, source, success=False, pid=self.node)
            self.request(address, 22, source, pid=self.node)
            # Verify the same HTTP targets work when the simulated TUN policy
            # is bypassed, so failures above cannot be caused by the fixture.
            prefix = address + ("/32" if family == "-4" else "/128")
            selector = (family, "rule", "priority", "4999", "to", prefix, "table", "main")
            self.run_in(self.node, "ip", family, "rule", "add", *selector[2:])
            try:
                for port in (80, 443):
                    self.request(address, port, source, pid=self.node)
            finally:
                self.run_in(self.node, "ip", family, "rule", "del", *selector[2:])

    def test_configurable_ports_and_validation(self):
        self.bypass()
        self.request("192.0.2.1", 8443, "198.51.100.2", success=False)
        self.bypass(SSH_PORT="2222", INGRESS_TCP_PORTS="80,443,8443")
        self.request("192.0.2.1", 2222, "198.51.100.2")
        self.request("2001:db8:1::1", 8443, "2001:db8:2::2")
        for value in ("0", "65536", "80,", "80;443", "999999999999999999999"):
            with self.subTest(value=value):
                self.assertNotEqual(self.bypass(check=False, INGRESS_TCP_PORTS=value).returncode, 0)
        self.assertNotEqual(self.bypass(check=False, SSH_PORT="0").returncode, 0)
        self.request("192.0.2.1", 8443, "198.51.100.2")
        self.bypass(INGRESS_TCP_PORTS="")
        self.request("192.0.2.1", 80, "198.51.100.2", success=False)
        self.request("192.0.2.1", 22, "198.51.100.2")

    def test_reload_preserves_foreign_mark_bits_and_cleans_legacy_rules(self):
        self.run_in(self.node, "nft", "-f", "-", input="""
table inet foreign_marks {
  counter preserved {}
  chain prerouting {
    type filter hook prerouting priority mangle - 1; policy accept;
    meta mark set meta mark | 0x4000
    iifname "wan0" ct state new ct mark set ct mark | 0x4000
  }
  chain output {
    type route hook output priority mangle - 1; policy accept;
    meta mark set meta mark | 0x4000
  }
  chain postrouting {
    type filter hook postrouting priority mangle; policy accept;
    ct direction reply ct mark & 0x4100 == 0x4100 meta mark & 0x4100 == 0x4100 counter name preserved
  }
}
""")
        self.addCleanup(self.run_in, self.node, "nft", "delete", "table", "inet", "foreign_marks")
        for family in ("-4", "-6"):
            self.run_in(self.node, "ip", family, "rule", "add", "priority", "5000", "fwmark", "0x100", "table", "main")
        for _ in range(3):
            self.bypass()
        for family in ("-4", "-6"):
            rules = self.run_in(self.node, "ip", family, "rule", "show").stdout.splitlines()
            self.assertEqual(len([rule for rule in rules if rule.startswith("5000:")]), 1)
            self.assertEqual(len([rule for rule in rules if rule.startswith("4004:")]), 1)
        for address, source in (("192.0.2.1", "198.51.100.2"), ("192.0.2.10", "198.51.100.2"),
                                ("2001:db8:1::1", "2001:db8:2::2"), ("2001:db8:1::10", "2001:db8:2::2")):
            self.request(address, 443, source)
        counters = json.loads(self.run_in(self.node, "nft", "-j", "list", "counter", "inet", "foreign_marks", "preserved").stdout)
        self.assertGreaterEqual(next(item["counter"]["packets"] for item in counters["nftables"] if "counter" in item), 4)
        self.bypass("cleanup")
        self.bypass("cleanup")
        for family in ("-4", "-6"):
            rules = self.run_in(self.node, "ip", family, "rule", "show").stdout
            self.assertNotIn("5000:", rules)
            self.assertNotIn("4004:", rules)
        self.assertNotEqual(self.run_in(self.node, "nft", "list", "table", "inet", "singbox_client_bypass", check=False).returncode, 0)

    def test_failed_nft_transaction_preserves_live_rules(self):
        self.bypass()
        before = self.run_in(self.node, "nft", "-j", "list", "table", "inet", "singbox_client_bypass").stdout
        wrapper = """
nft() {
  if [[ "$1" == -f ]]; then
    { cat; printf '\\nthis is invalid nft syntax\\n'; } | command nft -f -
  else
    command nft "$@"
  fi
}
export -f nft
exec bash "$1" apply
"""
        result = self.run_in(self.node, "bash", "-c", wrapper, "test", str(BYPASS), check=False,
                             env=dict(os.environ, IFACE_PUBLIC="wan0"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(before, self.run_in(self.node, "nft", "-j", "list", "table", "inet", "singbox_client_bypass").stdout)
        self.request("192.0.2.1", 80, "198.51.100.2")
        self.request("2001:db8:1::10", 443, "2001:db8:2::2")


if __name__ == "__main__":
    unittest.main()
