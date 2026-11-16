#!/bin/bash
# One time setup. Run on a JURECA LOGIN node (needs internet), from this folder:
#   bash prepare.sh
# Steps can be repeated; finished steps are skipped.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config.sh"
trap 'echo "PREPARE FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
log() { echo "$(date '+%F %T') [prepare] $*"; }

mkdir -p "$FIG11_HOME" "$BIN" "$TRACE_DIR" "$RUNS_DIR"

# 1) repo
if [[ ! -d "$TORPOR_REPO/.git" ]]; then
    log "cloning torpor to $TORPOR_REPO"
    git clone https://github.com/s4-lab-cuhksz/torpor "$TORPOR_REPO"
fi

# 2) images: use the existing SIF files, just check they are the Torpor ones
for f in "$SERVER_SIF" "$CLIENT_SIF"; do
    [[ -f "$f" ]] || { echo "missing image $f (check BASE in config.sh)" >&2; exit 1; }
done
apptainer exec "$SERVER_SIF" test -x /server_bin/server
apptainer exec "$CLIENT_SIF" test -f /start_with_server_id.sh
apptainer exec "$CLIENT_SIF" test -f /endpoint.py
log "images OK"

# 3) host python for router, sender and analysis
if type module >/dev/null 2>&1; then module load $PY_MODULE; fi
if [[ ! -x "$VENV/bin/python" ]]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --upgrade pip
    "$VENV/bin/pip" install pyzmq numpy requests "protobuf==3.20.3"
fi

# 4) patched scripts + helpers
python3 "$HERE/patch_scripts.py" "$TORPOR_REPO" "$BIN"
cp "$TORPOR_REPO/evaluation2/figure10/signal_pb2.py" "$BIN/"
cp "$TORPOR_REPO/evaluation/figure11/figure11_analyze_router_log.py" "$BIN/"
cp "$HERE/launch_client.sh" "$HERE/config.sh" "$BIN/"
chmod +x "$BIN/launch_client.sh"
cp -n "$TORPOR_REPO/tools/samples.npy" "$TRACE_DIR/"
(cd "$BIN" && PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python "$VENV/bin/python" -c \
    "import zmq, numpy, requests; from signal_pb2 import SignalRequest; SignalRequest(); print('host python OK')")

# 5) model weights: load all 8 models inside the client image, offline, CPU only.
#    torchvision would silently download a missing file, so compare the file list before and after.
[[ -d "$WEIGHTS_SRC/torch/hub/checkpoints" && -d "$WEIGHTS_SRC/hf/hub" ]] \
    || { echo "expected $WEIGHTS_SRC/torch/hub/checkpoints and $WEIGHTS_SRC/hf/hub" >&2; exit 1; }
log "checking model weights in $WEIGHTS_SRC (takes a minute)"
before=$(cd "$WEIGHTS_SRC" && find torch hf -type f | sort)
apptainer exec --cleanenv \
    --bind "$WEIGHTS_SRC:/models" \
    --env TORCH_HOME=/models/torch,HF_HOME=/models/hf,HF_HUB_OFFLINE=1,TRANSFORMERS_OFFLINE=1 \
    "$CLIENT_SIF" python -c '
import torchvision, transformers, torchvision.models as m
print("torchvision", torchvision.__version__, "transformers", transformers.__version__)
for f in (m.resnet50, m.resnet101, m.resnet152, m.densenet169, m.densenet201, m.inception_v3, m.efficientnet_b0):
    f(pretrained=True); print("ok", f.__name__)
from transformers import BertForQuestionAnswering
BertForQuestionAnswering.from_pretrained("bert-large-uncased-whole-word-masking-finetuned-squad"); print("ok bertqa")
'
after=$(cd "$WEIGHTS_SRC" && find torch hf -type f | sort)
new=$(comm -13 <(echo "$before") <(echo "$after") | grep -v '\.lock$' || true)
if [[ -n "$new" ]]; then
    log "these files were missing and got downloaded now (fine, compute nodes will use them):"
    echo "$new"
fi
touch "$WEIGHTS_SRC/.done"
log "weights OK"
du -sh "$WEIGHTS_SRC"

log "done. Next: sbatch fig11_job.sbatch (see README.md)"
