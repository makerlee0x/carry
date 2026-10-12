# Workspace

- **Source of truth:** https://github.com/makerlee0x/carry
- **Local session workspace:** `/Users/meador/Carry` (same inode as `/Users/meador/carry` on case-insensitive APFS)
- **Do not** deploy Carry from StockTokenSwap
- Side clone `/Users/meador/carry-v3` is optional; prefer this workspace

Parent agent must call `move_agent_to_root` with `rootPath=/Users/meador/Carry` so the Cursor sidebar shows **Carry** for this session (subagents cannot re-root).
