#!/bin/bash
# Figure 11, one variant at one function count.
# Usage: ./run_fig11_variant.sh <torpor|fifo|block|lru|random> <FUNC_NUM>
# Server, router and sender run in logs_fig11/<variant>_<n>f/.
set -u -o pipefail
cd "$(dirname "$0")"
HERE="$PWD"
source ../common/env.sh
source ../common/ports.sh
source ../common/kill_stale.sh
VARIANT=${1:?Usage: $0 <torpor|fifo|block|lru|random> <FUNC_NUM>}
FUNC_NUM=${2:?Usage: $0 <torpor|fifo|block|lru|random> <FUNC_NUM>}
MINUTES=31
SERVER_SIF="${SERVER_SIF:-$TORPOR/images/torpor-server.sif}"
CLIENT_SIF="${CLIENT_SIF:-$TORPOR/images/torpor-client.sif}"
SERVER_BIN="${SERVER_BIN:-}"
MODEL_DIR="${MODEL_DIR:-$TORPOR/models}"
ROUTER_CORES=0-15                         
SENDER_CORES=32-39

POLICY=sa
EXTRA_SERVER_ENV=""
case "$VARIANT" in
    torpor) ;;
    fifo)   POLICY=fifo ;;
    block)  EXTRA_SERVER_ENV=",BLOCK_MANAGER=Fixed" ;;
    lru)    EXTRA_SERVER_ENV=",EVICT_POLICY=LRU" ;;
    random) EXTRA_SERVER_ENV=",SCHEDULE_POLICY=RAND" ;;
    *) echo "ERROR: unknown variant '$VARIANT'"; exit 1 ;;
esac
echo "Using SERVER_SIF=$SERVER_SIF (variant=$VARIANT, policy=$POLICY, extra env='$EXTRA_SERVER_ENV')"
[ -z "$SERVER_BIN" ] || echo "Using SERVER_BIN=$SERVER_BIN"

RUN_DIR="$HERE/logs_fig11/${VARIANT}_${FUNC_NUM}f"
RESULT="$HERE/logs_fig11/${VARIANT}_${FUNC_NUM}f_result.txt"
export CLIENT_INSTANCE="fig11_${SLURM_JOB_ID:-$$}"

# Server crashes, CUDA asserts and ModelRepo lookup errors
FATAL_RE='terminate called|Segmentation fault|core dumped|double free or corruption'
FATAL_RE+='|Error: no free physical block|Error: cannot acquire block|acquire_block size too large|Error: cannot find physical block'
FATAL_RE+='|device-side assert|Assertion .* failed|cuda assert|cudnn assert'
FATAL_RE+='|parameter ptr not found|Memory access error|fails to find malloc'

cleanup() {
    apptainer instance stop -F "$CLIENT_INSTANCE" > /dev/null 2>&1
    pkill -f sender_from_trace.py 2>/dev/null
    kill_stale_processes
    rm -rf /dev/shm/ipc
}
trap cleanup EXIT
trap 'exit 143' INT TERM

fail() {
    echo "FAILED: $*" | tee "$RUN_DIR/FAILED.txt"
    for f in server.log router_stdout.log router.log sender.log; do
        [ -f "$RUN_DIR/$f" ] && { echo; echo "--- last 30 lines of $f ---"; tail -n 30 "$RUN_DIR/$f"; }
    done >> "$RUN_DIR/FAILED.txt"
    exit 1
}

check_health() {
    kill -0 "$SERVER_PID" 2>/dev/null || fail "server process died (see server.log)"
    local msg
    msg=$(grep -Em1 "$FATAL_RE" "$RUN_DIR/server.log")
    [ -z "$msg" ] || fail "crash message in server.log: $msg"
    [ -z "${ROUTER_PID:-}" ] || kill -0 "$ROUTER_PID" 2>/dev/null || fail "router died (see router_stdout.log)"
}

count() { local n; n=$(grep -cE "$1" "$RUN_DIR/router.log" 2>/dev/null); echo "${n:-0}"; }
count_uniq() { grep -oE "$1" "$RUN_DIR/router.log" 2>/dev/null | sort -u | wc -l; }

kill_stale_processes
apptainer instance stop -F "$CLIENT_INSTANCE" > /dev/null 2>&1
# wait until the previous run has released the GPUs
for i in $(seq 1 18); do
    [ -z "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null)" ] && break
    sleep 5
done
rm -rf /dev/shm/ipc && mkdir -p /dev/shm/ipc
rm -rf "$RUN_DIR" "$RESULT" && mkdir -p "$RUN_DIR/clients"
ulimit -c 0
ulimit -n "$(ulimit -Hn)"

# 1. Server on all 4 GPUs. It writes its own logs to its cwd (/work = run dir);
#    stdbuf gets crash messages into server.log right away.
apptainer exec --nv --cleanenv \
    --bind /dev/shm/ipc:/cuda --bind "$RUN_DIR:/work" --pwd /work \
    ${SERVER_BIN:+--bind "$SERVER_BIN:/server_bin/server:ro"} \
    --env MEM_LIMIT_IN_GB=25,IO_THREAD_NUM=4${EXTRA_SERVER_ENV} \
    "$SERVER_SIF" \
    bash -c 'LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH LD_PRELOAD=/server_bin/libwapper.so exec stdbuf -oL -eL /server_bin/server' \
    > "$RUN_DIR/server.log" 2>&1 &
SERVER_PID=$!

# See ../common/model_loop.sh for why this is matched as a prefix.
echo "Waiting for server readiness..."
READY_SRV=0
for i in $(seq 1 120); do
    if [ "$(grep -o 'Set I/O thread num' "$RUN_DIR/server.log" 2>/dev/null | wc -l)" -ge 4 ]; then
        READY_SRV=1; break
    fi
    check_health
    sleep 5
done
[ "$READY_SRV" -eq 1 ] || fail "server not ready after 600 s"
echo "Server is ready."

# 2. One Apptainer instance for all clients; router.py execs each client into it.
#    Clients write log_client_<id>.txt to their cwd (/work = run dir/clients).
apptainer instance start --cleanenv \
    --bind /dev/shm/ipc:/cuda --bind "$MODEL_DIR:/models:ro" --bind "$RUN_DIR/clients:/work" \
    "$CLIENT_SIF" "$CLIENT_INSTANCE" > "$RUN_DIR/client_instance.log" 2>&1 \
    || fail "apptainer instance start failed (see client_instance.log)"

# 3. Router launches the clients.
( cd "$RUN_DIR" && exec taskset -c "$ROUTER_CORES" python3 -u "$HERE/router.py" \
      -m mixed -s 4 -f "$FUNC_NUM" -p "$POLICY" ) > "$RUN_DIR/router_stdout.log" 2>&1 &
ROUTER_PID=$!

echo "Waiting for $FUNC_NUM clients (about 30 min at 560)..."
t0=$SECONDS; last=$SECONDS
while :; do
    loaded=$(count_uniq 'ExecuteAfterLoad [0-9]+ on server [0-9]+ resp:')
    [ "$loaded" -ge "$FUNC_NUM" ] && break
    relaunches=$(( $(count 'Try launching') - $(count_uniq 'Try launching [0-9]+ on server [0-9]+') ))
    [ "$relaunches" -le 40 ] || fail "more than 40 client relaunches (loaded $loaded / $FUNC_NUM)"
    [ $((SECONDS - t0)) -le 5400 ] || fail "clients not loaded after 5400 s ($loaded / $FUNC_NUM)"
    check_health
    if [ $((SECONDS - last)) -ge 300 ]; then
        echo "  $loaded / $FUNC_NUM loaded, $relaunches relaunches, $((SECONDS - t0)) s"; last=$SECONDS
    fi
    sleep 10
done
echo "Clients ready: $loaded / $FUNC_NUM after $((SECONDS - t0)) s"

# 4. Replay the trace (cached in ../../tools, so every variant sees the same requests)
( cd "$RUN_DIR" && exec taskset -c "$SENDER_CORES" python3 -u "$HERE/sender_from_trace.py" \
      "$FUNC_NUM" "$MINUTES" 0 ) > "$RUN_DIR/sender.log" 2>&1 &
SENDER_PID=$!
t0=$SECONDS; last=$SECONDS; prev=0; last_change=$SECONDS
while kill -0 "$SENDER_PID" 2>/dev/null; do
    check_health
    n=$(count 'end-to-end time')
    [ "$n" -ne "$prev" ] && { prev=$n; last_change=$SECONDS; }
    [ $((SECONDS - last_change)) -le 900 ] || fail "no request finished for 900 s"
    [ $((SECONDS - t0)) -le $((MINUTES * 60 + 1800)) ] || fail "sender still running after $((MINUTES * 60 + 1800)) s"
    if [ $((SECONDS - last)) -ge 300 ]; then
        echo "  $n requests finished, $((SECONDS - t0)) s"; last=$SECONDS
    fi
    sleep 10
done
wait "$SENDER_PID" || fail "sender failed (see sender.log)"
for i in $(seq 1 12); do check_health; sleep 5; done   # let the last requests finish
cleanup

# 5. Analyze
[ "$(count 'end-to-end time')" -gt 0 ] || fail "router.log has no finished requests"
python3 figure11_analyze_router_log.py "$RUN_DIR/router.log" > "$RUN_DIR/analysis.txt" 2>&1 \
    || fail "analyzer failed (see analysis.txt)"
{
    echo "variant=$VARIANT FUNC_NUM=$FUNC_NUM finished=$(count 'end-to-end time') client_timeouts=$(count 'Func [0-9]+ on server [0-9]+ timeout')"
    cat "$RUN_DIR/analysis.txt"
} > "$RESULT"
cat "$RESULT"
