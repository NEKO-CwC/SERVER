import json

from test_installers import AgentFixture


class BackupRestoreTests(AgentFixture):
    def setUp(self):
        super().setUp()
        self.backup = self.root / "local config.magpie-backup"
        self.backup.write_text("encrypted fixture")

    def test_restore_receives_passphrase_on_stdin_without_dav_credentials(self):
        self.env["MAGPIE_WEBDAV_PASSWORD"] = ""
        self.run_agent("--backup-file", self.backup)
        self.assertEqual((self.root / "backup-path").read_text(), str(self.backup))
        self.assertEqual(json.loads((self.root / "backup-stdin.json").read_text()),
                         [self.env["MAGPIE_PASSPHRASE"]])
        self.assertNotIn("webdav:on", self.calls())
        self.assertTrue((self.root / "state/config-success").is_file())

    def test_failed_restore_with_existing_config_does_not_mark_success(self):
        self.run_agent("--backup-file", self.backup)
        self.backup.write_text("different encrypted fixture")
        self.env["TEST_FAIL_CONFIG"] = "restore"
        result = self.run_agent("--backup-file", self.backup, ok=False)
        self.assertTrue((self.root / "config/magpie/providers.json").is_file())
        self.assertFalse((self.root / "state/config-success").exists())
        self.assertNotIn(self.env["MAGPIE_PASSPHRASE"], result.stdout + result.stderr)
        del self.env["TEST_FAIL_CONFIG"]
        self.run_agent("--backup-file", self.backup)
        self.assertEqual(self.calls().count("restore"), 3)

    def test_old_sql_flag_fails_with_migration_guidance(self):
        result = self.run_agent("--sql-file", "/unused/old.sql", ok=False)
        self.assertIn("--backup-file", result.stderr)
        self.assertFalse((self.root / "calls").exists())
