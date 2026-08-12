# README One-command Setup and Mermaid Design

## Goal

Make the primary startup path unmistakable: after installing the platform prerequisites, a user can start the complete stack with one `setup.ps1` invocation. Replace the ASCII architecture sketch with a Mermaid diagram that renders clearly on GitHub and other Mermaid-aware Markdown viewers.

## Scope

- Replace the introductory ASCII architecture block with a Mermaid `flowchart LR`.
- Show the full request path from the browser through Open WebUI and LiteLLM to the selected Ollama runtime.
- Show PostgreSQL as LiteLLM persistence and Prometheus/Grafana as the monitoring path.
- Show NVIDIA telemetry as profile-specific rather than universally available.
- Rename and rewrite the quick-start section around the single command `pwsh ./scripts/setup.ps1 -Profile auto -Pull`.
- Explain what the setup command performs and which prerequisites remain the user's responsibility.
- Keep `verify-stack.ps1` as a recommended, separate end-to-end validation step rather than part of startup.
- Retain the Windows PowerShell 5.1 equivalent command.

## Documentation Behavior

The README must not imply that the repository installs Docker, PowerShell, GPU drivers, or native Ollama. It must state that `setup.ps1` checks prerequisites, resolves a runtime profile, synchronizes the Prometheus token, optionally pulls images and the configured model, starts the selected Compose stack, and waits for required containers to become healthy.

For macOS Apple Silicon, automatic selection uses the native profile. Ollama must already be installed and running, while `-Pull` allows the setup script to fetch a missing configured model. For Windows and Linux, automatic selection uses NVIDIA only when the Docker GPU probe succeeds; otherwise it uses the portable CPU profile.

## Verification

- Run the existing script-portability documentation contract.
- Check that README contains a Mermaid block, the one-command startup example, the PowerShell 5.1 equivalent, and the optional verification wording.
- Confirm that the Mermaid block contains no ASCII architecture block remnants.