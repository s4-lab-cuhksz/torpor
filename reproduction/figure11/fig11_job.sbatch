#!/bin/bash
#SBATCH --job-name=torpor-fig11
#SBATCH --account=paj2615
#SBATCH --partition=dc-gpu
#SBATCH --gres=gpu:4,mem512:1
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --exclusive
#SBATCH --time=12:00:00
#SBATCH --output=torpor-fig11-%j.out
#SBATCH --error=torpor-fig11-%j.err
#SBATCH --signal=B:TERM@600
#
# Figure 11 (Torpor, FIFO, Block, LRU, Random) on one JURECA dc-gpu node.
# Submit from the folder that holds config.sh:
#   sbatch --export=ALL,FUNC_COUNTS="320",VARIANTS="torpor fifo block lru random" fig11_job.sbatch
# One count takes about 4.5 to 5 h, so use one or two counts per job (24 h limit).
#
# Optional settings (pass them in --export):
#   SENDER_FLAG=1      skip the router's clear up / warm up step before sending (upstream default: 0)
#   ABORT_ON_ASSERT=0  keep running after a CUDA device side assert (default 1: abort, because the
#                      GPU context is broken afterwards and every later result is garbage)
# Example, F40 without warm up:
#   sbatch --time=02:00:00 --export=ALL,FUNC_COUNTS="40",VARIANTS="torpor",SENDER_FLAG=1 fig11_job.sbatch

set -Eeuo pipefail
SETUP_DIR="${SLURM_SUBMIT_DIR:-$(pwd)}"
source "$SETUP_DIR/config.sh"

FUNC_COUNTS="${FUNC_COUNTS:-320}"
VARIANTS="${VARIANTS:-torpor fifo block lru random}"
RANDOM_ALL_COUNTS="${RANDOM_ALL_COUNTS:-0}"   # upstream ran Random only for 320 and 400
STALL_TIMEOUT="${STALL_TIMEOUT:-900}"         # s without a finished request while sending
SENDER_FLAG="${SENDER_FLAG:-0}"               # 0 = upstream (clear up + warm up), 1 = no warm up
ABORT_ON_ASSERT="${ABORT_ON_ASSERT:-1}"
NGPU=4

# A device side assert (e.g. an embedding lookup reading corrupted memory) breaks the CUDA context
# of that GPU for good; the server then prints one error line per relayed call and returns garbage.
if [[ "$ABORT_ON_ASSERT" == 1 ]]; then
    SERVER_FATAL_RE="$SERVER_FATAL_RE|device-side assert|Assertion .* failed|cuda assert|cudnn assert"
    # ModelRepo corruption (lookup into a racing std::map); the run's numbers are not valid after this
    SERVER_FATAL_RE="$SERVER_FATAL_RE|parameter ptr not found|Memory access error|fails to find malloc"
fi

JOB_ID="${SLURM_JOB_ID:-manual_$$}"
JOB_DIR="$RUNS_DIR/job_$JOB_ID"
JOB_LOG="$JOB_DIR/job.log"
ACTIVE_FILE="$FIG11_HOME/ACTIVE_JOB"
CLIENT_INSTANCE="fig11_clients_$JOB_ID"
export CLIENT_INSTANCE PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

SUMMARY_HDR="F,variant,sender_flag,slo_compliant_pct,finished_requests,client_timeouts,bad_outputs,bad_functions,run_dir"
SUMMARY_ALL="$RUNS_DIR/summary_all_v2.csv"   # new columns, so a new file next to the old summary_all.csv

CUR_RUN_DIR=""; SERVER_PID=""; ROUTER_PID=""; SENDER_PID=""; HEALTH_MSG=""; EXIT_DESC=""

mkdir -p "$JOB_DIR"
log() { echo "$(date '+%F %T') [job $JOB_ID] $*" | tee -a "$JOB_LOG"; }

# ------------------------------------------------------------------ failure handling
die() {
    trap - ERR
    # the report must never abort halfway (e.g. SIGPIPE from "| head" under pipefail)
    set +e +o pipefail
    local reason="$*"
    log "FATAL: $reason"
    {
        echo "job $JOB_ID FAILED at $(date '+%F %T') on $(hostname)"
        echo "reason : $reason"
        echo "run dir: ${CUR_RUN_DIR:-none}"
        if [[ -n "$CUR_RUN_DIR" ]]; then
            for f in server.log router_stdout.log router.log sender.log; do
                [[ -f "$CUR_RUN_DIR/$f" ]] || continue
                echo; echo "----- last 40 lines of $f -----"; tail -n 40 "$CUR_RUN_DIR/$f"
            done
            # first assert in server.log with the operations right before it
            if [[ -f "$CUR_RUN_DIR/server.log" ]]; then
                L=$(grep -n -m1 -E "assert|Assertion" "$CUR_RUN_DIR/server.log" | cut -d: -f1)
                if [[ -n "$L" ]]; then
                    echo; echo "----- server operations before the first assert (line $L) -----"
                    head -n "$L" "$CUR_RUN_DIR/server.log" | grep -E "^(Server|Controller)" | tail -n 20
                    echo "----- first assert -----"; sed -n "${L}p" "$CUR_RUN_DIR/server.log"
                fi
            fi
            # Torpor's own spdlog files (server, one per GPU executor)
            for f in "$CUR_RUN_DIR"/log_cuda_server.txt "$CUR_RUN_DIR"/log_executor_*.txt; do
                [[ -f "$f" ]] || continue
                echo; echo "----- last 25 lines of ${f#$CUR_RUN_DIR/} -----"; tail -n 25 "$f"
            done
            echo; echo "----- client logs with a Python traceback -----"
            grep -l "Traceback" "$CUR_RUN_DIR"/clients/*.log 2>/dev/null | head -20 || true
            first=$(grep -l "Traceback" "$CUR_RUN_DIR"/clients/*.log 2>/dev/null | head -1 || true)
            [[ -n "$first" ]] && { echo "----- $first -----"; tail -n 30 "$first"; }
            # always show the first clients, stdout and Torpor client lib log
            for c in 0 1; do
                for f in "$CUR_RUN_DIR/clients/client_$c.log" "$CUR_RUN_DIR/clients/log_client_$c.txt"; do
                    [[ -f "$f" ]] || continue
                    echo; echo "----- last 25 lines of ${f#$CUR_RUN_DIR/} -----"; tail -n 25 "$f"
                done
            done
            echo; echo "----- files in run dir -----"; ls -la "$CUR_RUN_DIR" "$CUR_RUN_DIR/clients" 2>&1 | head -60
        fi
        echo; echo "----- kernel messages (if readable) -----"; dmesg -T 2>/dev/null | tail -n 15 || echo "dmesg not readable"
        echo; echo "----- nvidia-smi -----"; nvidia-smi 2>&1 || true
        echo; echo "----- free -g -----"; free -g 2>&1 || true
    } > "$JOB_DIR/FAILED.txt" 2>&1
    [[ -n "$CUR_RUN_DIR" ]] && cp "$JOB_DIR/FAILED.txt" "$CUR_RUN_DIR/FAILED.txt"
    exit 1
}

kill_pattern() { pkill "$1" -u "$USER" -f "$2" 2>/dev/null || true; }

descendants() {   # all processes below pid $1, from one ps snapshot
    ps -e -o pid=,ppid= | awk -v root="$1" '{par[$1]=$2} END {
        for (p in par) { q = p; while ((q in par) && q != root && q > 1) q = par[q]; if (q == root && p != root) print p } }'
}

kill_everything() {
    apptainer instance stop -F "$CLIENT_INSTANCE" >/dev/null 2>&1 || true
    local sig pids
    for sig in -TERM -KILL; do
        pids=$(descendants $$ || true)
        [[ -n "$pids" ]] && { kill "$sig" $pids 2>/dev/null || true; }
        kill_pattern "$sig" '(Apptainer|Singularity) runtime parent'
        kill_pattern "$sig" "$BIN/sender_from_trace.py"
        kill_pattern "$sig" "$BIN/router.py"
        kill_pattern "$sig" "$BIN/launch_client.sh"
        kill_pattern "$sig" "/endpoint.py"
        kill_pattern "$sig" "$CLIENT_SIF"
        kill_pattern "$sig" "$SERVER_SIF"
        kill_pattern "$sig" '^(\./server|/server_bin/server)$'
        [[ "$sig" == -TERM ]] && sleep 5
    done
    SERVER_PID=""; ROUTER_PID=""; SENDER_PID=""
}

gpu_busy() { nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | grep -c . || true; }

wait_gpu_free() {   # $1 = die (1) or only warn (0)
    local i
    for i in $(seq 1 18); do
        [[ "$(gpu_busy)" -eq 0 ]] && return 0
        sleep 5
    done
    if [[ "$1" == 1 ]]; then die "GPU memory still held after cleanup: $(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader | tr '\n' ';')"; fi
    log "WARNING: GPU still busy after cleanup"
}

on_exit() {
    local rc=$?
    set +e
    trap - ERR TERM INT
    log "exit code $rc, cleaning up"
    kill_everything
    wait_gpu_free 0
    rm -rf "$WEIGHTS_SHM" "$IPC_DIR"
    [[ -f "$ACTIVE_FILE" && "$(cat "$ACTIVE_FILE")" == "$JOB_ID" ]] && rm -f "$ACTIVE_FILE"
    if [[ $rc -ne 0 ]]; then
        log "job FAILED, details in $JOB_DIR/FAILED.txt"
        if [[ "$SCANCEL_ON_FAIL" == 1 && -n "${SLURM_JOB_ID:-}" ]]; then
            log "releasing the allocation (scancel $SLURM_JOB_ID)"
            scancel "$SLURM_JOB_ID"
        fi
    else
        log "job finished OK, results in $JOB_DIR/summary.csv"
    fi
}
trap on_exit EXIT
trap 'die "command failed (line $LINENO, exit $?): $BASH_COMMAND"' ERR
trap 'die "received SIGTERM/SIGINT (walltime limit or scancel)"' TERM INT

# ------------------------------------------------------------------ helpers
expand_cores() { local IFS=, r; for r in $1; do [[ $r == *-* ]] && seq "${r%-*}" "${r#*-}" || echo "$r"; done; }

exit_desc() {   # sets EXIT_DESC: exit status of a finished background child (+ signal name)
    local rc=0
    wait "$1" 2>/dev/null || rc=$?
    if (( rc > 128 )); then EXIT_DESC="exit $rc = killed by SIG$(kill -l $((rc - 128)) 2>/dev/null || echo '?')"
    else EXIT_DESC="exit $rc"; fi
}

health() {   # sets HEALTH_MSG and returns 1 when something died
    if [[ -n "$SERVER_PID" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
        exit_desc "$SERVER_PID"
        HEALTH_MSG="server process died, $EXIT_DESC (see server.log, log_cuda_server.txt)"; return 1; fi
    if [[ -n "$SERVER_PID" ]] && grep -Eq "$SERVER_FATAL_RE" "$CUR_RUN_DIR/server.log" 2>/dev/null; then
        HEALTH_MSG="crash message in server.log: $(grep -Em1 "$SERVER_FATAL_RE" "$CUR_RUN_DIR/server.log")"; return 1; fi
    if [[ -n "$ROUTER_PID" ]] && ! kill -0 "$ROUTER_PID" 2>/dev/null; then
        exit_desc "$ROUTER_PID"
        HEALTH_MSG="router died, $EXIT_DESC (see router_stdout.log)"; return 1; fi
    return 0
}

count_re()    { { grep -cE "$1" "$CUR_RUN_DIR/$2" 2>/dev/null || true; } | head -1; }
uniq_ids()    { { grep -oE "$1" "$CUR_RUN_DIR/router.log" 2>/dev/null || true; } | awk '{print $'"$2"'}' | sort -u | wc -l; }
loaded_cnt()  { uniq_ids 'ExecuteAfterLoad [0-9]+ on server [0-9]+ resp:' 2; }
tried_cnt()   { uniq_ids 'Try launching [0-9]+ on server' 3; }
launch_cnt()  { local n; n=$(count_re 'Try launching' router.log); echo "${n:-0}"; }
done_cnt()    { local n; n=$(count_re 'end-to-end time' router.log); echo "${n:-0}"; }
timeout_cnt() { local n; n=$(count_re 'Func [0-9]+ on server [0-9]+ timeout' router.log); echo "${n:-0}"; }

check_ports_free() {
    local lo=$PORT_BASE hi=$((PORT_BASE + $1 - 1)) busy
    busy=$(ss -lntH | awk -v lo="$lo" -v hi="$hi" '{n=split($4,a,":"); p=a[n]+0; if (p>=lo && p<=hi) print p}' | sort -u | tr '\n' ' ')
    [[ -z "$busy" ]] || die "ports already in use in $lo..$hi: $busy (check: ss -lntp)"
}

variant_policy() { [[ "$1" == fifo ]] && echo fifo || echo sa; }
variant_env() {
    case "$1" in
        torpor|fifo) echo "" ;;
        block)  echo "BLOCK_MANAGER=Fixed" ;;
        lru)    echo "EVICT_POLICY=LRU" ;;
        random) echo "SCHEDULE_POLICY=RAND" ;;
    esac
}

# ------------------------------------------------------------------ one run
run_one() {
    local F=$1 variant=$2 policy extra t0 n prev_n last_change
    policy=$(variant_policy "$variant"); extra=$(variant_env "$variant")
    CUR_RUN_DIR="$JOB_DIR/F${F}_${variant}"
    [[ -e "$CUR_RUN_DIR" ]] && die "run dir $CUR_RUN_DIR already exists"
    mkdir -p "$CUR_RUN_DIR/clients"
    rm -f "$CUR_RUN_DIR/router.log" "$CUR_RUN_DIR/server.log"
    log "===== F=$F variant=$variant (router -p $policy, server env: ${extra:-none}, sender flag $SENDER_FLAG) -> $CUR_RUN_DIR"
    {
        echo "date=$(date '+%F %T') node=$(hostname) job=$JOB_ID"
        echo "F=$F variant=$variant policy=$policy server_extra_env=$extra"
        echo "MEM_LIMIT_IN_GB=$MEM_LIMIT_IN_GB IO_THREAD_NUM=$IO_THREAD_NUM PORT_BASE=$PORT_BASE TRACE_MINUTES=$TRACE_MINUTES LOAD_TIMEOUT=${LOAD_TIMEOUT:-120}"
        echo "SENDER_FLAG=$SENDER_FLAG ABORT_ON_ASSERT=$ABORT_ON_ASSERT SERVER_CORES=${SERVER_CORES:-none} CLIENT_CORES=${CLIENT_CORES:-per_gpu}"
        echo "torpor_rev=$(git -C "$TORPOR_REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
        echo "SERVER_BIN_DIR=${SERVER_BIN_DIR:-image} server_md5=$(md5sum "${SERVER_BIN_DIR:-/nonexistent}/server" 2>/dev/null | cut -d' ' -f1)"
    } > "$CUR_RUN_DIR/meta.txt"

    # clean slate
    kill_everything
    wait_gpu_free 1
    rm -rf "$IPC_DIR"; mkdir -p "$IPC_DIR"
    check_ports_free "$F"

    # 1) server
    local envs="MEM_LIMIT_IN_GB=$MEM_LIMIT_IN_GB,IO_THREAD_NUM=$IO_THREAD_NUM"
    [[ -n "$extra" ]] && envs="$envs,$extra"
    local pin=()
    [[ -n "$SERVER_CORES" ]] && pin=(taskset -c "$SERVER_CORES")
    # start.sh would drop apptainer's driver path from LD_LIBRARY_PATH, so start the binary directly.
    # The server writes log_cuda_server.txt / log_executor_<gpu>.txt into its cwd, and the SIF is
    # read only, so it runs in the run dir (bound to /work).
    # Server start script (runs inside the container, cwd /work = run dir):
    #  * stdout/stderr line buffered, so the last message before a crash is not lost in the buffer
    #  * glibc's libSegFault (if the image has it) prints a backtrace into server.log on a crash
    cat > "$CUR_RUN_DIR/start_server.sh" <<'EOS'
cd /work
PRE=/server_bin/libwapper.so
SEGV=$(ls /lib/x86_64-linux-gnu/libSegFault.so /usr/lib/x86_64-linux-gnu/libSegFault.so 2>/dev/null | head -n 1)
if [ -n "$SEGV" ]; then
    PRE="$PRE:$SEGV"
    export SEGFAULT_SIGNALS="segv bus abrt ill fpe"
    echo "[start_server] crash backtraces enabled ($SEGV)"
else
    echo "[start_server] libSegFault not in image, no crash backtrace"
fi
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}
export LD_PRELOAD=$PRE
if command -v stdbuf >/dev/null 2>&1; then
    exec stdbuf -oL -eL /server_bin/server
else
    echo "[start_server] stdbuf not in image, output stays buffered"
    exec /server_bin/server
fi
EOS
    # SERVER_BIN_DIR (config.sh): rebuilt server + libwapper.so bound over the image's /server_bin
    srvbin=()
    [[ -n "${SERVER_BIN_DIR:-}" ]] && srvbin=(--bind "$SERVER_BIN_DIR:/server_bin")
    ( cd "$CUR_RUN_DIR" && exec "${pin[@]}" apptainer exec --nv --cleanenv \
          --bind "$IPC_DIR:/cuda" --bind "$CUR_RUN_DIR:/work" "${srvbin[@]}" --env "$envs" "$SERVER_SIF" \
          bash /work/start_server.sh \
    ) > "$CUR_RUN_DIR/server.log" 2>&1 &
    SERVER_PID=$!
    t0=$SECONDS
    while :; do
        health || die "$HEALTH_MSG"
        n=$({ grep -oE "Server [0-9]+ -- Set I/O thread num to $IO_THREAD_NUM" "$CUR_RUN_DIR/server.log" 2>/dev/null || true; } | sort -u | wc -l)
        [[ $n -ge $NGPU ]] && break
        (( SECONDS - t0 > SERVER_READY_TIMEOUT )) && die "server not ready after ${SERVER_READY_TIMEOUT}s ($n/$NGPU GPUs up)"
        sleep 5
    done
    log "server ready after $((SECONDS - t0))s"

    # 2) clients (one shared apptainer instance, one exec per function)
    # clients write log_client_<id>.txt into their cwd -> /work = run dir/clients
    apptainer instance start --cleanenv \
        --bind "$IPC_DIR:/cuda" --bind "$WEIGHTS_SHM:/models:ro" --bind "$CUR_RUN_DIR/clients:/work" \
        "$CLIENT_SIF" "$CLIENT_INSTANCE" > "$CUR_RUN_DIR/client_instance.log" 2>&1 \
        || die "apptainer instance start failed (see client_instance.log)"

    ( cd "$CUR_RUN_DIR" && exec taskset -c "$ROUTER_CORES" "$VENV/bin/python" -u "$BIN/router.py" \
          -m mixed -s "$NGPU" -f "$F" -p "$policy" ) > "$CUR_RUN_DIR/router_stdout.log" 2>&1 &
    ROUTER_PID=$!
    t0=$SECONDS; local last_report=0 loaded tried launches relaunches
    while :; do
        health || die "$HEALTH_MSG"
        loaded=$(loaded_cnt); tried=$(tried_cnt); launches=$(launch_cnt)
        relaunches=$(( launches - tried ))
        [[ $loaded -ge $F ]] && break
        (( relaunches > MAX_RELAUNCHES )) && die "too many client relaunches ($relaunches > $MAX_RELAUNCHES), loaded $loaded/$F"
        (( SECONDS - t0 > CLIENTS_READY_TIMEOUT )) && die "clients not ready after ${CLIENTS_READY_TIMEOUT}s (loaded $loaded/$F)"
        if (( SECONDS - last_report >= 300 )); then
            log "loading clients: $loaded/$F loaded, $relaunches relaunches, $((SECONDS - t0))s"
            last_report=$SECONDS
        fi
        sleep 10
    done
    log "all $F clients loaded after $((SECONDS - t0))s ($relaunches relaunches)"

    # 3) sender (flag 0: router clears up and warms up first, flag 1: start sending right away)
    ( cd "$CUR_RUN_DIR" && exec taskset -c "$SENDER_CORES" "$VENV/bin/python" -u "$BIN/sender_from_trace.py" \
          "$F" "$TRACE_MINUTES" "$SENDER_FLAG" ) > "$CUR_RUN_DIR/sender.log" 2>&1 &
    SENDER_PID=$!

    # CPU monitor during sending (stopped by kill_everything)
    ( trap - ERR; set +eE +o pipefail
      while sleep 60; do date; uptime; top -b -n1 -o %CPU -w 200 | head -40; done
    ) > "$CUR_RUN_DIR/cpu.log" 2>&1 &

    local deadline=$(( TRACE_MINUTES * 60 + F / 20 + 1200 ))
    t0=$SECONDS; last_report=$SECONDS; prev_n=0; last_change=$SECONDS
    while kill -0 "$SENDER_PID" 2>/dev/null; do
        health || die "$HEALTH_MSG"
        n=$(done_cnt)
        if (( n != prev_n )); then prev_n=$n; last_change=$SECONDS; fi
        (( SECONDS - last_change > STALL_TIMEOUT )) && die "no request finished for ${STALL_TIMEOUT}s (stuck server or router?)"
        (( SECONDS - t0 > deadline )) && die "sender still running after ${deadline}s"
        if (( SECONDS - last_report >= 300 )); then
            log "sending: $n requests finished, $(timeout_cnt) timeouts, $((SECONDS - t0))s"
            last_report=$SECONDS
        fi
        sleep 10
    done
    local rc=0
    wait "$SENDER_PID" || rc=$?
    SENDER_PID=""
    [[ $rc -eq 0 ]] || die "sender exited with code $rc (see sender.log)"

    # 4) drain, stop, analyze
    t0=$SECONDS
    while (( SECONDS - t0 < DRAIN_SEC )); do health || die "$HEALTH_MSG"; sleep 5; done
    local finished timeouts
    finished=$(done_cnt); timeouts=$(timeout_cnt)
    kill_everything
    [[ $finished -gt 0 ]] || die "router.log has no finished requests"

    "$VENV/bin/python" "$BIN/figure11_analyze_router_log.py" "$CUR_RUN_DIR/router.log" \
        > "$CUR_RUN_DIR/analysis.txt" 2>&1 || die "analysis script failed (see analysis.txt)"
    local pct
    pct=$({ grep -oE 'SLO-compliant Func\. \(%\) *: *[0-9.]+' "$CUR_RUN_DIR/analysis.txt" || true; } | grep -oE '[0-9.]+$' || true)
    [[ -n "$pct" ]] || die "analysis.txt contains no SLO percentage"

    # 5) validity: every endpoint uses a fixed input, so a healthy model always returns the same
    #    output. A response that differs from the reference (taken from the clean F40 run
    #    job 15832810, community images) means the model computed garbage (corrupted model memory).
    #    Such requests still count as finished in the SLO analysis.
    #    Other images (e.g. the official -v1 ones) may give slightly different reference values:
    #    take them from a clean F40 run (python firstbad.py <run_dir>) and update REF.
    "$VENV/bin/python" - "$CUR_RUN_DIR/router.log" <<'EOPY' > "$CUR_RUN_DIR/validity.txt" 2>&1 || true
import re, sys, math, collections
REF = {0: 0.0026607513427734375,   # resnet50
       1: 0.0016813278198242188,   # resnet101
       2: 0.0020055770874023438,   # resnet152
       3: 0.004660606384277344,    # densenet169
       4: 0.002803802490234375,    # densenet201
       5: -21.933094024658203,     # inception
       6: 15.983399391174316,      # efficientnet
       7: -1725.9248046875}        # bertqa
pat = re.compile(r'Func (\d+) .* on server (\d+) end-to-end.*output: ([^,]+),')
tot = bad = 0
funcs, gpus = collections.Counter(), collections.Counter()
for l in open(sys.argv[1]):
    m = pat.search(l)
    if not m:
        continue
    tot += 1
    try:
        x = float(m[3])
    except ValueError:
        x = float('nan')
    ref = REF[int(m[1]) % 8]
    if not math.isfinite(x) or abs(x - ref) > 1e-4 * max(1.0, abs(ref)):
        bad += 1
        funcs[int(m[1])] += 1
        gpus[int(m[2])] += 1
print(f'bad_outputs {bad}')
print(f'total_outputs {tot}')
print(f'bad_functions {len(funcs)}')
print('bad per GPU', dict(sorted(gpus.items())))
print('worst functions', funcs.most_common(15))
EOPY
    local bad badf
    bad=$(awk '/^bad_outputs/{print $2}' "$CUR_RUN_DIR/validity.txt" 2>/dev/null || true); bad=${bad:-unknown}
    badf=$(awk '/^bad_functions/{print $2}' "$CUR_RUN_DIR/validity.txt" 2>/dev/null || true); badf=${badf:-unknown}

    echo "$F,$variant,$SENDER_FLAG,$pct,$finished,$timeouts,$bad,$badf,$CUR_RUN_DIR" | tee -a "$JOB_DIR/summary.csv" >> "$SUMMARY_ALL"
    log "RESULT F=$F $variant: $pct % SLO-compliant functions ($finished requests, $timeouts client timeouts, $bad bad outputs in $badf functions)"
    if [[ "$bad" != 0 ]]; then
        log "WARNING: $bad requests returned garbage (output differs from the clean reference) in $badf functions; this SLO result is NOT valid (see validity.txt)"
    fi
    if [[ $timeouts -gt 0 ]]; then
        log "note: $timeouts client timeouts; those functions were dropped by the router (upstream behaviour)"
    fi
    CUR_RUN_DIR=""
}

# ------------------------------------------------------------------ job setup
log "node $(hostname), counts: $FUNC_COUNTS, variants: $VARIANTS, sender flag: $SENDER_FLAG, abort on assert: $ABORT_ON_ASSERT"
ulimit -c 0
[[ "$(ulimit -c)" == 0 ]] || die "could not disable core dumps"
ulimit -n "$(ulimit -Hn)"
ulimit -u "$(ulimit -Hu)" 2>/dev/null || true

# one job per directory
if [[ -f "$ACTIVE_FILE" ]]; then
    other=$(cat "$ACTIVE_FILE")
    if [[ "$other" != "$JOB_ID" ]] && squeue -h -j "$other" 2>/dev/null | grep -q .; then
        die "job $other is still running in $FIG11_HOME; never run two jobs in the same directory"
    fi
fi
echo "$JOB_ID" > "$ACTIVE_FILE"

command -v apptainer >/dev/null || die "apptainer not found in PATH"
for v in $VARIANTS; do
    case "$v" in torpor|fifo|block|lru|random) ;; *) die "unknown variant '$v' (use: torpor fifo block lru random)" ;; esac
done
case "$SENDER_FLAG" in 0|1) ;; *) die "SENDER_FLAG must be 0 (warm up) or 1 (no warm up), got '$SENDER_FLAG'" ;; esac
type module >/dev/null 2>&1 || die "module command not available in the batch shell"
# Load exactly the Python the venv was built with (read from venv/pyvenv.cfg), e.g.
# home = /p/software/.../stages/2025/software/Python/3.12.3-GCCcore-13.3.0/bin
py_home=$(awk -F' *= *' '$1=="home"{print $2}' "$VENV/pyvenv.cfg" 2>/dev/null || true)
if [[ "$py_home" =~ stages/([0-9]+)/software/Python/([0-9.]+)-GCCcore-([0-9.]+) ]]; then
    mods="Stages/${BASH_REMATCH[1]} GCCcore/.${BASH_REMATCH[3]} Python/${BASH_REMATCH[2]}"
else
    mods="$PY_MODULE"
    log "WARNING: could not read the venv's Python from $VENV/pyvenv.cfg (home=$py_home), using PY_MODULE"
fi
set +u   # Lmod does not like nounset
module load $mods > "$JOB_DIR/module_load.log" 2>&1 \
    || { set -u; die "module load $mods failed: $(tail -n 5 "$JOB_DIR/module_load.log" | tr '\n' ' ')"; }
set -u
log "host python: $("$VENV/bin/python" -V 2>&1) (modules: $mods)"
for f in "$SERVER_SIF" "$CLIENT_SIF" "$VENV/bin/python" "$BIN/router.py" "$BIN/sender_from_trace.py" \
         "$BIN/signal_pb2.py" "$BIN/launch_client.sh" "$BIN/figure11_analyze_router_log.py" \
         "$TRACE_DIR/samples.npy" "$WEIGHTS_SRC/.done" ${SERVER_BIN_DIR:+"$SERVER_BIN_DIR/server" "$SERVER_BIN_DIR/libwapper.so"}; do
    [[ -e "$f" ]] || die "missing $f (run prepare.sh on a login node first)"
done
(cd "$BIN" && "$VENV/bin/python" -c "import zmq, numpy, requests; from signal_pb2 import SignalRequest") \
    || die "host venv broken on this node (python $VENV, modules $mods)"
[[ "$(nvidia-smi -L | grep -c GPU)" -eq $NGPU ]] || die "expected $NGPU GPUs, nvidia-smi shows: $(nvidia-smi -L | tr '\n' ';')"
nvidia-smi topo -m > "$JOB_DIR/topo.txt" 2>&1 || true
log "GPU topology saved to $JOB_DIR/topo.txt (check it against GPU_CORES_* in config.sh)"

# CPU pinning sanity: allowed by Slurm, router/sender outside GPU ranges
allowed=$(grep Cpus_allowed_list /proc/self/status | awk '{print $2}')
missing=$(comm -23 <(expand_cores "$GPU_CORES_0,$GPU_CORES_1,$GPU_CORES_2,$GPU_CORES_3,$ROUTER_CORES,$SENDER_CORES" | sort -u) \
                   <(expand_cores "$allowed" | sort -u) | head -5 | tr '\n' ' ')
[[ -z "$missing" ]] || die "cores not allowed in this allocation: $missing (allowed: $allowed)"
overlap=$(comm -12 <(expand_cores "$ROUTER_CORES,$SENDER_CORES" | sort -u) \
                   <(expand_cores "$GPU_CORES_0,$GPU_CORES_1,$GPU_CORES_2,$GPU_CORES_3" | sort -u) | head -5 | tr '\n' ' ')
[[ -z "$overlap" ]] || die "router/sender cores overlap GPU client cores: $overlap"

# stage weights to node local memory
log "staging weights to $WEIGHTS_SHM"
rm -rf "$WEIGHTS_SHM"; mkdir -p "$WEIGHTS_SHM"
cp -a "$WEIGHTS_SRC/." "$WEIGHTS_SHM/" || die "copying weights to $WEIGHTS_SHM failed (df: $(df -h /dev/shm | tail -1))"
log "weights staged: $(du -sh "$WEIGHTS_SHM" | cut -f1)"

echo "$SUMMARY_HDR" > "$JOB_DIR/summary.csv"
[[ -f "$SUMMARY_ALL" ]] || echo "$SUMMARY_HDR" > "$SUMMARY_ALL"

# ------------------------------------------------------------------ main loop
for F in $FUNC_COUNTS; do
    for v in $VARIANTS; do
        if [[ "$v" == random && "$F" -gt 400 && "$RANDOM_ALL_COUNTS" != 1 ]]; then
            log "skipping random for F=$F (upstream ran it only for 320 and 400)"
            continue
        fi
        run_one "$F" "$v"
    done
done
log "all runs done"
cat "$JOB_DIR/summary.csv"