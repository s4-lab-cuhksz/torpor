#!/usr/bin/env python3
"""Create JURECA versions of the Figure 11 router and sender from the upstream files.

Changes (everything else stays byte identical):
  router.py
    * client ports: 9000 + id  ->  PORT_BASE + id   (env PORT_BASE, default 20000)
    * load request timeout 5 s -> LOAD_TIMEOUT (env, default 120 s); measured requests keep 5 s
    * `docker run ... standalone-client` -> bash $BIN/launch_client.sh (apptainer + taskset),
      client stdout/stderr go to clients/client_<id>.log in the run directory
    * client loads are serialized across the 4 GPU managers with a file lock (SERIAL_LOAD=0 disables)
    * the fixed 8 s wait after a client launch polls the client's port instead (LAUNCH_WAIT=fixed restores it)
  sender_from_trace.py
    * trace directory '../tools' -> env TRACE_DIR

Every replacement is checked; the script exits non zero if upstream changed.
"""
import re
import sys
from pathlib import Path

if len(sys.argv) != 3:
    sys.exit("usage: patch_scripts.py <torpor_repo> <out_dir>")

repo, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)

# The Figure 11 versions differ from torpor/scripts/ (that router uses a different model mix,
# that sender lacks the per-minute trace cache), so only accept files with the Figure 11 markers.
ROUTER_OK = "model_mixed = ['resnet50', 'resnet101', 'resnet152', 'densenet169', 'densenet201', 'inception', 'efficientnet', 'bertqa']"
ROUTER_BAD = "model_mixed = ['densenet201'] * 4"
SENDER_OK = "_{mins}min_trace.npy"
candidates = [repo / "evaluation/figure11/test_scripts", repo / "evaluation/figure11", repo / "scripts"]


def find(name, ok, bad=None):
    for d in candidates:
        f = d / name
        if f.is_file():
            t = f.read_text()
            if ok in t and (bad is None or bad not in t):
                print(f"using {f}")
                return t
            print(f"skipping {f}: not the Figure 11 version")
    sys.exit(
        f"PATCH FAILED: no Figure 11 {name} found in {', '.join(map(str, candidates))}.\n"
        f"Restore it with:  git -C {repo} checkout -- evaluation/figure11/test_scripts\n"
        f"(see what changed with: git -C {repo} status)")


def must_sub(pattern, repl, text, count_expected, what):
    new, n = re.subn(pattern, repl, text)
    if n != count_expected:
        sys.exit(f"PATCH FAILED ({what}): expected {count_expected} match(es), found {n}")
    return new


# ---------------- router.py ----------------
router = find("router.py", ROUTER_OK, ROUTER_BAD)

header = (
    "import os as _os\n"
    "PORT_BASE = int(_os.environ.get('PORT_BASE', '20000'))\n"
    "LOAD_TIMEOUT = float(_os.environ.get('LOAD_TIMEOUT', '120'))\n"
    "LAUNCH_CLIENT = _os.path.join(_os.environ['BIN'], 'launch_client.sh')\n"
    "CLIENT_LOG_DIR = _os.path.join(_os.getcwd(), 'clients')\n"
    "_os.makedirs(CLIENT_LOG_DIR, exist_ok=True)\n"
    "import fcntl as _fcntl\n"
    "# One client load at a time across all GPU managers (SERIAL_LOAD=1, default): the server's\n"
    "# ModelRepo is a lock-free std::map singleton shared by the 4 executor threads, and concurrent\n"
    "# cold-start loads corrupt it ('parameter ptr not found', segfaults, device side asserts).\n"
    "SERIAL_LOAD = _os.environ.get('SERIAL_LOAD', '1') == '1'\n"
    "_LOAD_LOCK_PATH = _os.path.join(_os.getcwd(), '.client_load.lock')\n"
    "_load_lock_fd = None\n"
    "def _load_lock_acquire():\n"
    "    global _load_lock_fd\n"
    "    if SERIAL_LOAD:\n"
    "        _load_lock_fd = open(_LOAD_LOCK_PATH, 'a')  # own fd per process, flock excludes across processes\n"
    "        _fcntl.flock(_load_lock_fd, _fcntl.LOCK_EX)\n"
    "def _load_lock_release():\n"
    "    global _load_lock_fd\n"
    "    if _load_lock_fd is not None:\n"
    "        _fcntl.flock(_load_lock_fd, _fcntl.LOCK_UN)\n"
    "        _load_lock_fd.close()\n"
    "        _load_lock_fd = None\n"
    "import socket as _socket\n"
    "# Upstream sleeps a fixed 8 s after starting a client; the client listens after ~3 s (median).\n"
    "# LAUNCH_WAIT=port (default): poll the client's port, at most 60 s; LAUNCH_WAIT=fixed: upstream 8 s.\n"
    "LAUNCH_WAIT = _os.environ.get('LAUNCH_WAIT', 'port')\n"
    "def _wait_client_ready(client_id, limit=60.0):\n"
    "    import time\n"
    "    if LAUNCH_WAIT == 'fixed':\n"
    "        time.sleep(8)\n"
    "        return\n"
    "    deadline = time.time() + limit\n"
    "    while time.time() < deadline:\n"
    "        try:\n"
    "            with _socket.create_connection(('localhost', PORT_BASE + client_id), timeout=1):\n"
    "                return\n"
    "        except OSError:\n"
    "            time.sleep(0.2)\n"
)
router = header + router

# fixed 8 s wait after a client launch -> wait until the client listens
router = must_sub(r"\n                    time\.sleep\(8\)\n",
                  "\n                    _wait_client_ready(client_id)\n", router, 1, "launch wait")

# serialize the launch + first (ExecuteAfterLoad) request of each client across all managers
router = must_sub(r"(\n            if flag == '0':\n                client_id = msg\n)(                while True:\n)",
                  r"\1                _load_lock_acquire()\n\2", router, 1, "load lock acquire")
router = must_sub(r"(\n                    if is_success:\n                        break\n)(\s*\n            elif flag == '1': # execute\n)",
                  r"\1                _load_lock_release()\n\2", router, 1, "load lock release")

# the two docker run launches (mixed and single model)
docker_re = (r"os\.system\(f'docker run [^']*-e model_name=\{(mod_n|model_name)\}[^']*"
             r"standalone-client bash /start_with_server_id\.sh \{client_id\} \{server_id\} "
             r"endpoint\.py \{client_id \+ 9000\} &'\)")
router = must_sub(
    docker_re,
    lambda m: ("os.system(f'bash {LAUNCH_CLIENT} {client_id} {server_id} {" + m.group(1) +
               "} {client_id + PORT_BASE} >> {CLIENT_LOG_DIR}/client_{client_id}.log 2>&1 &')"),
    router, 2, "docker run")

# Load request (ExecuteAfterLoad) timeout: upstream 5 s, but the first request on a fresh executor
# takes ~7 s on JURECA A100s, and the router's retry path then crashes the server.
# Only this launch-phase request changes; the measured Execute requests keep 5 s.
router = must_sub(r"(else batch_size_limit\)\}, )timeout=5\)",
                  r"\1timeout=LOAD_TIMEOUT)", router, 1, "load timeout")

# all remaining 9000 + x port computations (code and one comment)
router = must_sub(r"str\(9000 \+ (client_id|func_id|func)\)", r"str(PORT_BASE + \1)",
                  router, 4, "port base")
if "9000" in router:
    sys.exit("PATCH FAILED: leftover '9000' in router.py")
if "docker" in router:
    sys.exit("PATCH FAILED: leftover 'docker' in router.py")
(out / "router.py").write_text(router)

# ---------------- sender_from_trace.py ----------------
sender = find("sender_from_trace.py", SENDER_OK)
sender = must_sub(r"data_path = '\.\./tools'",
                  "data_path = os.environ.get('TRACE_DIR', '../tools')",
                  sender, 1, "trace dir")
(out / "sender_from_trace.py").write_text(sender)

print(f"patched router.py and sender_from_trace.py written to {out}")