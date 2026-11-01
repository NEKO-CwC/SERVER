import tarfile

from test_installers import AgentFixture


class AgentMigrationTests(AgentFixture):
    def setUp(self):
        super().setUp()
        self.home = self.root / "home"
        self.home.mkdir()
        self.env["HOME"] = str(self.home)
        self.script("bin/pgrep", "#!/bin/sh\nexit 1\n")
        self.script("bin/systemctl", "#!/bin/sh\nexit 1\n")
        self.legacy = self.script("bin/cc-switch", "#!/bin/sh\necho legacy\n")
        (self.home / ".cc-switch").mkdir()
        (self.home / ".cc-switch/cc-switch.db").write_text("legacy database")
        (self.home / ".claude").mkdir()
        (self.home / ".claude/settings.json").write_text('{"original":true}')
        (self.root / "bashrc").write_text("# original shell\n")

    def migrate(self, *args, ok=True):
        return self.bash('''source agent/migrate-ccs-to-magpie.sh
check_root() { :; }
prepare_process_env() { export PATH="$TEST_ROOT/bin:$PATH"; }
main --env "$@"
''', *args, ok=ok)

    def backups(self):
        return sorted((self.root / "state").glob("ccs-migration.*"))

    def test_success_backs_up_before_sync_and_retires_all_path_binaries(self):
        extra = self.script("extra/cc-switch", "#!/bin/sh\necho another\n")
        self.env["PATH"] = str(extra.parent) + ":" + self.env["PATH"]
        self.migrate()
        backup, = self.backups()
        self.assertEqual(backup.stat().st_mode & 0o777, 0o700)
        self.assertEqual((backup / "client.tar").stat().st_mode & 0o777, 0o600)
        with tarfile.open(backup / "client.tar") as archive:
            name = str(self.home / ".claude/settings.json").lstrip("/")
            self.assertEqual(archive.extractfile(name).read(), b'{"original":true}')
            self.assertIn(str(self.root / "bashrc").lstrip("/"), archive.getnames())
        self.assertFalse(self.legacy.exists())
        self.assertFalse(extra.exists())
        self.assertEqual(len(list((backup / "bin").iterdir())), 2)
        self.assertTrue((backup / "complete").exists())
        self.assertEqual((self.home / ".cc-switch/cc-switch.db").read_text(), "legacy database")
        self.assertIn("webdav:on", self.calls())
        self.assertIn("library:sync", self.calls())

    def test_sync_failure_keeps_ccs_and_original_backup_then_retry_succeeds(self):
        self.env["TEST_FAIL_CONFIG"] = "library:sync"
        self.migrate(ok=False)
        self.assertTrue(self.legacy.exists())
        self.assertEqual((self.root / "bashrc").read_text(), "# original shell\n")
        self.assertFalse((self.backups()[0] / "complete").exists())
        del self.env["TEST_FAIL_CONFIG"]
        self.migrate()
        self.assertFalse(self.legacy.exists())
        self.assertEqual(len(self.backups()), 2)
        self.assertEqual(self.calls().count("download:magpie"), 1)

    def test_local_backup_and_symlink_binary(self):
        target = self.root / "legacy-target"
        self.legacy.rename(target)
        self.legacy.symlink_to(target)
        local_backup = self.root / "source.magpie-backup"
        local_backup.write_text("encrypted fixture")
        self.migrate("--backup-file", local_backup)
        saved = self.backups()[0] / "bin/cc-switch.1"
        self.assertTrue(saved.is_symlink())
        self.assertEqual(saved.resolve(), target)
        self.assertFalse(self.legacy.is_symlink())
        self.assertIn("restore", self.calls())
        self.assertNotIn("webdav:on", self.calls())

    def test_running_client_or_service_prevents_changes(self):
        self.script("bin/pgrep", "#!/bin/sh\n[ \"$2\" = cc-switch ]\n")
        self.migrate(ok=False)
        self.assertEqual(self.backups(), [])
        self.assertTrue(self.legacy.exists())
        self.script("bin/pgrep", "#!/bin/sh\nexit 1\n")
        self.script("bin/systemctl", "#!/bin/sh\n[ \"$4\" = magpie.service ]\n")
        self.migrate(ok=False)
        self.assertEqual(self.backups(), [])
        self.assertFalse((self.root / "calls").exists())

    def test_skip_and_invalid_credentials_do_not_modify_client(self):
        self.migrate("--skip-config", ok=False)
        self.env["MAGPIE_PASSPHRASE"] = ""
        self.migrate(ok=False)
        self.assertTrue(self.legacy.exists())
        self.assertEqual(self.backups(), [])
        self.assertFalse((self.root / "calls").exists())

    def test_linked_native_config_backs_up_target_data(self):
        native = self.home / ".claude"
        target = self.root / "native-claude"
        native.rename(target)
        native.symlink_to(target, target_is_directory=True)
        self.migrate()
        with tarfile.open(self.backups()[0] / "client.tar") as archive:
            self.assertTrue(archive.getmember(str(native).lstrip("/")).issym())
            data = archive.extractfile(str(target / "settings.json").lstrip("/"))
            self.assertEqual(data.read(), b'{"original":true}')

    def test_backup_failure_prevents_download_and_uninstall(self):
        self.script("bin/tar", "#!/bin/sh\nexit 1\n")
        self.migrate(ok=False)
        self.assertTrue(self.legacy.exists())
        self.assertFalse((self.root / "calls").exists())

    def test_duplicate_and_linked_path_directories_retire_binary_once(self):
        linked_bin = self.root / "linked-bin"
        linked_bin.symlink_to(self.legacy.parent, target_is_directory=True)
        self.env["PATH"] = f"{linked_bin}:{self.legacy.parent}:" + self.env["PATH"]
        self.migrate()
        self.assertEqual(len(list((self.backups()[0] / "bin").iterdir())), 1)
        self.assertTrue((self.backups()[0] / "complete").exists())
