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
- **Live Local Daemon Integration:** Testing native iOS apps against a locally running daemon on `127.0.0.1:3080` before publishing.

---

## 5. Implementation in CI

Every public repository in the fleet should maintain a comprehensive `.github/workflows/ci.yml` that executes:
1. `verify`: Typecheck, unit test suite, Python compilation, formatting and syntax checks on `ubuntu-latest`.
2. `ios`: Automated `xcodegen` and `xcodebuild` compilation for iOS Simulator on `macos-15`.
3. `e2e`: Headless browser testing on `ubuntu-latest`.
