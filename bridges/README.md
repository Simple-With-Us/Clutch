# Bridges

The stdio JSON-RPC bridges that let Shellular, ACP callers, and other agents
spawn an engine session over a single child process.  Each bridge is a thin
Python script: read JSON-RPC frames from stdin, fork-and-exec the engine
binary (`dsh --profile …`), write ACP-shaped frames to stdout.  Both the
DeepSeek and the MiniMax bridge spawn `dsh`; the MiniMax bridge pins the
MiniMax LLM via the `minimax-headless` profile.

## Why Python

The DSH bridge (`dsh/dsh-acp.py`) predates this repo and carries production
fixes (DEVNULL stdin, process-group kill, heartbeats) earned through real
failures documented in
`ai-fleet-coordinator/docs/rollouts/2026-08-23-shellular-deepseek-thinking-fix.md`
and follow-ups.  Porting it to TypeScript is a coin-flip on whether every fix
comes across correctly.  The MiniMax bridge (`minimax/minimax-acp.py`) was
once an HTTP chat/completions adapter; it now mirrors `dsh-acp.py` and spawns
`dsh --profile minimax-headless` so Shellular MiniMax gets the same local
tools as DeepSeek.

If you need a new bridge: write it in Python, stdlib-only, and put it in
`bridges/<name>/`.  The `bin` entry in `package.json` does not list bridge
binaries — they are invoked by name (`dsh-acp.sh`, `minimax-acp.sh`) from the
shell wrappers, not via `npm exec`.

## Layout

```
bridges/
├── README.md
├── dsh/
│   └── dsh-acp.py        # DeepSeek Harness engine → ACP
├── minimax/
│   └── minimax-acp.py    # MiniMax on the dsh engine → ACP (spawns dsh)
└── grok/
    └── grok-acp.py       # Grok Build leader-stdio → ACP (strip authMethods)
```

The `dsh-acp.sh`, `minimax-acp.sh`, and `grok-acp.sh` shell wrappers live in
`scripts/` (Shellular runs them from `~/apps/clutch-runtime/scripts/`).  The
DeepSeek and MiniMax wrappers source `scripts/lib/clutch-env.sh`, which pins
`DSH_HOME` to `$CLUTCH_HOME/dsh` (default `~/.clutch/dsh`), then `exec` the
Python under `/opt/homebrew/bin/python3`.  The Grok wrapper does not, because
Grok is not the DSH engine.

## Auth

Bridges never read agent credentials.  Auth comes from:

- The process environment (`DEEPSEEK_API_KEY` for DeepSeek, `MINIMAX_API_KEY`
  for MiniMax).
- `$DSH_HOME/.credentials.yaml` (Clutch's engine credential store, default
  `~/.clutch/dsh/.credentials.yaml`) for DeepSeek.
- `$DSH_HOME/.credentials.yaml` / `~/.secrets/global-api-keys` for MiniMax
  (`MINIMAX_API_KEY`, looked up by `CLUTCH_MINIMAX_API_KEY_NAME`).

The Shellular `agents.json` entry for each agent sets the env vars via the
`env` block; the agent-facing config never holds a secret value.
