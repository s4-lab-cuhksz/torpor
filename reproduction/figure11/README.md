# Torpor Figure 11 on JURECA (Slurm + Apptainer)

Policy comparison of Figure 11: Torpor, Torpor-FIFO, Torpor-Block, Torpor-LRU and
Torpor-Random, 320 to 560 functions over the 8-model mix, 4 GPUs, 25 GB model memory
per GPU, 31-minute trace.

## Changes against upstream

### Server: two one-line fixes
The image (`docker://paulaugsten/torpor:server`) contains the plain upstream server.
The job binds a rebuilt server over `/server_bin` (`SERVER_BIN_DIR` in `config.sh`,
binaries in `server_bin_fixed/` in this folder).

| File | Fix | Without it |
|---|---|---|
| `include/server/model_repo.hpp` | `host_addr = 0` in `load_model_h2d_at_start` (the same change as commit `79d1930` of PaulAugsten/torpor-reproduction, used for Figures 6 to 10) | a failed weight lookup during loading uses an uninitialised pointer and the server crashes or silently corrupts memory |
| `include/server/memory_manager.hpp` | `valid_memory_address` returns the lookup result instead of always `false` | input/activation pointers are never translated, so a model computes correctly only on the GPU it was loaded on. Wrong outputs and device-side asserts (bert-qa embedding) once eviction moves models between GPUs |

The binaries are not in git: they are built from the fixed sources of this repository.

### Building the server: `build_server.sh`
```bash
bash build_server.sh        # login node, no Figure 11 job running
```
* compiles `server` and `libwapper.so` inside `torpor-server.sif`, with this repository
  mounted at `/gpu-swap`, using upstream's configuration (`dockerfiles/server.Dockerfile`)
* installs both into `server_bin_fixed/` and writes `build_info.txt` there (date, commit,
  uncommitted changes, md5 sums)
* refuses to build if either fix is missing from the sources, or while a Figure 11 job is running
* build directory `$FIG11_HOME/server_build` (`SERVER_BUILD_DIR`); the first build takes
  ~3 min, later builds only recompile what changed
* only `server` contains the fixes. `libwapper.so` (sic, upstream's name for the CUDA
  kernel-registration wrapper) is built from unchanged upstream code

Rebuild after any change in `include/` or `src/`. A build in a different directory gives a
different md5 for `server`, because build paths end up in the binary; the code is the same.

### Router and sender: patched copies
`patch_scripts.py` writes JURECA versions of `test_scripts/router.py` and
`test_scripts/sender_from_trace.py` to `$FIG11_HOME/bin/`. The upstream files stay
untouched and every replacement is checked.

* `docker run … standalone-client` → `launch_client.sh` (Apptainer + taskset), one log per client
* client ports `9000 + id` → `PORT_BASE + id` (20000; 9100 is node_exporter on JURECA)
* **client loads serialized** across the 4 GPU managers with a file lock (`SERIAL_LOAD=1`).
  The server's `ModelRepo` is a lock-free `std::map` shared by all executor threads, and
  concurrent loads corrupt it (`parameter ptr not found`, segfaults)
* load request (ExecuteAfterLoad) timeout 5 s → `LOAD_TIMEOUT` (120 s), because the first request takes ~7 s on A100;
  measured requests keep 5 s
* fixed 8 s wait after a client launch → poll the client's port (`LAUNCH_WAIT=fixed` restores upstream)
* sender: trace directory from `TRACE_DIR`

## Files
| File | What |
|---|---|
| `config.sh` | all paths and settings (ports, cores, timeouts, `SERVER_BIN_DIR`) |
| `prepare.sh` | once, on a login node: images, venv, weights, patched scripts |
| `patch_scripts.py` | makes `router.py` / `sender_from_trace.py` JURECA ready |
| `launch_client.sh` | started by the router once per function |
| `fig11_job.sbatch` | the job: every variant for the given function counts |
| `build_server.sh` | builds the fixed server into `server_bin_fixed/` |
| `server_bin_fixed/` | output of `build_server.sh`, bound over `/server_bin` by the job (git-ignored) |
| `.gitignore` | ignores `server_bin_fixed/` and the Slurm `torpor-fig11-*.out/.err` files |

The SLO analysis is upstream's `evaluation/figure11/figure11_analyze_router_log.py`
(unchanged, copied to `$BIN` by `prepare.sh`). The diagnosis scripts used to find the
server bugs stay in `evaluation/figure11/`.
`router.py` and `sender_from_trace.py` in this folder are old copies and are not used:
`patch_scripts.py` reads upstream's `evaluation/figure11/test_scripts/`.

## Steps
1. Edit `config.sh` (`BASE`) and `--account` in `fig11_job.sbatch`.
2. Images (login node):
   ```bash
   apptainer build torpor-server.sif docker://paulaugsten/torpor:server
   apptainer build torpor-client.sif docker://paulaugsten/torpor:client
   ```
3. Login node: `bash prepare.sh`, then `bash build_server.sh`.
4. Smoke test: `sbatch --time=02:00:00 --export=ALL,FUNC_COUNTS="40",VARIANTS="torpor",SENDER_FLAG=0 fig11_job.sbatch`
5. Submit from this folder, for example all four policy variants at one count:
   ```bash
   sbatch --export=ALL,FUNC_COUNTS="560",VARIANTS="torpor fifo block lru",SENDER_FLAG=0 fig11_job.sbatch
   ```
   One run takes ~65 min at 560 functions (~30 min client loading, 31 min replay).
   Only one job may use `FIG11_HOME` at a time; chain jobs with `--dependency=afterany:<jobid>`.

## Output
`$FIG11_HOME/runs/job_<id>/`
* `job.log` progress, `summary.csv` results, `topo.txt` GPU/CPU map
* `F<count>_<variant>/` with `server.log`, `router.log`, `sender.log`, `clients/`,
  `analysis.txt` (SLO), `validity.txt` (output check), `meta.txt`
* `FAILED.txt` on a crash: reason, log tails, client tracebacks, nvidia-smi

`$FIG11_HOME/runs/summary_all_v2.csv` collects all jobs (columns include `bad_outputs`, `bad_functions`).

## Output validity check
The upstream SLO script only measures latency, so a request with a wrong result counts
as a success. After each run the job therefore compares every output with the reference
output of a clean F=40 run (every endpoint uses a fixed input) and writes `validity.txt`.
`job.log` shows a WARNING if any output is wrong. **Judge a run by both numbers.**

