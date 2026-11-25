#!/bin/bash
# Figure 11, every variant at one function count: Torpor, -FIFO, -Block, -LRU,
# and -Random (320 and 400 only, as in the original's Figure11_README.md).
# Usage: ./run_all_figure11.sh <FUNC_NUM>
# Set KEEP_LOGS=1 to keep the previous logs of this count.
set -u
cd "$(dirname "$0")"
FUNC_NUM=${1:?Usage: $0 <FUNC_NUM>}

if [ "${KEEP_LOGS:-0}" != "1" ]; then
    rm -rf logs_fig11/*_"${FUNC_NUM}"f logs_fig11/*_"${FUNC_NUM}"f_result.txt
fi

VARIANTS=(torpor fifo block lru)
if [ "$FUNC_NUM" -le "${RANDOM_MAX_FUNC:-400}" ]; then
    VARIANTS+=(random)
else
    echo "Skipping random at FUNC_NUM=$FUNC_NUM (original only runs it at 320 and 400)."
fi

FAILED=()
for v in "${VARIANTS[@]}"; do
    echo "###### ./run_fig11_variant.sh $v $FUNC_NUM ######"
    ./run_fig11_variant.sh "$v" "$FUNC_NUM" || FAILED+=("$v")
    echo
done

echo "===== Figure 11 (FUNC_NUM=$FUNC_NUM): all variants ====="
for v in "${VARIANTS[@]}"; do
    f="logs_fig11/${v}_${FUNC_NUM}f_result.txt"
    [ -f "$f" ] && { echo "--- $f ---"; cat "$f"; echo; }
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "FAILED variants: ${FAILED[*]}"
    exit 1
fi
