import os
import shutil

from test_installers import AgentFixture


class SQLImportTests(AgentFixture):
    def setUp(self):
        super().setUp()
        self.sql = self.root / "local config.sql"
        self.sql.write_text("select 1;\n")

    def test_redirected_cli_reproduces_prompt_error_but_installer_imports(self):
        shutil.copy(self.root / "payload/cc-switch", self.root / "bin/cc-switch")
        self.bash('''export PATH="$TEST_ROOT/bin:$PATH"
cc-switch config import "$1" >"$TEST_ROOT/old-import.log" 2>&1
''', self.sql, ok=False)
        self.assertIn("Prompt failed", (self.root / "old-import.log").read_text())
        self.run_agent("--sql-file", self.sql)
        self.assertTrue((self.root / "state/config-success").is_file())
        self.assertTrue((self.root / "config/cc-switch.db").is_file())
        self.assertFalse((self.root / "state/config-last.log").exists())

    def test_cancelled_import_is_not_success_even_with_existing_database(self):
        self.run_agent("--sql-file", self.sql)
        self.sql.write_text("select 2;\n")
        self.env["TEST_IMPORT_CANCEL"] = "1"
        self.run_agent("--sql-file", self.sql, ok=False)
        self.assertTrue((self.root / "config/cc-switch.db").is_file())
        self.assertFalse((self.root / "state/config-success").exists())
        self.assertIn("did not report confirmed success", (self.root / "state/config-last.log").read_text())

    def test_import_failure_is_retried(self):
        self.env["TEST_FAIL_CONFIG"] = "config:import"
        self.run_agent("--sql-file", self.sql, ok=False)
        self.assertFalse((self.root / "state/config-success").exists())
        del self.env["TEST_FAIL_CONFIG"]
        self.run_agent("--sql-file", self.sql)
        self.assertEqual(self.calls().count("config:import"), 2)
        self.assertTrue((self.root / "state/config-success").is_file())

    def test_unknown_prompt_is_not_confirmed_and_timeout_reaps_child(self):
        self.script("bin/cc-switch", '''#!/usr/bin/env python3
import os, pathlib
root = pathlib.Path(os.environ['TEST_ROOT'])
(root / 'import-child.pid').write_text(str(os.getpid()))
input('Unrelated destructive confirmation? ')
(root / 'unexpected-answer').write_text('answered')
''')
        result = self.bash('''export PATH="$TEST_ROOT/bin:$PATH"
python3 -c 'import sys; sys.path.insert(0, "agent"); from import_sql import import_sql; sys.exit(import_sql(sys.argv[1], timeout=0.5))' "$1"
''', self.sql, ok=False)
        self.assertEqual(result.returncode, 124)
        self.assertFalse((self.root / "unexpected-answer").exists())
        with self.assertRaises(ProcessLookupError):
            os.kill(int((self.root / "import-child.pid").read_text()), 0)
