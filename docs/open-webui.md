# Open WebUI accounts, model access and OCR

## Open WebUI login

Open `http://localhost:3000`. On a fresh installation, set `WEBUI_ADMIN_EMAIL` and `WEBUI_ADMIN_PASSWORD` before startup and sign in with that administrator. Leaving them unset allows the first registered account to become administrator. Select `default-general` for general text work or `default-ocr` for document images. Open WebUI connects only to LiteLLM; direct Ollama access is disabled.

## Thai and English OCR with Typhoon

`default-ocr` routes to `scb10x/typhoon-ocr1.5-3b`, the on-device Ollama build recommended by the Typhoon OCR 1.5 authors. The exact Hugging Face checkpoint `typhoon-ai/typhoon-ocr1.5-2b` uses Qwen3-VL 2B; the recommended Ollama build uses a quantized Qwen2.5-VL 3B model. This distinction is intentional because the authors warn that third-party GGUF conversions may reduce OCR accuracy.

This is a task-specific OCR model, not a general chat or VQA model. Its Ollama build supports completion and vision but not tool calling. In Open WebUI, keep `Built-in Tools: Off` for `default-ocr`; otherwise Open WebUI can attach a `tools` payload and Ollama will reject the request. Start a new chat, select `default-ocr`, attach one document image, set temperature to `0.1`, and use the model's required prompt:

```text
Extract all text from the image.

Instructions:
- Only return the clean Markdown.
- Do not include any explanation or extra text.
- You must include all information on the page.

Formatting Rules:
- Tables: Render tables using <table>...</table> in clean HTML format.
- Equations: Render equations using LaTeX syntax with inline ($...$) and block ($$...$$).
- Page Numbers: Wrap page numbers in <page_number>...</page_number>.
- Checkboxes: Use ☐ for unchecked and ☑ for checked boxes.
```

Use `default-general` for complex reasoning or ordinary chat. Typhoon OCR can still hallucinate, so compare important output with the source document. Image inputs consume context tokens; if Ollama reports `exceeds the available context size`, increase `OLLAMA_CONTEXT_LENGTH` in the private `.env` and recreate the Ollama container. Larger contexts consume more RAM and KV-cache memory.

## Admin settings and regular users

For the initial configuration or default-alias migration:

```powershell
pwsh ./scripts/configure-open-webui.ps1 -AdminEmail <admin-email>
```

This configures Task Model → External Models → `default-general`, the default user role and initial public models, and closes sign-up unless `-EnableSignup` is supplied. Review the script options in the [provisioning guide](provisioning-guide.md). Password sign-up does not verify mailbox ownership or enforce an organization email domain. Use reviewed SSO/domain policy for organizational identity.

For a custom model, an administrator creates a Workspace Model based on the LiteLLM alias and grants the intended users/groups read access. Seeing a model as administrator does not prove regular-user access. API keys have separate scopes; see [API access](api-access.md).

Open WebUI stores settings after the first start. Editing `.env` alone generally does not replace saved connections, sign-up, roles or task settings; use Admin Panel or the configuration script. [Privacy mode](privacy.md) deliberately disables persisted configuration and uses reviewed environment settings instead. Accounts, chats and Function Valves are separate data.

## Response problems

A response visible only after refresh needs streaming/WebSocket diagnosis. A long conversation with empty final output needs context/output-budget and provider diagnosis. These are different failure paths; follow [troubleshooting](troubleshooting.md) before changing GPU settings.

## Rename a displayed model

Changing a WebUI display name alone does not rename the LiteLLM alias. Use [Rename a model](models/rename-models.md) for a coordinated compatibility rename. The script retains old API names and stable WebUI IDs so existing clients and chats can continue; new API names require appropriately scoped keys.
