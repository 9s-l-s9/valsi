#!/usr/bin/env python3
"""Exercise the launcher template in real Bubblewrap mount namespaces.

Run with Guix-store paths for bash, bubblewrap, coreutils, and the ELF loader:
  python3 test/pi-launcher-test.py BASH BWRAP COREUTILS LOADER
This smoke test needs unprivileged user namespaces; it does not run an agent.
"""
# SPDX-License-Identifier: GPL-3.0-or-later

from pathlib import Path
import socket
import subprocess
import sys
import tempfile

bash, bwrap, coreutils, loader = sys.argv[1:]
template = (Path(__file__).parent.parent / "scripts/pi-launcher.sh.in").read_text()
for token, value in {
    "BASH": bash, "BWRAP": bwrap, "COREUTILS": coreutils,
    "LOADER_DIR": "/lib64", "LOADER_NAME": "ld-test.so", "LOADER": loader,
    "RUNTIME": bash + "/bin/bash",
}.items():
    template = template.replace("@" + token + "@", value)

for layout in ("absent", "directory", "symlink"):
    with tempfile.TemporaryDirectory(prefix="valsi-launcher-") as tmp:
        root = Path(tmp)
        for directory in ("gnu", "proc", "dev", "tmp", "home/test", "srv/project",
                          "run/user/1000", "var/guix", "bin", "usr/bin"):
            (root / directory).mkdir(parents=True, exist_ok=True)
        (root / "bin/sh").symlink_to(bash + "/bin/bash")
        (root / "usr/bin/env").symlink_to(coreutils + "/bin/env")
        (root / "launcher").write_text(template)
        (root / "launcher").chmod(0o755)
        for name, shebang in (("shell", "/bin/sh"), ("env", "/usr/bin/env bash")):
            helper = root / "srv/project" / name
            helper.write_text("#!" + shebang + "\nprintf 'helper-ok\\n'\n")
            helper.chmod(0o755)
        if layout != "absent":
            target = root / ("usr/lib64" if layout == "symlink" else "lib64")
            target.mkdir()
            (target / "keep").write_text("preserved")
            (target / "alias").symlink_to("keep")
            # The old loader is replaced in the namespace, not on disk.
            (target / "ld-test.so").write_text("old-loader")
            if layout == "symlink":
                (root / "lib64").symlink_to("usr/lib64")
        with socket.socket(socket.AF_UNIX) as runtime, socket.socket(socket.AF_UNIX) as daemon:
            runtime.bind(str(root / "run/user/1000/agent.sock"))
            daemon.bind(str(root / "var/guix/daemon.sock"))
            command = [bwrap + "/bin/bwrap", "--dev-bind", tmp, "/",
                       "--ro-bind", "/gnu", "/gnu", "--proc", "/proc", "--dev", "/dev",
                       "--setenv", "HOME", "/home/test", "--setenv", "PATH",
                       bash + "/bin:" + coreutils + "/bin", "--chdir", "/srv/project"]
            checks = '''set -eu
[[ "$PWD" == /srv/project && "$HOME" == /home/test ]]
[[ -S /run/user/1000/agent.sock && -S /var/guix/daemon.sock ]]
[[ -r /lib64/ld-test.so ]]
[[ "$(./shell)" == helper-ok && "$(./env)" == helper-ok ]]
'''
            if layout != "absent":
                checks += '[[ "$(cat /lib64/keep)" == preserved && -L /lib64/alias ]]\n'
            subprocess.run(command + ["/launcher", "-c", checks], check=True)
            invalid = subprocess.run(command + ["--setenv", "HOME", "/missing",
                                               "/launcher", "-c", "exit 99"],
                                     capture_output=True, text=True)
            assert invalid.returncode == 1, invalid
            assert "HOME must name an existing directory" in invalid.stderr
        if layout == "absent":
            assert not (root / "lib64").exists(), "launcher created a host directory"
        else:
            assert (target / "ld-test.so").read_text() == "old-loader"
        assert not (root / "missing").exists()
        print(layout + ": filesystem, sockets, cwd, shebangs, loader, invalid HOME OK")
