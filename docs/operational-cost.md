# Operational Cost

Current cost is one Ruby process, one TCP port, and one AOF file. The main
debugging cost is understanding whether a bug lives in protocol parsing,
application command handling, store state, or AOF replay.

The accepted trade-off is low infrastructure cost in exchange for missing
production controls.
