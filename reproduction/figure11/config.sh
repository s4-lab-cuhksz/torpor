# Shared settings for prepare.sh, fig11_job.sbatch and launch_client.sh.
# Edit the paths in the first block, keep the rest unless you know why.

# ---- paths (on GPFS, e.g. $PROJECT or $SCRATCH) ----
# BASE = the folder holding torpor/, torpor-client.sif, torpor-server.sif (run `pwd` there and paste it)
export BASE="${BASE:-/p/scratch/paj2615/remane1}"
export TORPOR_REPO="$BASE/torpor"                       # git clone of s4-lab-cuhksz/torpor
export FIG11_HOME="$BASE/torpor_fig11"                  # venv, patched scripts, traces, runs
export SERVER_SIF="$BASE/torpor-server.sif"             # your existing images
export CLIENT_SIF="$BASE/torpor-client.sif"
export WEIGHTS_SRC="$BASE/models"               # torch/hub/checkpoints + hf/hub (checked by prepare.sh)
export VENV="$FIG11_HOME/venv"                  # host python for router/sender/analysis
export PY_MODULE="Stages/2025 GCCcore/.13.3.0 Python/3.12.3"
export BIN="$FIG11_HOME/bin"                    # patched router/sender + helpers
export TRACE_DIR="$FIG11_HOME/traces"           # samples.npy + cached traces (same trace for every variant)
export RUNS_DIR="$FIG11_HOME/runs"
# server rebuilt from $TORPOR_REPO with two one-line fixes (empty = the image's /server_bin):
#   model_repo.hpp      host_addr = 0 (same as PaulAugsten/torpor-reproduction commit 79d1930)
#   memory_manager.hpp  valid_memory_address returns the lookup result
# Build or rebuild (no job running): bash build_server.sh   (see README)
export SERVER_BIN_DIR="${SERVER_BIN_DIR-$TORPOR_REPO/reproduction/figure11/server_bin_fixed}"

# ---- node local ----
export IPC_DIR=/dev/shm/ipc
export WEIGHTS_SHM=/dev/shm/torpor_weights

# ---- experiment ----
export PORT_BASE=20000          # upstream: 9000 (collides with node_exporter on 9100)
export LOAD_TIMEOUT=120         # s, router's first (load) request per client; upstream 5 s is too short on A100
export MEM_LIMIT_IN_GB=25
export IO_THREAD_NUM=4
export TRACE_MINUTES=31

# ---- CPU pinning (verify with: nvidia-smi topo -m) ----
export GPU_CORES_0="48-63"
export GPU_CORES_1="16-31"
export GPU_CORES_2="112-127"
export GPU_CORES_3="80-95"
export SERVER_CORES=""
export ROUTER_CORES="0-15"      # outside all GPU ranges
export SENDER_CORES="32-39"     # outside all GPU ranges

# ---- watchdog ----
export SERVER_READY_TIMEOUT=600     # s
export CLIENTS_READY_TIMEOUT=5400   # s (560 clients take ~30 min)
export MAX_RELAUNCHES=40            # client relaunches per run before giving up
export DRAIN_SEC=60                 # wait after the sender finished
export SCANCEL_ON_FAIL=1            # release the allocation when something crashes

# Patterns in server.log that count as a crash (extended regex)
# (server process death is always fatal; this also catches a hung server after a crash message
#  and the block manager's memory pool errors, which are followed by a crash anyway)
export SERVER_FATAL_RE='terminate called|Segmentation fault|core dumped|double free or corruption|Error: no free physical block|Error: cannot acquire block|acquire_block size too large|Error: cannot find physical block'