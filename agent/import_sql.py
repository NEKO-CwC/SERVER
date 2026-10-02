#!/usr/bin/env python3
"""Run cc-switch's mandatory import confirmation in an owned terminal."""

import errno
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time


ANSI = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")
PROMPT = b"Continue with import?"
SUCCESS = b"Configuration imported from "


def import_sql(sql_file, timeout=120):
    pid, terminal = pty.fork()
    if pid == 0:
        try:
            os.execvp("cc-switch", ["cc-switch", "config", "import", sql_file])
        except OSError as error:
            print(f"Cannot start cc-switch: {error}", file=sys.stderr, flush=True)
            os._exit(127)

    fcntl.ioctl(terminal, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 160, 0, 0))
    deadline = time.monotonic() + timeout
    tail = b""
    confirmed = False
    succeeded = False
    reaped = False
    status = None
    try:
        while time.monotonic() < deadline:
            if select.select([terminal], [], [], 0.1)[0]:
                try:
                    data = os.read(terminal, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    data = b""  # Linux PTYs report EIO after the child closes the slave.
                if data:
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                    tail = (tail + data)[-32768:]
                    # inquire/crossterm can request the terminal cursor position.
                    if b"\x1b[6n" in tail:
                        os.write(terminal, b"\x1b[1;1R")
                        tail = tail.replace(b"\x1b[6n", b"")
                    plain = ANSI.sub(b"", tail)
                    if not confirmed and PROMPT in plain:
                        os.write(terminal, b"y\r")
                        confirmed = True
                        tail = b""
                        plain = b""
                    if confirmed and SUCCESS in plain:
                        succeeded = True
                    continue

            ended, status = os.waitpid(pid, os.WNOHANG)
            if ended:
                reaped = True
                code = os.waitstatus_to_exitcode(status)
                if code != 0:
                    return code if code > 0 else 128 - code
                if not confirmed or not succeeded:
                    print("SQL import did not report confirmed success; no completion state will be saved.", file=sys.stderr)
                    return 1
                return 0

        print("SQL import timed out; stopping cc-switch. See the private import log.", file=sys.stderr)
        return 124
    finally:
        os.close(terminal)
        if not reaped:
            # Closing the owned PTY sends HUP; bound cleanup even if the child ignores it.
            cleanup_deadline = time.monotonic() + 3
            while time.monotonic() < cleanup_deadline:
                ended, _ = os.waitpid(pid, os.WNOHANG)
                if ended:
                    break
                time.sleep(0.05)
            else:
                os.killpg(pid, signal.SIGKILL)
                os.waitpid(pid, 0)


def interrupted(signum, frame):
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: import_sql.py FILE", file=sys.stderr)
        sys.exit(2)
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    sys.exit(import_sql(sys.argv[1]))
