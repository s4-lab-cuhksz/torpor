#!/bin/bash
#SBATCH --job-name=figure11-repro
#SBATCH --partition=dc-gpu
#SBATCH --qos=normal
#SBATCH --nodes=1
#SBATCH --gres=gpu:4,mem512:1
#SBATCH --time=24:00:00
#SBATCH --output=logs_batch/slurm-%j.out
#SBATCH --error=logs_batch/slurm-%j.err
#
# Full Figure 11 run: Torpor, -FIFO, -Block, -LRU, -Random at 320, 400, 480 and
# 560 functions. Submit from this directory:
#   mkdir -p logs_batch && sbatch -A <project> sbatch_figure11.sh           # all counts
#   mkdir -p logs_batch && sbatch -A <project> sbatch_figure11.sh 480 560   # a subset
# Jobs share this directory, so chain them instead of running them in parallel:
#   JOB=$(sbatch --parsable -A <project> sbatch_figure11.sh 320 400)
#   sbatch -A <project> --dependency=afterany:$JOB sbatch_figure11.sh 480 560

set -u
cd "${SLURM_SUBMIT_DIR:-$(dirname "$0")}"
mkdir -p logs_batch
source ../common/env.sh

source "$TORPOR/venv/bin/activate"

FUNC_NUMS=("$@")
[ "${#FUNC_NUMS[@]}" -gt 0 ] || FUNC_NUMS=(320 400 480 560)
RESULTS_DIR="${RESULTS_ROOT:-$HOME/results}/figure_11"
mkdir -p "$RESULTS_DIR"

# Model weights in node memory: faster client loads.
export MODEL_DIR=/dev/shm/torpor_models
trap 'rm -rf "$MODEL_DIR"' EXIT
rm -rf "$MODEL_DIR" && mkdir -p "$MODEL_DIR"
cp -a "$TORPOR/models/." "$MODEL_DIR/" || { echo "ERROR: staging the model weights failed"; exit 1; }

FAILED_RUNS=()

for FUNC_NUM in "${FUNC_NUMS[@]}"; do
    echo "=================================================="
    echo "FUNC_NUM=$FUNC_NUM starting at $(date)"
    echo "=================================================="

    ./run_all_figure11.sh "$FUNC_NUM"
    RC=$?
    if [ "$RC" -ne 0 ]; then
        echo "WARNING: run_all_figure11.sh $FUNC_NUM exited with code $RC -- saving whatever results it produced and continuing"
        FAILED_RUNS+=("$FUNC_NUM")
    fi

    if compgen -G "logs_fig11/*_${FUNC_NUM}f_result.txt" > /dev/null; then
        cp logs_fig11/*_${FUNC_NUM}f_result.txt "$RESULTS_DIR/"
    else
        echo "WARNING: no result files found for FUNC_NUM=$FUNC_NUM"
    fi

    echo "FUNC_NUM=$FUNC_NUM done at $(date)"
    echo
done

echo "=================================================="
echo "All FUNC_NUM values processed."
if [ "${#FAILED_RUNS[@]}" -gt 0 ]; then
    echo "FUNC_NUM values with at least one failed variant: ${FAILED_RUNS[*]}"
    echo "(see logs_fig11/<variant>_<n>f/FAILED.txt)"
else
    echo "All runs completed successfully."
fi
echo "Results saved to: $RESULTS_DIR (raw logs kept in logs_fig11/)"
