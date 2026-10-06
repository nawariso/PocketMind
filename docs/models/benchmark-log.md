# Model Benchmark Log

Measurements below are historical observations from the reference Windows laptop (RTX 3050 Laptop GPU 4 GB, approximately 24 GB host RAM). They are not universal guarantees. Runs used the PocketMind/Ollama stack and generally context 8192 unless noted.

## `llama3.2:3b`

- Role at time of test: former `corp-general`.
- Observed output rate: roughly 35–40 eval tokens/s.
- Thai percentage reasoning: correct (1,000 → 800 → 960).
- Tool call: correct `get_weather` function and Bangkok argument.
- Coding comparison: explanation quality was weaker and the 256-token run did not reach corrected code.
- Decision: removed after Qwen 3 4B showed a better quality/fit trade-off.

## `qwen3.5:4b`

- Official Ollama manifest observed: about 3.39 GB.
- Placement at context 8192: about 54% CPU / 46% GPU; process size about 3.9 GB.
- Thai reasoning run: 51.67 s wall, about 8.86 eval tokens/s, correct result.
- Coding run: 26.89 s wall, about 8.91 eval tokens/s, correct mutable-default fix.
- Tool call: 3.33 s wall, correct function/argument.
- Decision: removed; multimodal overhead made it slower than the selected text-only Qwen 3 model.

## `qwen3:4b-instruct-2507-q4_K_M`

- Official Ollama manifest observed: about 2.497 GB.
- Model: Qwen 3, 4.0B, Q4_K_M; tools/thinking/completion.
- Placement at context 8192: about 37% CPU / 63% GPU; process size about 3.8 GB.
- Thai reasoning: 24.85 s cold/warm-mixed run, about 13.51 eval tokens/s, correct result.
- Coding: 19.25 s 256-token run at about 13.61 eval tokens/s; explanation correct but truncated by budget.
- Focused corrected-code request: 2.25 s, about 17.75 eval tokens/s, valid `items=None` fix.
- Tool call: 1.89 s, correct `get_weather`/Bangkok call.
- LiteLLM alias validation: Thai text request 4.42 s; native tool call 1.91 s.
- Decision: promoted to `corp-general`.

## `gemma4:12b`

- Exact-tag provenance: preserved in the verified historical rollout commit and confirmed to resolve through the Ollama registry during this documentation review.
- Observed download/model size: about 7.6 GB; 11.9B parameters; Q4_K_M.
- Approximate placement: 72% CPU/RAM and 28% GPU; VRAM around 2.6/4 GB in one observation.
- Text inference observation: about 82.2 s.
- OCR with Thinking off on one fixture: about 15.4 s and correct fixture transcription.
- User evaluation on broader images: too slow and OCR quality insufficient.
- Decision: removed and replaced by dedicated Typhoon OCR.

## `scb10x/typhoon-ocr1.5-3b`

- Official on-device Ollama build recommended by Typhoon authors at the time of evaluation.
- Observed model: qwen25vl architecture, 3.8B, Q4_K_M, about 3.2 GB.
- Known fixture included English title, invoice ID, amount, and Thai text.
- Transcription returned all fixture lines correctly in about 25.1 s.
- Limitation: does not support tools. Open WebUI must keep `builtin_tools=false`.
- Decision: promoted to `corp-ocr`.

## Apple M2 reference (MacBook Air Mac14,2, 16 GB, native Ollama)

Measured through the PocketMind stack on one machine with other applications and Docker Desktop (about 7.6 GB for the VM) running, so host memory was under pressure (about 12.8–14 GB used and several GB of swap while measuring). These are single observations, context 8192, not guarantees.

- `qwen3:4b-instruct-2507-q4_K_M` (`corp-general`): `ollama ps` showed 100% GPU (Metal), process size about 3.8 GB at context 8192. Short English request through a personal API key: 1.1 s, 17 total tokens (prompt plus output). Thai two-sentence request: 3.5 s, 130 total tokens with output limited to 120.
- `qwen3:1.7b` (`lab-qwen3-1.7b`, 2.0B reported): Model Lab text test, Thai prompt, 128 output tokens. Cold run 4.10 s (31.2 tokens/s wall rate); warm run 2.38 s (53.7 tokens/s). Wall rate includes request overhead and is not comparable with provider eval tokens/s.
- `scb10x/typhoon-ocr1.5-3b` (`corp-ocr`): a generated Thai and English receipt image (receipt number, two dates, customer name, two line items, total) was returned with all 9 expected fragments, 16.9 s, temperature 0.1, using the documented extraction prompt. The image was synthetic, so this says nothing about scans or photographs.
- Streaming through a personal key delivered 16 chunks for a short count.

## Benchmark hygiene

Future entries must include exact model tag, context, prompt/output budget, cold vs warm status, placement, and ground-truth result. Do not compare Model Lab wall-rate directly with provider eval tokens/s without labeling the metric.
