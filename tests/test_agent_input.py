import json

from test_installers import AgentFixture


INTERACTIVE_SETUP = '''export PATH="$TEST_ROOT/bin:$PATH"
source agent/install.sh
check_root() { :; }
# Keep actual installer effects in temporary paths even in interactive mode.
set_default_paths() {
  STATE_DIR="$TEST_ROOT/state"
  CC_CONFIG_DIR="$TEST_ROOT/config"
  BASHRC_FILE="$TEST_ROOT/bashrc"
}
'''


class AgentInputTests(AgentFixture):
    def test_default_requires_terminal_even_when_environment_is_complete(self):
        result = self.bash(INTERACTIVE_SETUP + 'main', ok=False)
        self.assertIn("默认交互模式需要终端", result.stderr)
        self.assertFalse((self.root / "state").exists())
        self.assertFalse((self.root / "calls").exists())

    def test_env_selects_local_sql_without_dav_credentials(self):
        sql = self.root / "my config.sql"
        sql.write_text("select 1;")
        self.env.update(CC_SWITCH_CONFIG_SOURCE="sql", CC_SWITCH_SQL_FILE=str(sql), CC_SWITCH_WEBDAV_PASSWORD="")
        self.run_agent()
        self.assertEqual((self.root / "sql-path").read_text(), str(sql))
        self.assertNotIn("config:webdav:download", self.calls())

    def test_env_file_defaults_to_dav_and_overrides_exported_values(self):
        self.env.pop("CC_SWITCH_CONFIG_SOURCE")
        env_file = self.root / "private settings.env"
        env_file.write_text("""AGENT_PROXY_MODE=env
AGENT_PROXY_URL=
http_proxy='http://127.0.0.1:19001'
CC_SWITCH_WEBDAV_BASE_URL='https://file.example.invalid/dav'
CC_SWITCH_WEBDAV_USERNAME='from-env-file'
CC_SWITCH_WEBDAV_PASSWORD='fixture-file-password'
""")
        self.bash(INTERACTIVE_SETUP + 'main --env "$1"', env_file)
        args = json.loads((self.root / "dav-args.json").read_text())
        self.assertIn("from-env-file", args)
        self.assertIn("fixture-file-password", args)
        self.assertEqual(json.loads((self.root / "download-env.json").read_text())["http_proxy"], "http://127.0.0.1:19001")

    def test_invalid_env_source_and_missing_file_fail_before_install(self):
        self.env["CC_SWITCH_CONFIG_SOURCE"] = "invalid"
        self.run_agent(ok=False)
        self.env.update(CC_SWITCH_CONFIG_SOURCE="sql", CC_SWITCH_SQL_FILE="/missing/fixture.sql")
        self.run_agent(ok=False)
        self.bash(INTERACTIVE_SETUP + 'main --env /missing/fixture.env', ok=False)
        self.assertFalse((self.root / "calls").exists())

    def test_default_dav_and_proxy_are_interactive_and_password_is_hidden(self):
        self.env.update(AGENT_PROXY_MODE="ssh", AGENT_PROXY_URL="http://wrong.example.invalid", CC_SWITCH_CONFIG_SOURCE="sql", CC_SWITCH_SQL_FILE="/ignored.sql")
        password = "fixture $ password ' unchanged"
        conversation = [
            ("代理方式", "9"), ("代理方式", "2"),
            ("代理 URL", "socks5h://127.0.0.1:19002"),
            ("cc-switch 配置来源", ""),
            ("WebDAV Base URL", "https://interactive.example.invalid/dav"),
            ("WebDAV 用户名", "interactive-user"),
            ("WebDAV 密码", password),
            ("WebDAV Remote Root", ""), ("WebDAV Profile", ""),
        ]
        output = self.bash_tty(INTERACTIVE_SETUP + 'main', conversation)
        self.assertNotIn(password, output)
        args = json.loads((self.root / "dav-args.json").read_text())
        self.assertIn(password, args)
        self.assertIn("interactive-user", args)
        self.assertIn("cc-switch-sync", args)
        self.assertIn("default", args)
        proxies = json.loads((self.root / "download-env.json").read_text())
        self.assertTrue(all(value == "socks5h://127.0.0.1:19002" for value in proxies.values()))

    def test_interactive_sql_reprompts_for_missing_file_and_clears_proxy_env(self):
        sql = self.root / "chosen config.sql"
        sql.write_text("select 2;")
        self.env.update(http_proxy="http://wrong.example.invalid", ALL_PROXY="socks5h://wrong.example.invalid:1080")
        output = self.bash_tty(INTERACTIVE_SETUP + 'main', [
            ("代理方式", ""), ("cc-switch 配置来源", "2"),
            ("本地 SQL 文件路径", "/missing/fixture.sql"),
            ("本地 SQL 文件路径", str(sql)),
        ])
        self.assertNotIn("WebDAV 密码", output)
        self.assertEqual((self.root / "sql-path").read_text(), str(sql))
        self.assertTrue(all(value is None for value in json.loads((self.root / "download-env.json").read_text()).values()))
        self.assertNotIn("config:webdav:download", self.calls())

    def test_cancelled_input_exits_before_any_installation(self):
        self.bash_tty(INTERACTIVE_SETUP + 'main', [("代理方式", None)], ok=False)
        self.assertFalse((self.root / "state").exists())
        self.assertFalse((self.root / "calls").exists())

    def test_explicit_sql_flag_keeps_proxy_prompt_but_skips_dav_questions(self):
        sql = self.root / "explicit.sql"
        sql.write_text("select 3;")
        output = self.bash_tty(INTERACTIVE_SETUP + 'main --sql-file "$1"', [("代理方式", "1")], sql)
        self.assertNotIn("cc-switch 配置来源", output)
        self.assertEqual((self.root / "sql-path").read_text(), str(sql))
