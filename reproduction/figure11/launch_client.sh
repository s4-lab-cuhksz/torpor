#!/bin/bash
# Called by the patched router.py once per function (replaces `docker run standalone-client`).
# usage: launch_client.sh <client_id> <server_id> <model_name> <port>
# Needs the env exported by fig11_job.sbatch (config.sh values).
set -uo pipefail
cid=$1; sid=$2; model=$3; port=$4
ts() { date '+%F %T'; }

cores_var="GPU_CORES_${sid}"
cores="${!cores_var:-}"
if [[ -z "$cores" ]]; then
    echo "$(ts) [launch_client] ERROR: no core range for server $sid" >&2
    exit 1
fi

# A relaunch by the router must not race an old instance for the same port.
pkill -u "$USER" -f "endpoint.py ${port}\$" 2>/dev/null && sleep 1

echo "$(ts) [launch_client] client=$cid server=$sid model=$model port=$port cores=$cores"

# No --nv on purpose: the client image ships a fake libcuda.so.1 (Torpor remoting lib).
# --nv would put the host libcuda first in LD_LIBRARY_PATH and bypass Torpor.
ENVS=(--env "OMP_NUM_THREADS=1,KMP_DUPLICATE_LIB_OK=TRUE,model_name=$model"
      --env "TORCH_HOME=/models/torch,HF_HOME=/models/hf,HF_HUB_OFFLINE=1,TRANSFORMERS_OFFLINE=1")

# The Torpor client lib writes log_client_<id>.txt into the cwd; the SIF is read only,
# so start in /work (= run dir/clients, writable).
CMD="cd /work && exec bash /start_with_server_id.sh $cid $sid /endpoint.py $port"

if [[ -n "${CLIENT_INSTANCE:-}" ]]; then
    # shared instance started by the job (binds /cuda, /models and /work already set there)
    exec taskset -c "$cores" apptainer exec --cleanenv "${ENVS[@]}" "instance://$CLIENT_INSTANCE" \
        bash -c "$CMD"
else
    exec taskset -c "$cores" apptainer exec --cleanenv \
        --bind "$IPC_DIR:/cuda" --bind "$WEIGHTS_SHM:/models:ro" --bind "$PWD/clients:/work" \
        "${ENVS[@]}" "$CLIENT_SIF" bash -c "$CMD"
fi