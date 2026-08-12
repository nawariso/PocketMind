# README One-command Setup and Mermaid Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Document one-command stack startup and replace the README's ASCII architecture sketch with a readable Mermaid diagram.

**Architecture:** Keep all operational behavior unchanged and update only documentation plus its existing contract test. The README will distinguish prerequisites, automated setup actions, and optional end-to-end verification while retaining platform-specific guidance.

**Tech Stack:** Markdown, Mermaid flowchart syntax, PowerShell documentation contract tests.

## Global Constraints

- The primary startup command is exactly `pwsh ./scripts/setup.ps1 -Profile auto -Pull`.
- Windows PowerShell 5.1 retains its `powershell -ExecutionPolicy Bypass -File` equivalent.
- `setup.ps1` does not install Docker, PowerShell, GPU drivers, or native Ollama.
- `verify-stack.ps1` remains a separate recommended validation step and is not required to start the stack.
- The macOS automatic profile requires native Ollama to be installed and running.
- Existing service addresses, credentials, profiles, and localhost-only networking remain unchanged.

---

### Task 1: Document the one-command startup path

**Files:**
- Modify: `tests/script-portability.ps1`
- Modify: `README.md:5`
- Modify: `README.md:39`
- Modify: `README.md:48`

**Interfaces:**
- Consumes: Current `setup.ps1` parameters `-Profile auto` and `-Pull`.
- Produces: A README architecture diagram and startup instructions protected by the documentation contract.

- [x] **Step 1: Extend the documentation contract**

Add assertions to `tests/script-portability.ps1` requiring these exact README elements:

```powershell
foreach ($term in @(
    '```mermaid',
    'flowchart LR',
    'pwsh ./scripts/setup.ps1 -Profile auto -Pull',
    'powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1 -Profile auto -Pull',
    'recommended end-to-end validation; it is not required to start the stack'
)) {
    Assert-True -Condition ($readme.Contains($term)) -Message "README is missing one-command setup guidance: $term"
}
Assert-True -Condition ($readme -notmatch 'Browser -> Open WebUI') `
    -Message 'README still contains the old ASCII architecture diagram'
```

- [x] **Step 2: Run the contract and confirm the new expectations fail**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\script-portability.ps1
```

Expected: FAIL for missing Mermaid and one-command wording before `README.md` is updated.

- [x] **Step 3: Replace the architecture diagram and rewrite Quick Start**

Replace the introductory ASCII block with a Mermaid `flowchart LR` containing Browser, Open WebUI, LiteLLM, selected Ollama runtime, PostgreSQL, Prometheus, Grafana, and profile-specific NVIDIA exporter nodes. Rewrite Quick Start so that the single primary command appears first, followed by a precise list of what `setup.ps1` performs, prerequisites it does not install, the Windows PowerShell 5.1 equivalent, and the separate optional verifier command.

- [x] **Step 4: Run the documentation contract**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\script-portability.ps1
```

Expected: `Script portability contract passed.`

- [x] **Step 5: Run broader static configuration validation**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\profile-contract.ps1
powershell -ExecutionPolicy Bypass -File .\tests\config-contract.ps1
```

Expected: Both contracts pass, confirming the documentation-only change did not disturb profile or Compose expectations.

- [x] **Step 6: Review the rendered source structure**

Run:

```powershell
Select-String -Path .\README.md -Pattern '^```mermaid$','^flowchart LR$','setup.ps1 -Profile auto -Pull','not required to start the stack'
```

Expected: One Mermaid opening fence, one flowchart declaration, both PowerShell startup forms, and the optional-verification statement. Commit is intentionally omitted because this workspace is not a Git repository.
