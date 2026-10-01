# Fleet Compute Offload Policy — Prioritizing Free Cloud & GitHub Runners

## Executive Summary

To maximize developer ergonomics, protect local hardware, and optimize fleet economics, **all compute-intensive workloads for public repositories must be offloaded to free cloud infrastructure** — primarily GitHub Actions hosted runners (`ubuntu-latest` and `macos-15` / `macos-14`).  Local machines and local guest VMs should only perform fast pre-flight validation or handle tasks strictly requiring local resources.

---

## 1. The Core Policy

> **Standing Fleet Rule:** If a repository is **public**, all heavy build, compilation, test matrix, and visual verification workloads default to GitHub Actions hosted runners.&nbsp; Do not burn local CPU cycles, heat, or battery on long-running test suites or multi-architecture Xcode builds when GitHub provides free cloud compute.

---

## 2. Workload Allocation Matrix

| Workload Type | Public Repositories (Primary) | Private Repositories | Offline / Local Hardware |
|---|---|---|---|
| **Pre-flight Lint / Syntax** | Local (`git diff --check`, `tsc`) | Local (`git diff --check`, `tsc`) | Local |
| **Targeted Unit Tests** | Local fast lane (<10s) | Local fast lane (<10s) | Local |
| **Full Vitest / Test Suite** | GitHub Actions (`ubuntu-latest`) | Local worktree / CI | Local worktree |
| **Playwright / Browser E2E** | GitHub Actions (`ubuntu-latest`) | Cloud Box / VPS container | Local VM / Headless |
| **Xcode Simulator Builds** | GitHub Actions (`macos-15` runner) | Headless macOS Guest VM (`mac_vm`) | Headless macOS Guest VM |
| **TestFlight ASC Distribution** | GitHub Actions (with secrets) | Headless macOS Guest VM | Headless macOS Guest VM |

---

## 3. Why Offloading Compute to GitHub Matters

1. **Free for Public Repositories:**  
   GitHub provides unlimited standard Linux (`ubuntu-latest`) runner minutes and free Apple Silicon macOS runners (`macos-14`, `macos-15`) for all public open-source repositories.&nbsp; Leveraging this compute costs \$0.00.

2. **Operator Focus & Zero Desktop Contention:**  
   Running end-to-end tests or iOS Simulator tests locally inevitably risks popping up windows, stealing active keystrokes, or intercepting mouse events while the operator is coding or chatting.&nbsp; Offloading to GitHub cloud runners guarantees 100% uninterrupted local desktop focus.

3. **Hardware Longevity & Battery Life:**  
   Compiling large Swift or C++ targets, indexing DerivedData, and running headless browser clusters consumes substantial memory, spins thermal fans, and rapidly drains laptop battery.&nbsp; Cloud runners absorb this wear and tear.

4. **Guaranteed Clean-Room Reproducibility:**  
   GitHub runners spin up ephemeral virtual machines for every single run.&nbsp; There is zero risk of stale caches, leftover temporary files, or environment drift masking build failures.

---

## 4. Role of the Local Headless macOS Guest VM (`mac_vm`)

The headless macOS Guest VM (`scripts/mac-guest-vm-runner.sh` via Apple Virtualization / Tart) remains an essential piece of infrastructure, specifically reserved for:
- **Private Repositories:** Where GitHub Actions macOS runners incur metered per-minute billing.
- **Hardware Credential Isolation:** Workflows requiring local physical security keys, hardware enclaves, or provisioning identities that cannot be stored in GitHub Secrets.
- **Offline Development:** Air-gapped or travel environments without internet connectivity.
- **Live Local Daemon Integration:** Testing native iOS apps against a locally running daemon on `127.0.0.1:3180` before publishing.

---

## 5. Implementation in CI

Every public repository in the fleet should maintain a comprehensive `.github/workflows/ci.yml` that executes:
1. `verify`: Typecheck, unit test suite, Python compilation, formatting and syntax checks on `ubuntu-latest`.
2. `ios`: Automated `xcodegen` and `xcodebuild` compilation for iOS Simulator on `macos-15`.
3. `e2e`: Headless browser testing on `ubuntu-latest`.

---

## 6. Offloading to Free/Unmetered Cloud VM External Agents

Beyond GitHub Actions, the operator has access to three dedicated external agent platforms that provide dedicated cloud virtual machines with CLI tooling (`infisical`, `gh`, `sentry`, etc.) already authenticated:

### The Cloud Agent Inventory

1. **Instinct (Dispatched via iMessage):**
   - **Environment:** Dedicated cloud VM.
   - **Concurrency:** Operates serially on focused single-agent tasks.
   - **Best Fit:** Discrete off-machine commands, targeted scripts, or alert remediation.

2. **Meta Muse (Dispatched via Mac / iOS Apps):**
   - **Environment:** Dedicated cloud VM shared across bots.
   - **Compute Pricing:** **Unmetered pure compute time** — Meta does not charge for background VM execution hours, only for direct model queries.
   - **Best Fit:** Multi-day or multi-week heavy compute jobs where an agent configures the automation once and lets bash/system utilities execute headlessly in the background.
     *(Real Fleet Example: Muse converting 505GB of video files from H.264 to H.265 with metadata preservation, syncing back into iCloud Photos, and cleaning up originals over several weeks without burning ongoing AI tokens).*

3. **Grok Bot (Dispatched via X/Grok Interfaces):**
   - **Environment:** Dedicated cloud VM shared across bots.
   - **Best Fit:** Fast cloud-side script execution, batch repository scraping, and research workflows.

### The Offloading Threshold Rule (Avoid Coordination Overhead)

> **The 2x Coordination Rule:** Never spend more time formatting, briefing, and babysitting an external offloaded agent than it would take to execute the task locally or on GitHub Actions.&nbsp; Small, interactive, or tightly coupled 1-step edits must stay in the local workspace.
>
> **When to Offload:**
> - Batch media transcoding or large-scale file processing (>10GB).
> - Long-running database migrations or historical log parsing.
> - Multi-day asynchronous scrapers, formatters, or archival syncs.
> - Background maintenance tasks where script setup is amortized over days of CPU runtime.

---

## 7. Cloud Platform Economics — Unmetered VMs vs. Cursor Cloud & Ultra Tier

Understanding provider billing structures and tiers is critical to maximize value without burning monthly resource budgets:

- **Unmetered Cloud VMs (Meta Muse, Grok Bot, Instinct):**
  These platforms decouple LLM token pricing from VM CPU runtime.&nbsp; Once a long-running process (e.g. ffmpeg, curl, python batch script) is spawned, the VM runs for hours or weeks at zero additional compute cost.&nbsp; They are the optimal target for massive background batch jobs.

- **Cursor Cloud & Ultra Tier Utilization (Owner Preference):**
  - **Non-Coding Compute Warning:** Never route pure background batch tasks (e.g. video transcoding, heavy log crunching) through Cursor Cloud, as extra VM compute credits rapidly drain the monthly allocation.
  - **Agentic Coding Workloads (Composer 2.5):** For agentic coding tasks, the owner subscribes to Cursor's **Ultra tier** with substantial monthly quota.&nbsp; The fleet has ample coding work to fully utilize this entire tier each month.
  - **Model Directive:** **Always select Composer 2.5 (or the newest available Composer model)** in Cursor to ensure maximum reasoning and coding capability while exhausting the monthly Ultra quota effectively.

---

## 8. Canonical Cloud MCP Endpoints

When connecting cloud agents or external tools across the fleet, use the designated HTTPS MCP endpoints:

1. **Grok / Shared Fleet Agents MCP:**
   `https://agents.jays.services/mcp`
   Provides unified access to shared fleet memory (recall search, stats, contribute), fleet coordination manifests, and agent services.

2. **BotFleet Admin MCP:**
   `https://botfleetadmin.jays.services/mcp`
   Provides administrative control, bot orchestration, session inspection, and container/mount dispatch across BotFleet.
