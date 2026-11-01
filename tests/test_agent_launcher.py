import json

from test_installers import AgentFixture


class AgentLauncherTests(AgentFixture):
    def test_claude_launch_preserves_args_without_reading_old_provider(self):
        self.script("bin/cc-switch", '''#!/bin/sh
touch "$TEST_ROOT/old-provider-read"
exit 1
''')
        self.script("bin/claude", '''#!/usr/bin/env python3
import json, os, pathlib, sys
pathlib.Path(os.environ['TEST_ROOT'], 'claude-launch.json').write_text(json.dumps({
    'args': sys.argv[1:], 'sandbox': os.environ.get('IS_SANDBOX'),
    'base': os.environ.get('ANTHROPIC_BASE_URL')}))
''')
        self.env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:3425"
        self.bash('export PATH="$TEST_ROOT/bin:$PATH"\nbash agent/cc.sh --model fixture-model')
        result = json.loads((self.root / "claude-launch.json").read_text())
        self.assertEqual(result["args"], ["--dangerously-skip-permissions", "--model", "fixture-model"])
        self.assertEqual(result["sandbox"], "true")
        self.assertEqual(result["base"], self.env["ANTHROPIC_BASE_URL"])
        self.assertFalse((self.root / "old-provider-read").exists())
