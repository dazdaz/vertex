# Vertex Garden List

A collection of tools and scripts for interacting with AI models through Google AI Studio and Vertex AI.

## Setup

### Python Environment

```bash
# Create virtual environment
uv venv

# Activate the virtual environment
source .venv/bin/activate

# Install dependencies
uv pip install -r requirements.txt
```

### Environment Variables

```bash
export PROJECT_ID="daev-playground"
export LOCATION="global"
```

## Tools

### query_gemini.sh

An interactive bash script for querying AI models through **Google AI Studio** or **Vertex AI** endpoints.

#### Features

- **Multi-endpoint support**: Choose between AI Studio and Vertex AI at runtime
- **Dual authentication**: API key for AI Studio, OAuth for Vertex AI
- **Model discovery**: Dynamic model discovery for Vertex AI with caching
- **Multiple providers**: Support for Anthropic (Claude), Google (Gemini), Meta (Llama), Mistral, and Cohere models
- **Advanced features**: 1M context window support for Claude Sonnet models, streaming responses

#### Usage

```bash
# Interactive mode - select endpoint and model
./query_gemini.sh

# Show help
./query_gemini.sh --help

# List available models
./query_gemini.sh --list

# Refresh Vertex AI model cache
./query_gemini.sh --refresh
```

#### Endpoints

**AI Studio** (Option 1)
- Authentication: API key
- Models: Gemini models (2.0-flash-exp, exp-1206, 1.5-flash, 1.5-pro, etc.)
- Best for: Quick access to latest Gemini experimental models

**Vertex AI** (Option 2)
- Authentication: gcloud OAuth (`gcloud auth login`)
- Models: Anthropic Claude, Google Gemini, Meta Llama, Mistral, Cohere
- Best for: Production use, multi-provider access, enterprise features

#### Example Workflow

```bash
$ ./query_gemini.sh

Select endpoint:
1) AI Studio (API key authentication)
2) Vertex AI (gcloud OAuth authentication)
Enter choice (1-2): 1

Enter your AI Studio API key: ****

Please select a model to use:
1) gemini-2.0-flash-exp
2) gemini-exp-1206
3) gemini-1.5-pro
...

Enter number (1-6): 1

Please enter your prompt. Press Ctrl+D when you are finished.
What is the capital of France?
^D

Sending request...
Response saved to out.json.

--- Formatted Output ---
The capital of France is Paris.
```

#### Notes

- Some Vertex AI models (e.g., Claude Opus 4.1) require EULA acceptance before use
- Claude Sonnet models support optional 1M context window
- Vertex AI model list is cached for 24 hours (use `--refresh` to update)
- Responses are saved to `out.json` and formatted output is displayed

### show_endpoints.sh

A utility script to display endpoint information for both **Google AI Studio** and **Vertex AI**.

#### Features

- **AI Studio endpoints**: Shows base URLs, API versions, common endpoints, and available models
- **Vertex AI endpoints**: Lists deployed endpoints across all GCP regions or a specific region
- **Flexible filtering**: Show only AI Studio, only Vertex AI, or both
- **Region-specific queries**: Check Vertex AI endpoints in a specific region

#### Usage

```bash
# Show both AI Studio and Vertex AI endpoints
./show_endpoints.sh

# Show only AI Studio endpoints
./show_endpoints.sh --aistudio

# Show only Vertex AI endpoints
./show_endpoints.sh --vertex

# Show Vertex AI endpoints for a specific region
./show_endpoints.sh --vertex --region us-central1

# Show help
./show_endpoints.sh --help
```

#### Output Information

**AI Studio:**
- Base endpoint URL
- API versions (v1beta, v1)
- Common endpoint patterns (generateContent, streamGenerateContent)
- Authentication method
- Available Gemini models

**Vertex AI:**
- Base endpoint URL
- API version
- Endpoint format with placeholders
- Supported publishers (Anthropic, Google, Meta, Mistral, Cohere)
- Deployed endpoints per region (via `gcloud ai endpoints list`)

## Resources

- [Vertex AI Pricing](https://cloud.google.com/vertex-ai/pricing)
- [AI Studio Pricing](https://ai.google.dev/pricing)
