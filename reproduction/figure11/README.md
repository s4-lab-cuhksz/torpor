# Figure 11: Torpor variants with mixed models

SLO compliance, i.e. the share of functions whose P98 latency is within 80 ms
(CV models) or 200 ms (bertqa), at 320/400/480/560 functions over 8 mixed
models (`router.py -m mixed`: function _i_ runs model _i_ mod 8 out of
resnet50/101/152, densenet169/201, inception, efficientnet, bertqa). Each run
replays a 31-minute Azure-trace workload. Five variants differ in one knob:

| Variant  | Paper name    | Change against Torpor              |
| -------- | ------------- | ---------------------------------- |
| `torpor` | Torpor        | none (SLO-aware queueing, `-p sa`) |
| `fifo`   | Torpor-FIFO   | router `-p fifo`                   |
| `block`  | Torpor-Block  | server env `BLOCK_MANAGER=Fixed`   |
| `lru`    | Torpor-LRU    | server env `EVICT_POLICY=LRU`      |
| `random` | Torpor-Random | server env `SCHEDULE_POLICY=RAND`  |

`random` runs at 320 and 400 only, as annotated in the original
`evaluation/figure11/Figure11_README.md` (override with `RANDOM_MAX_FUNC`).
The trace is generated once per function count and cached as
`../../tools/req_arrivals_<n>_31min_trace.npy`, so all variants at one count
see the same requests.

The server image must contain both server fixes, `host_addr` and
`valid_memory_address` (see [`../images/README.md`](../images/README.md)).
Without the second, a model returns wrong outputs once it runs on a GPU other
than the one it was loaded on.

## Run everything

```bash
mkdir -p logs_batch && sbatch -A <project> sbatch_figure11.sh          # 320 400 480 560
mkdir -p logs_batch && sbatch -A <project> sbatch_figure11.sh 320 400  # or a subset per job
# or interactively on a compute node, venv active:
./run_all_figure11.sh <FUNC_NUM>   # every variant at one count (KEEP_LOGS=1 keeps old logs)
```

Chunked jobs must run one after the other (`--dependency=afterany:<jobid>`,
see `sbatch_figure11.sh`). They share this directory, and stale processes are
killed by name, not by job.

## Individual runs

```bash
./run_fig11_variant.sh <variant> <FUNC_NUM>   # e.g. ./run_fig11_variant.sh lru 560
```

A run at 560 functions takes about 60 minutes: 30 for client loading, 30 for
the replay.

## Changes against original repo

`router.py` and `sender_from_trace.py` are the original's
`evaluation/figure11/test_scripts/` versions with these changes (`diff` shows
them all):

- Clients run in one shared Apptainer instance instead of `docker run`, each
  pinned to the cores local to its GPU (`NUMA_CORES`), on port
  `CLIENT_PORT_BASE + id` (20000 instead of 9000, see `../common/ports.sh`).
- **Client loads are serialized** across the 4 GPU managers with a file lock.
  The server's `ModelRepo` is a `std::map` shared by all GPUs without a lock,
  and concurrent loads corrupt it (`parameter ptr not found`, segfaults).
  `SERIAL_LOAD=0` turns the lock off.
- The fixed 8 s wait after a client launch polls the client's port instead.
- The sender finds `../../tools` relative to its own file, because it runs in
  the run directory.

## Outputs

- `logs_fig11/<variant>_<n>f_result.txt`: SLO summary (original's analyzer)
- `logs_fig11/<variant>_<n>f/`: every log of that run (`server.log`,
  `router.log`, `sender.log`, the server's own logs, `clients/`), and
  `FAILED.txt` if the run was aborted

A run is aborted as soon as the server dies or `server.log` shows a crash, a
CUDA assert or a `ModelRepo` lookup error (`FATAL_RE` in
`run_fig11_variant.sh`). After a device-side assert the CUDA context is broken
and every later output is garbage.

The analyzer's "Total function count" is the number of functions in
`router.log`, not FUNC_NUM.
