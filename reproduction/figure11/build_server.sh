#!/bin/bash
# Build the Torpor GPU server (server + libwapper.so) from $TORPOR_REPO inside the server
# image and install it into $SERVER_BIN_DIR (default: server_bin_fixed/ next to this script).
# fig11_job.sbatch binds that directory over the image's /server_bin.
#
# The source must contain the two one-line fixes (checked below):
#   include/server/model_repo.hpp      host_addr = 0
#   include/server/memory_manager.hpp  valid_memory_address returns the lookup result
#
# Usage (login node, no Figure 11 job running):  bash build_server.sh
#   SERVER_BUILD_DIR=<dir>  build directory (default $FIG11_HOME/server_build, reused by later builds)
#   MAKE_JOBS=<n>           parallel make jobs (default 16)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config.sh"

OUT="${SERVER_BIN_DIR:-$HERE/server_bin_fixed}"
BUILD="${SERVER_BUILD_DIR:-$FIG11_HOME/server_build}"
JOBS="${MAKE_JOBS:-16}"
die() { echo "build_server.sh: $*" >&2; exit 1; }

command -v apptainer >/dev/null || die "apptainer not found"
[[ -f "$SERVER_SIF" ]] || die "server image $SERVER_SIF not found (see README)"

# never swap the binary under a running job
if [[ -f "$FIG11_HOME/ACTIVE_JOB" ]]; then
    job=$(cat "$FIG11_HOME/ACTIVE_JOB")
    if squeue -h -j "$job" 2>/dev/null | grep -q .; then
        die "job $job is running and uses $OUT; build after it has finished"
    fi
fi

# refuse to build an unfixed server
grep -q 'uint64_t host_addr = 0, block_addr = 0;' "$TORPOR_REPO/include/server/model_repo.hpp" \
    || die "host_addr fix missing in $TORPOR_REPO/include/server/model_repo.hpp"
grep -q 'return model_repo_.find_block_ephe_ptr_mapping(function, addr);' "$TORPOR_REPO/include/server/memory_manager.hpp" \
    || die "valid_memory_address fix missing in $TORPOR_REPO/include/server/memory_manager.hpp"

mkdir -p "$BUILD" "$OUT"
echo "source: $TORPOR_REPO   build: $BUILD   install: $OUT"

# Same configuration as upstream's dockerfiles/server.Dockerfile. The repository is mounted at
# /gpu-swap, where the image keeps its own copy of the sources.
apptainer exec --cleanenv --bind "$TORPOR_REPO:/gpu-swap" --bind "$BUILD" "$SERVER_SIF" bash -c "
    set -e
    if [ ! -f '$BUILD/CMakeCache.txt' ]; then
        cmake -S /gpu-swap -B '$BUILD' -DCMAKE_BUILD_TYPE=Release -DBUILD_TARGET:STRING=server \
              -DCMAKE_PREFIX_PATH=/opt/conda/lib/python3.8/site-packages/torch > '$BUILD/cmake.log' 2>&1 \
            || { tail -20 '$BUILD/cmake.log'; exit 1; }
    fi
    make -C '$BUILD' -j$JOBS server > '$BUILD/make.log' 2>&1 || { tail -30 '$BUILD/make.log'; exit 1; }
"

cp "$BUILD/target/server" "$BUILD/src/server/libwapper.so" "$OUT/"

# record what was built, so a binary can be traced back to its source
{
    echo "built $(date '+%F %T') on $(hostname) in $SERVER_SIF"
    echo "commit $(git -C "$TORPOR_REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "uncommitted changes in include/ src/:"
    git -C "$TORPOR_REPO" status --short -- include src 2>/dev/null || true
    (cd "$OUT" && md5sum server libwapper.so)
} > "$OUT/build_info.txt"
cat "$OUT/build_info.txt"
echo "installed into $OUT"
