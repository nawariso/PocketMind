# ADR 0002: Typhoon for OCR

- Status: Accepted

## Context

`gemma4:12b` ran on the 4 GB GPU through heavy CPU/RAM offload, was slow for general use, and did not meet the user's OCR quality expectations across real images. OCR should be separated from general chat.

The exact Hugging Face Typhoon OCR 1.5 2B checkpoint was considered, but the authors' recommended on-device Ollama path at evaluation time was `scb10x/typhoon-ocr1.5-3b`; third-party GGUF conversions risked accuracy loss.

## Decision

Route `corp-ocr` to `scb10x/typhoon-ocr1.5-3b` and treat it as a constrained OCR model.

Open WebUI metadata must retain:

```text
vision=true
builtin_tools=false
```

Use temperature 0.1 and the extraction prompt documented in the root README. Keep context 8192 for observed image-prompt needs.

## Consequences

- Better role specialization and smaller weights than Gemma 4 12B.
- The model is not a general chat/VQA replacement.
- Tool definitions must never be sent to it.
- OCR remains generative and requires human review for important documents.

## Alternatives considered

- Keep Gemma 4 12B: rejected for latency/resource pressure and user-observed OCR quality.
- Exact 2B Transformers service: deferred because it adds a separate runtime and operational complexity.
- Third-party 2B GGUF: rejected as the default due accuracy risk.

## Rollback

Evaluate another OCR model behind a `lab-*` alias, verify a known fixture and Open WebUI capability routing, then change only the `corp-ocr` physical mapping in a reviewed change.
