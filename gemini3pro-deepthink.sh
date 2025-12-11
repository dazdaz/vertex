#!/bin/bash
# ==============================================================================
#  GEMINI 3.0: DEEP THINKING + GOOGLE SEARCH GROUNDING using AIStudio endpoint
# ==============================================================================

# 1. CONFIGURATION
API_KEY="abcd1234"
MODEL="gemini-3-pro-preview"

# Default Settings
PROMPT=""
ENABLE_SEARCH=true
THINKING_LEVEL="high"
MAX_TOKENS=65536
INCLUDE_THOUGHTS=true

# 2. HELP FUNCTION
show_help() {
    cat << 'EOF'
==============================================================================
 GEMINI DEEP THINKING CLI
==============================================================================

USAGE:
    ./gemini-deepthink.sh [OPTIONS]

DESCRIPTION:
    Query Google's Gemini 3.0 API with Deep Thinking and optional 
    Google Search grounding capabilities.

OPTIONS:
    -p, --prompt <text>
        The prompt/question to send to Gemini.
        Required unless reading from stdin with --stdin.

    -s, --stdin
        Read prompt from standard input instead of command line.
        Useful for multi-line prompts or piping content.

    --no-search, --no-grounding
        Disable Google Search grounding (pure reasoning mode).
        Default: Search is ENABLED.

    -t, --thinking-level <level>
        Set the thinking depth level.
        Options: none, low, medium, high
        Default: high

    --no-thoughts
        Exclude thinking process from output (show only final answer).
        Default: Thoughts are INCLUDED.

    -m, --max-tokens <number>
        Maximum output tokens (1-65536).
        Default: 65536

    --model <model-name>
        Specify the Gemini model to use.
        Default: gemini-3-pro-preview

    --api-key <key>
        Override the API key (or set GEMINI_API_KEY env variable).

    -v, --verbose
        Show debug information including full JSON payload.

    -r, --raw
        Output raw JSON response without parsing.

    -h, --help
        Show this help message and exit.

    --version
        Show version information.

EXAMPLES:
    # Basic query with default settings
    ./gemini-deepthink.sh --prompt "Explain quantum entanglement"

    # Disable search grounding for pure reasoning
    ./gemini-deepthink.sh -p "Solve this logic puzzle..." --no-search

    # Use lower thinking level for faster responses
    ./gemini-deepthink.sh -p "What is 2+2?" --thinking-level low

    # Read prompt from file
    cat question.txt | ./gemini-deepthink.sh --stdin

    # Pipe content for analysis
    echo "Analyze this text" | ./gemini-deepthink.sh -s

    # Use environment variable for API key
    GEMINI_API_KEY="your-key" ./gemini-deepthink.sh -p "Hello"

ENVIRONMENT VARIABLES:
    GEMINI_API_KEY    - API key for authentication (overrides built-in key)
    GEMINI_MODEL      - Default model to use

EXIT CODES:
    0    Success
    1    Error (invalid arguments, API error, etc.)

==============================================================================
EOF
    exit 0
}

show_version() {
    echo "gemini-deepthink.sh v1.0.0"
    echo "Gemini 3.0 Deep Thinking CLI Client"
    exit 0
}

# 3. ARGUMENT PARSING
VERBOSE=false
RAW_OUTPUT=false
READ_STDIN=false

# Check for environment variables
[[ -n "$GEMINI_API_KEY" ]] && API_KEY="$GEMINI_API_KEY"
[[ -n "$GEMINI_MODEL" ]] && MODEL="$GEMINI_MODEL"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        --version)
            show_version
            ;;
        -p|--prompt)
            if [[ -n "$2" && "$2" != -* ]]; then
                PROMPT="$2"
                shift
            else
                echo "Error: --prompt requires a text argument."
                echo "Use --help for usage information."
                exit 1
            fi
            ;;
        -s|--stdin)
            READ_STDIN=true
            ;;
        --no-search|--no-grounding)
            ENABLE_SEARCH=false
            ;;
        -t|--thinking-level)
            if [[ -n "$2" && "$2" != -* ]]; then
                case "$2" in
                    none|low|medium|high)
                        THINKING_LEVEL="$2"
                        ;;
                    *)
                        echo "Error: Invalid thinking level '$2'."
                        echo "Valid options: none, low, medium, high"
                        exit 1
                        ;;
                esac
                shift
            else
                echo "Error: --thinking-level requires an argument."
                exit 1
            fi
            ;;
        --no-thoughts)
            INCLUDE_THOUGHTS=false
            ;;
        -m|--max-tokens)
            if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
                if [[ "$2" -ge 1 && "$2" -le 65536 ]]; then
                    MAX_TOKENS="$2"
                else
                    echo "Error: --max-tokens must be between 1 and 65536."
                    exit 1
                fi
                shift
            else
                echo "Error: --max-tokens requires a numeric argument."
                exit 1
            fi
            ;;
        --model)
            if [[ -n "$2" && "$2" != -* ]]; then
                MODEL="$2"
                shift
            else
                echo "Error: --model requires an argument."
                exit 1
            fi
            ;;
        --api-key)
            if [[ -n "$2" && "$2" != -* ]]; then
                API_KEY="$2"
                shift
            else
                echo "Error: --api-key requires an argument."
                exit 1
            fi
            ;;
        -v|--verbose)
            VERBOSE=true
            ;;
        -r|--raw)
            RAW_OUTPUT=true
            ;;
        -*)
            echo "Error: Unknown option '$1'"
            echo "Use --help for usage information."
            exit 1
            ;;
        *)
            # Treat as prompt if no prompt set yet
            if [[ -z "$PROMPT" ]]; then
                PROMPT="$1"
            else
                echo "Error: Unexpected argument '$1'"
                exit 1
            fi
            ;;
    esac
    shift
done

# Read from stdin if requested
if [[ "$READ_STDIN" == true ]]; then
    PROMPT=$(cat)
fi

# Validate required arguments
if [[ -z "$PROMPT" ]]; then
    echo "Error: No prompt provided."
    echo ""
    echo "Usage: ./gemini-deepthink.sh --prompt \"Your question here\""
    echo "       ./gemini-deepthink.sh --help"
    exit 1
fi

if [[ "$API_KEY" == "abcd" || -z "$API_KEY" ]]; then
    echo "Error: No valid API key configured."
    echo "Set GEMINI_API_KEY environment variable or use --api-key option."
    exit 1
fi

# Check for Python (Required for safe JSON handling)
if ! command -v python3 &>/dev/null; then
    echo "Error: 'python3' is required to run this script safely."
    exit 1
fi

# 4. CONSTRUCT URL AND JSON PAYLOAD
URL="https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${API_KEY}"

# We use Python to build the JSON object safely
JSON_PAYLOAD=$(python3 -c "
import json, sys

prompt_text = sys.argv[1]
enable_search = sys.argv[2] == 'true'
thinking_level = sys.argv[3]
include_thoughts = sys.argv[4] == 'true'
max_tokens = int(sys.argv[5])

# Base Configuration
payload = {
    'contents': [{'parts': [{'text': prompt_text}]}],
    'generationConfig': {
        'maxOutputTokens': max_tokens,
        'thinkingConfig': {
            'includeThoughts': include_thoughts,
            'thinkingLevel': thinking_level
        }
    }
}

# Conditionally Inject Google Search Tool
if enable_search:
    payload['tools'] = [{'googleSearch': {}}]

print(json.dumps(payload))
" "$PROMPT" "$ENABLE_SEARCH" "$THINKING_LEVEL" "$INCLUDE_THOUGHTS" "$MAX_TOKENS")

# 5. DISPLAY CONFIGURATION
echo "=========================================================="
echo " Model     : $MODEL"
echo " Thinking  : Level=$THINKING_LEVEL, ShowThoughts=$INCLUDE_THOUGHTS"
if [ "$ENABLE_SEARCH" = true ]; then
    echo " Grounding : ‚úì ENABLED (Google Search)"
else
    echo " Grounding : ‚úó DISABLED (Pure Logic)"
fi
echo " MaxTokens : $MAX_TOKENS"
echo " Prompt    : \"${PROMPT:0:60}$([ ${#PROMPT} -gt 60 ] && echo '...')\""
echo "=========================================================="

if [[ "$VERBOSE" == true ]]; then
    echo ""
    echo "[DEBUG] JSON Payload:"
    echo "$JSON_PAYLOAD" | python3 -m json.tool 2>/dev/null || echo "$JSON_PAYLOAD"
    echo ""
fi

echo "Sending query... (Deep Thinking + Search takes time)"

# 6. EXECUTE REQUEST
SECONDS=0

RESPONSE=$(curl -s -X POST "$URL" \
    -H "Content-Type: application/json" \
    -d "$JSON_PAYLOAD")

DURATION=$SECONDS

# 7. HANDLE RAW OUTPUT MODE
if [[ "$RAW_OUTPUT" == true ]]; then
    echo ""
    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
    exit 0
fi

# 8. PARSE & DISPLAY OUTPUT
echo ""
echo "=========================================================="
echo " Query completed in: ${DURATION} seconds"
echo "=========================================================="

python3 -c "
import sys, json

include_thoughts = sys.argv[1] == 'true'

try:
    raw = sys.stdin.read()
    if not raw.strip():
        print('[Error] Empty response from API.')
        sys.exit(1)

    data = json.loads(raw)
    
    # Check for API Errors
    if 'error' in data:
        print(f\"\n‚úó [API ERROR]: {data['error']['message']}\")
        sys.exit(1)

    candidates = data.get('candidates', [])
    if not candidates:
        print(\"\n‚ö†Ô∏è [No response content received]\")
        sys.exit(0)

    candidate = candidates[0]
    parts = candidate.get('content', {}).get('parts', [])
    grounding = candidate.get('groundingMetadata', {})

    # A. Print Deep Thinking (if enabled)
    if include_thoughts:
        print(\"\n--- üß† DEEP THINKING PROCESS ---\")
        thought_found = False
        for part in parts:
            if 'thought' in part and part['thought']:
                print(part.get('text', '').strip())
                thought_found = True
        if not thought_found:
            print(\"(No thoughts returned. The model may have skipped reasoning.)\")

    # B. Print Grounding Sources (If search was used)
    if grounding and 'groundingChunks' in grounding:
        print(\"\n--- üåç SEARCH SOURCES ---\")
        chunks = grounding.get('groundingChunks', [])
        for i, chunk in enumerate(chunks):
            web = chunk.get('web', {})
            title = web.get('title', 'Source')
            uri = web.get('uri', '#')
            print(f\"[{i+1}] {title} ({uri})\")

    # C. Print Final Answer
    print(\"\n--- üìù FINAL ANSWER ---\")
    for part in parts:
        if 'text' in part and ('thought' not in part or not part['thought']):
            print(part.get('text', '').strip())

except Exception as e:
    print(f\"Failed to parse JSON: {e}\")
    print(\"Raw Response Snippet:\", raw[:500] if 'raw' in dir() else 'N/A')
" "$INCLUDE_THOUGHTS" <<< "$RESPONSE"

echo ""
echo "=========================================================="
