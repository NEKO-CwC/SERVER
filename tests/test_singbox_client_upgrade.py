"""Client upgrades preserve host settings and recover from startup failure."""
import json
from test_installers import ShellTests


class ClientUpgradeTests(ShellTests):
    def setUp(self):
        super().setUp()
        (self.root / 'stage').mkdir()
        (self.root / 'config').mkdir()
        self.setup_client = '''source VPS/singbox/client/install.sh
TMP_DIR="$TEST_ROOT/stage"
CONFIG_DIR="$TEST_ROOT/config"
CONFIG_FILE="$CONFIG_DIR/config.json"
CONFIG_OVERRIDE_FILE="$CONFIG_DIR/config.override.json"
BYPASS_FILE="$CONFIG_DIR/bypass.sh"
INSTALL_BIN="$TEST_ROOT/bin/sing-box"
SINGBOX_UNIT="$TEST_ROOT/client.service"
BYPASS_UNIT="$TEST_ROOT/bypass.service"
cleanup_proxy() { :; }
'''
        self.script('validator', '''#!/usr/bin/env python3
import json, pathlib, sys
args = sys.argv[1:]
if args[0] == 'version': print('sing-box version 1.14.4')
elif args[0] == 'merge':
    configs = [json.loads(pathlib.Path(args[i+1]).read_text()) for i,x in enumerate(args) if x == '-c']
    result = configs[0]
    for config in configs[1:]:
        for key, value in config.items():
            if isinstance(value, dict): result.setdefault(key, {}).update(value)
            else: result[key] = value
    pathlib.Path(args[1]).write_text(json.dumps(result))
elif args[0] == 'check':
    p = json.loads(pathlib.Path(args[args.index('-c')+1]).read_text())
    if p.get('invalid'): sys.exit(1)
else: sys.exit(1)
''')

    def test_override_is_merged_and_validated_before_replacement(self):
        (self.root / 'config/config.override.json').write_text(json.dumps({'route': {'auto_detect_interface': False, 'default_interface': 'wan0'}}))
        self.bash(self.setup_client + '''download_file() { printf '%s' '{"route":{"auto_detect_interface":true,"final":"proxy"}}' > "$1"; }
stage_config "$TEST_ROOT/validator" https://example.invalid/sub
cp "$STAGED_CONFIG" "$TEST_ROOT/result.json"
''')
        route = json.loads((self.root / 'result.json').read_text())['route']
        self.assertEqual(route, {'auto_detect_interface': False, 'default_interface': 'wan0', 'final': 'proxy'})
        self.assertFalse((self.root / 'config/config.json').exists())

    def test_invalid_override_or_merged_config_preserves_old_config(self):
        old = self.root / 'config/config.json'
        old.write_text('old config')
        for value in ('invalid json', '{"invalid":true}'):
            with self.subTest(value=value):
                (self.root / 'config/config.override.json').write_text(value)
                self.bash(self.setup_client + '''download_file() { printf '{}' > "$1"; }
stage_config "$TEST_ROOT/validator" https://example.invalid/sub
''', ok=False)
                self.assertEqual(old.read_text(), 'old config')

    def previous_install(self):
        for path in ('config/config.json', 'config/bypass.sh', 'client.service', 'bypass.service', 'bin/sing-box', 'bin/libcronet.so'):
            file = self.root / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('old ' + path)
            file.chmod(0o600 if path.endswith('.json') else 0o755)
        return {p: (p.read_bytes(), p.stat().st_mode) for p in self.root.rglob('*') if p.is_file()}

    def test_failed_start_restores_files_and_restarts_previous_client(self):
        originals = self.previous_install()
        self.bash(self.setup_client + '''systemctl() {
  printf '%s\\n' "$*" >> "$TEST_ROOT/systemctl.calls"
  case "$1" in
    is-active|is-enabled) return 0 ;;
    restart) [[ "$(cat "$CONFIG_FILE")" == 'old config/config.json' ]] ;;
  esac
}
trap cleanup EXIT
snapshot_install
for path in "${ROLLBACK_FILES[@]}"; do printf 'new broken install' > "$path"; done
start_services
''', ok=False)
        for path, (content, mode) in originals.items():
            self.assertEqual(path.read_bytes(), content)
            self.assertEqual(path.stat().st_mode, mode)
        calls = (self.root / 'systemctl.calls').read_text().splitlines()
        self.assertEqual(calls[-3:], ['daemon-reload', 'enable sing-box-client.service', 'restart sing-box-client.service'])

    def test_failed_first_install_removes_files_and_disables_service(self):
        self.bash(self.setup_client + '''systemctl() {
  printf '%s\\n' "$*" >> "$TEST_ROOT/systemctl.calls"
  case "$1" in is-active|is-enabled) return 1;; esac
}
snapshot_install
mkdir -p "$(dirname "$INSTALL_BIN")"
for path in "${ROLLBACK_FILES[@]}"; do printf new > "$path"; done
rollback_install
for path in "${ROLLBACK_FILES[@]}"; do [[ ! -e "$path" ]]; done
''')
        calls = (self.root / 'systemctl.calls').read_text()
        self.assertIn('disable sing-box-client.service', calls)
        self.assertNotIn('restart sing-box-client.service', calls)

    def test_success_does_not_roll_back(self):
        self.previous_install()
        self.bash(self.setup_client + '''systemctl() { return 0; }
trap cleanup EXIT
snapshot_install
printf new > "$CONFIG_FILE"
INSTALL_PENDING=0
''')
        self.assertEqual((self.root / 'config/config.json').read_text(), 'new')

    def test_partial_write_failure_preserves_previously_stopped_client(self):
        originals = self.previous_install()
        self.bash(self.setup_client + '''systemctl() {
  printf '%s\\n' "$*" >> "$TEST_ROOT/systemctl.calls"
  case "$1" in is-active|is-enabled) return 1;; esac
}
trap cleanup EXIT
snapshot_install
printf partial > "$CONFIG_FILE"
false
''', ok=False)
        for path, (content, mode) in originals.items():
            self.assertEqual(path.read_bytes(), content)
            self.assertEqual(path.stat().st_mode, mode)
        calls = (self.root / 'systemctl.calls').read_text()
        self.assertIn('disable sing-box-client.service', calls)
        self.assertNotIn('restart sing-box-client.service', calls)
