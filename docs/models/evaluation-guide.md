# Model Evaluation Guide

## Goal

Decide whether a candidate improves useful quality without exceeding the reference machine's latency, memory, disk, context, or capability constraints.

## Before downloading

Record:

- exact registry identifier and URL;
- publisher/official or third-party status;
- architecture, parameters, quantization, and download size;
- modalities and tool/thinking support;
- license;
- intended workload;
- expected fit against 4 GB VRAM and approximately 24 GB host RAM.

Use Model Lab for reversible evaluation. Never replace `corp-general` or `corp-ocr` before evidence exists.

## Controlled environment

- Use the same configured context (8192 unless testing context specifically).
- Run one heavy inference at a time.
- Record Ollama version, exact tag, profile, and hardware.
- Keep prompt, temperature, output limit, and thinking mode consistent.
- Run at least one cold and two warm samples.
- Inspect `ollama ps` during inference.

## Standard quality suite

### Thai instruction following

Ask for a constrained Thai response with formatting/length requirements. Score instruction compliance and naturalness.

### Thai reasoning

Use a simple but trap-prone problem, such as percentage decrease followed by equal percentage increase. Require concise reasoning and exact arithmetic.

### Coding/debugging

Use a known bug such as Python mutable default arguments. Require root cause and corrected executable code. Verify the code, not only prose.

### Tool calling

Provide a minimal function schema and require the model to call it rather than answer from memory. Verify function name and parsed arguments. Do not send tools to a model that does not declare support.

### Hallucination resistance

Provide insufficient information and check whether the model asks for missing context instead of fabricating facts.

### Structured output

If required, test a JSON schema and parse the result programmatically.

### Vision/OCR

Only for declared vision models. Use a known fixture with Thai, English, numbers, punctuation, and table/layout content. Compare transcription against ground truth. Run without tools for OCR-only models.

## Runtime measurements

Record separately:

- pull/download size;
- cold wall latency;
- warm wall latency;
- prompt/eval tokens per second when available;
- output token count and truncation;
- CPU/GPU placement;
- VRAM and host-memory pressure;
- context used;
- errors/OOM/timeouts;
- whether another production model was loaded.

The Model Lab wall-rate includes HTTP and model-loading overhead; it is not identical to Ollama eval tokens/s.

## Suggested rubric

| Category | Weight |
|---|---:|
| Thai quality/instruction following | 20% |
| Reasoning accuracy | 20% |
| Coding correctness | 15% |
| Tool/structured behavior | 15% |
| Hallucination resistance | 10% |
| Warm latency/rate | 10% |
| Memory and operational fit | 10% |

For OCR candidates, replace coding/tool weights with transcription accuracy/layout fidelity.

## Acceptance gates for this machine

A production candidate should:

- complete representative requests at context 8192 without OOM;
- remain usable under one-request concurrency;
- provide a meaningful quality gain for its role;
- support required capabilities honestly;
- have a rollback path and exact tag;
- preserve `corp-general`/`corp-ocr` client contracts;
- pass smoke tests and invalid-key rejection after integration.

A model may be retained as an opt-in lab model even if too slow for production default.

## Decision outcomes

- **Promote:** update production config/contracts/docs in a reviewed change.
- **Keep experimental:** retain/recreate a `lab-*` alias as needed; do not grant broad access.
- **Reject but retain weights:** remove alias only.
- **Reject and remove:** remove alias with `-DeleteWeights` after shared/production safety checks.

Append material results to `benchmark-log.md` and summarize final status in `catalog.md`.
