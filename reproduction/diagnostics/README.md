# Diagnostic server patches (not used for any reported result)

All reported results ran on the images described in
[`../images/README.md`](../images/README.md): upstream code plus the one-line
`host_addr` fix. The patches here were used only to investigate the Figure 11
failure. Two of them were measured and rejected; none of them is part of the
reproduction.

| What | Where | Outcome |
|---|---|---|
| `send_complete_signal` tracking-window patch | [`trackfix/`](trackfix/) | Registration bookkeeping cleaner, outputs unchanged. Backed out. |
| Per-client `active_func_` state | [`activefunc/`](activefunc/) | **Failed** (81 unregistered models, 0 requests served). Do not use. |
| Earlier race fixes and extra logging | branch `server-fixes-diagnostics` | Not measured for any result. Kept for reference. |

Patched binaries can be tested without building a new image: build the server
into an overlay (see the READMEs), then point `SERVER_BIN` at it for
`../figure11/run_fig11_variant.sh`.
The binary is bind-mounted over `/server_bin/server`.

The background (two races on per-server state in `cuda_server.hpp` and
`memory_manager.hpp`) is summarised under "Known problems in the results" in
[`../README.md`](../README.md) and in the READMEs of the two patches.
