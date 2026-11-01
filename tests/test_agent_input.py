import json

from test_installers import AgentFixture


INTERACTIVE_SETUP = '''export PATH="$TEST_ROOT/bin:$PATH"
source agent/install.sh
check_root() { :; }
# Keep actual installer effects in temporary paths even in interactive mode.
set_default_paths() {
  STATE_DIR="$TEST_ROOT/state"
  MAGPIE_CONFIG_DIR="$TEST_ROOT/config/magpie"
  BASHRC_FILE="$TEST_ROOT/bashrc"
}
'''


class AgentInputTests(AgentFixture):
    def test_default_requires_terminal_even_when_environment_is_complete(self):
        result = self.bash(INTERACTIVE_SETUP + 'main', ok=False)
        self.assertIn("默认交互模式需要终端", result.stderr)
        self.assertFalse((self.root / "state").exists())
        self.assertFalse((self.root / "calls").exists())

    def test_env_selects_local_backup_without_dav_credentials(self):
        backup = self.root / "my config.magpie-backup"
        backup.write_text("encrypted fixture one")
        self.env.update(MAGPIE_CONFIG_SOURCE="backup", MAGPIE_BACKUP_FILE=str(backup), MAGPIE_WEBDAV_PASSWORD="")
        self.run_agent()
        self.assertEqual((self.root / "backup-path").read_text(), str(backup))
        self.assertNotIn("webdav:on", self.calls())

    def test_env_file_defaults_to_dav_and_overrides_exported_values(self):
        self.env.pop("MAGPIE_CONFIG_SOURCE")
        env_file = self.root / "private settings.env"
        env_file.write_text("""AGENT_PROXY_MODE=env
AGENT_PROXY_URL=
http_proxy='http://127.0.0.1:19001'
MAGPIE_WEBDAV_BASE_URL='https://file.example.invalid/dav'
MAGPIE_WEBDAV_USERNAME='from-env-file'
MAGPIE_WEBDAV_PASSWORD='fixture-file-password'
""")
        self.bash(INTERACTIVE_SETUP + 'main --env "$1"', env_file)
        args = json.loads((self.root / "dav-args.json").read_text())
        self.assertIn("user=from-env-file", args)
        self.assertIn("fixture-file-password", json.loads((self.root / "dav-stdin.json").read_text()))
        self.assertEqual(json.loads((self.root / "download-env.json").read_text())["http_proxy"], "http://127.0.0.1:19001")

    def test_invalid_env_source_and_missing_file_fail_before_install(self):
        self.env["MAGPIE_CONFIG_SOURCE"] = "invalid"
        self.run_agent(ok=False)
        self.env.update(MAGPIE_CONFIG_SOURCE="backup", MAGPIE_BACKUP_FILE="/missing/fixture.magpie-backup")
        self.run_agent(ok=False)
        self.bash(INTERACTIVE_SETUP + 'main --env /missing/fixture.env', ok=False)
        self.assertFalse((self.root / "calls").exists())

    def test_default_dav_and_proxy_are_interactive_and_password_is_hidden(self):
        self.env.update(AGENT_PROXY_MODE="ssh", AGENT_PROXY_URL="http://wrong.example.invalid", MAGPIE_CONFIG_SOURCE="backup", MAGPIE_BACKUP_FILE="/ignored.magpie-backup")
        password = "fixture $ password ' unchanged"
        conversation = [
            ("代理方式", "9"), ("代理方式", "2"),
            ("代理 URL", "socks5h://127.0.0.1:19002"),
            ("Magpie 配置来源", ""),
            ("WebDAV Base URL", "https://interactive.example.invalid/dav"),
            ("WebDAV 用户名", "interactive-user"),
            ("WebDAV 密码", password),
            ("Magpie 加密口令", "fixture-interactive-passphrase"),
        ]
        output = self.bash_tty(INTERACTIVE_SETUP + 'main', conversation)
        self.assertNotIn(password, output)
        args = json.loads((self.root / "dav-args.json").read_text())
        self.assertIn(password, json.loads((self.root / "dav-stdin.json").read_text()))
        self.assertIn("user=interactive-user", args)
        self.assertIn("passphrase=", args)
        self.assertNotIn("fixture-interactive-passphrase", output)
        proxies = json.loads((self.root / "download-env.json").read_text())
        self.assertTrue(all(value == "socks5h://127.0.0.1:19002" for value in proxies.values()))

    def test_interactive_backup_reprompts_for_missing_file_and_clears_proxy_env(self):
        backup = self.root / "chosen config.magpie-backup"
        backup.write_text("encrypted fixture two")
        self.env.update(http_proxy="http://wrong.example.invalid", ALL_PROXY="socks5h://wrong.example.invalid:1080")
        output = self.bash_tty(INTERACTIVE_SETUP + 'main', [
            ("代理方式", ""), ("Magpie 配置来源", "2"),
            ("本地 Magpie 备份文件路径", "/missing/fixture.magpie-backup"),
            ("本地 Magpie 备份文件路径", str(backup)),
            ("Magpie 加密口令", "fixture-backup-passphrase"),
        ])
        self.assertNotIn("WebDAV 密码", output)
        self.assertEqual((self.root / "backup-path").read_text(), str(backup))
        self.assertTrue(all(value is None for value in json.loads((self.root / "download-env.json").read_text()).values()))
        self.assertNotIn("webdav:on", self.calls())

    def test_cancelled_input_exits_before_any_installation(self):
        self.bash_tty(INTERACTIVE_SETUP + 'main', [("代理方式", None)], ok=False)
        self.assertFalse((self.root / "state").exists())
        self.assertFalse((self.root / "calls").exists())

    def test_explicit_backup_flag_keeps_proxy_prompt_but_skips_dav_questions(self):
        backup = self.root / "explicit.magpie-backup"
        backup.write_text("encrypted fixture three")
        output = self.bash_tty(INTERACTIVE_SETUP + 'main --backup-file "$1"', [("代理方式", "1"), ("Magpie 加密口令", "fixture-backup-passphrase")], backup)
        self.assertNotIn("Magpie 配置来源", output)
        self.assertEqual((self.root / "backup-path").read_text(), str(backup))
