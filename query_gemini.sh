#!/bin/bash

# Multi-endpoint script for querying AI models via Google AI Studio or Vertex AI
# Added: 18 Nov 2025 - Support for both AI Studio and Vertex AI endpoints
# Added: 01 Oct 2025 - 1M context window support for Claude Sonnet models
# Added: 30 Sep 2025 - Added support for Claude Sonnet 4.5
# Claude Opus 4.1 - Accept the EULA for this model in Vertex UI or from gcloud ai ...
# https://cloud.google.com/vertex-ai/pricing

PROJECT_ID="my-playground"
OUTFILE="out.json"
LOCATION="global"
VERTEX_ENDPOINT="https://aiplatform.googleapis.com"
AISTUDIO_ENDPOINT="https://generativelanguage.googleapis.com"

# Function to display help
show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

A script to interact with various AI models through Google AI Studio or Vertex AI.

OPTIONS:
    -h, --help      Show this help message and exit
    -l, --list      List all available models and exit
    -r, --refresh   Refresh the model cache (Vertex AI only) and exit
    
ENDPOINTS:
    This script supports two endpoints:
    1. Google AI Studio - Uses API key authentication, primarily for Gemini models
    2. Vertex AI - Uses gcloud OAuth authentication, supports multiple model providers
    
IMPORTANT:
    Before using certain models (particularly Claude Opus 4.1 on Vertex AI), you must 
    accept the End User License Agreement (EULA) through either:
    - The Vertex AI UI in Google Cloud Console
    - Using gcloud CLI: gcloud ai models describe <model-name> --project=<project-id>
    
    Failure to accept the EULA will result in API errors when querying the endpoint.

USAGE EXAMPLE:
    1. Run the script: $0
    2. Select an endpoint (AI Studio or Vertex AI)
    3. Select a model from the menu
    4. Enter your prompt (press Ctrl+D when finished)
    5. View the response

PROJECT CONFIGURATION (Vertex AI):
    Current Project ID: $PROJECT_ID
    Location: $LOCATION
    
For more information about pricing, visit:
https://cloud.google.com/vertex-ai/pricing
https://ai.google.dev/pricing

EOF
}

# Function to discover all available models from Vertex AI API
discover_vertex_models() {
    local cache_file="/tmp/vertex_models_cache.json"
    local cache_age=$((60 * 60 * 24)) # 24 hours in seconds
    
    # Check if cache exists and is fresh
    if [[ -f "$cache_file" ]] && [[ $(find "$cache_file" -mtime -1 2>/dev/null) ]]; then
        if [[ "$1" != "force" ]]; then
            echo "Using cached model list (use -r to refresh)" >&2
            cat "$cache_file"
            return
        fi
    fi
    
    echo "Discovering available models from Vertex AI API..." >&2
    
    ACCESS_TOKEN=$(gcloud auth print-access-token)
    if [ -z "$ACCESS_TOKEN" ]; then
        echo "Error: Access token is empty. Please authenticate with gcloud auth login." >&2
        exit 1
    fi
    
    # Query for all publishers
    local publishers=("anthropic" "google" "meta" "mistral" "cohere")
    local all_models="[]"
    
    for publisher in "${publishers[@]}"; do
        echo "Checking $publisher models..." >&2
        
        # List models for this publisher
        local response=$(curl -s \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            "${VERTEX_ENDPOINT}/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/${publisher}/models")
        
        if [[ $? -eq 0 ]] && [[ -n "$response" ]]; then
            # Parse the response and add publisher info
            local models=$(echo "$response" | jq -r '.models[]?.name // empty' 2>/dev/null | while read -r model; do
                if [[ -n "$model" ]]; then
                    # Extract just the model name from the full path
                    model_name=$(echo "$model" | awk -F'/' '{print $NF}')
                    
                    # Determine the appropriate method based on publisher
                    if [[ "$publisher" == "anthropic" ]]; then
                        method="streamRawPredict"
                    else
                        method="streamGenerateContent"
                    fi
                    
                    echo "{\"publisher\": \"$publisher\", \"model\": \"$model_name\", \"method\": \"$method\"}"
                fi
            done | jq -s '.')
            
            if [[ -n "$models" ]] && [[ "$models" != "[]" ]]; then
                all_models=$(echo "$all_models" "$models" | jq -s 'add')
            fi
        fi
    done
    
    # Also check for models using the models list endpoint
    echo "Checking additional models via models endpoint..." >&2
    local models_response=$(curl -s \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "${VERTEX_ENDPOINT}/v1/projects/${PROJECT_ID}/locations/${LOCATION}/models")
    
    if [[ $? -eq 0 ]] && [[ -n "$models_response" ]]; then
        local additional_models=$(echo "$models_response" | jq -r '.models[]?.name // empty' 2>/dev/null | while read -r model; do
            if [[ -n "$model" ]]; then
                # Parse the model path to extract publisher and model name
                # Format: projects/{project}/locations/{location}/models/{model}
                model_id=$(echo "$model" | awk -F'/' '{print $NF}')
                
                # Try to determine publisher from model name
                if [[ "$model_id" == *"claude"* ]]; then
                    publisher="anthropic"
                    method="streamRawPredict"
                elif [[ "$model_id" == *"gemini"* ]]; then
                    publisher="google"
                    method="streamGenerateContent"
                elif [[ "$model_id" == *"llama"* ]]; then
                    publisher="meta"
                    method="streamGenerateContent"
                elif [[ "$model_id" == *"mistral"* ]]; then
                    publisher="mistral"
                    method="streamGenerateContent"
                else
                    # Skip unknown models
                    return
                fi
                
                echo "{\"publisher\": \"$publisher\", \"model\": \"$model_id\", \"method\": \"$method\"}"
            fi
        done | jq -s '.')
        
        if [[ -n "$additional_models" ]] && [[ "$additional_models" != "[]" ]]; then
            all_models=$(echo "$all_models" "$additional_models" | jq -s 'add | unique_by(.model)')
        fi
    fi
    
    # If we still have no models, fall back to known defaults
    if [[ "$all_models" == "[]" ]]; then
        echo "Could not discover models from API, using defaults..." >&2
        all_models='[
            {"publisher": "anthropic", "model": "claude-3-7-sonnet@20250219", "method": "streamRawPredict"},
            {"publisher": "anthropic", "model": "claude-sonnet-4@20250514", "method": "streamRawPredict"},
            {"publisher": "anthropic", "model": "claude-opus-4-1@20250805", "method": "streamRawPredict"},
            {"publisher": "anthropic", "model": "claude-sonnet-4-5@20250929", "method": "streamRawPredict"},
            {"publisher": "anthropic", "model": "claude-haiku-4-5@20251001", "method": "streamRawPredict"},
            {"publisher": "google", "model": "gemini-2.5-flash@default", "method": "streamGenerateContent"},
            {"publisher": "google", "model": "gemini-2.5-pro@default", "method": "streamGenerateContent"},
            {"publisher": "google", "model": "gemini-1.5-flash-001", "method": "streamGenerateContent"},
            {"publisher": "google", "model": "gemini-1.5-pro-001", "method": "streamGenerateContent"},
            {"publisher": "google", "model": "gemini-3-pro-preview-11-2025", "method": "streamGenerateContent"},
            {"publisher": "google", "model": "gemini-3.0-pro-eval-001", "method": "streamGenerateContent"},
            {"publisher": "meta", "model": "llama3-405b-instruct-maas", "method": "streamGenerateContent"},
            {"publisher": "meta", "model": "llama3-70b-instruct-maas", "method": "streamGenerateContent"},
            {"publisher": "meta", "model": "llama3-8b-instruct-maas", "method": "streamGenerateContent"},
            {"publisher": "mistral", "model": "mistral-large@latest", "method": "streamGenerateContent"},
            {"publisher": "mistral", "model": "mistral-nemo@latest", "method": "streamGenerateContent"},
            {"publisher": "cohere", "model": "command-r-plus", "method": "streamGenerateContent"},
            {"publisher": "cohere", "model": "command-r", "method": "streamGenerateContent"}
        ]'
    fi
    
    # Save to cache
    echo "$all_models" > "$cache_file"
    echo "$all_models"
}

# Function to get AI Studio models (predefined list)
get_aistudio_models() {
    echo '[
        {"publisher": "google", "model": "gemini-2.0-flash-exp", "method": "streamGenerateContent"},
        {"publisher": "google", "model": "gemini-exp-1206", "method": "streamGenerateContent"},
        {"publisher": "google", "model": "gemini-2.0-flash-thinking-exp-1219", "method": "streamGenerateContent"},
        {"publisher": "google", "model": "gemini-1.5-flash", "method": "streamGenerateContent"},
        {"publisher": "google", "model": "gemini-1.5-flash-8b", "method": "streamGenerateContent"},
        {"publisher": "google", "model": "gemini-1.5-pro", "method": "streamGenerateContent"}
    ]'
}

# Function to list available models
list_models() {
    local endpoint_type="$1"
    local models_json
    
    if [[ "$endpoint_type" == "aistudio" ]]; then
        models_json=$(get_aistudio_models)
        echo "Available models (AI Studio):"
    else
        models_json=$(discover_vertex_models)
        echo "Available models (Vertex AI):"
    fi
    
    echo "=================="
    
    # Parse and display models grouped by publisher
    local publishers=$(echo "$models_json" | jq -r '.[].publisher' | sort -u)
    
    local counter=1
    for publisher in $publishers; do
        echo ""
        echo "[$publisher]"
        echo "---"
        
        echo "$models_json" | jq -r --arg pub "$publisher" '.[] | select(.publisher == $pub) | .model' | while read -r model; do
            # Add notes for specific models
            note=""
            if [[ "$model" == *"opus"* ]]; then
                note=" (EULA acceptance required)"
            elif [[ "$model" == *"sonnet"* ]]; then
                note=" (Supports 1M context window)"
            elif [[ "$model" == *"405b"* ]]; then
                note=" (405B parameters)"
            elif [[ "$model" == *"70b"* ]]; then
                note=" (70B parameters)"
            elif [[ "$model" == *"8b"* ]]; then
                note=" (8B parameters)"
            fi
            
            printf "%3d. %-50s%s\n" "$counter" "$model" "$note"
            ((counter++))
        done
    done
    
    echo ""
    if [[ "$endpoint_type" != "aistudio" ]]; then
        echo "Note: Some models require EULA acceptance before use."
    fi
    echo "Total models available: $(echo "$models_json" | jq 'length')"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -l|--list)
            echo "Select endpoint to list models:"
            echo "1) AI Studio"
            echo "2) Vertex AI"
            read -p "Enter choice (1-2): " list_choice
            case $list_choice in
                1) list_models "aistudio" ;;
                2) list_models "vertex" ;;
                *) echo "Invalid choice"; exit 1 ;;
            esac
            exit 0
            ;;
        -r|--refresh)
            discover_vertex_models "force" > /dev/null
            echo "Model cache refreshed."
            list_models "vertex"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
    shift
done

# --- Endpoint Selection ---

echo "Select endpoint:"
echo "1) AI Studio (API key authentication)"
echo "2) Vertex AI (gcloud OAuth authentication)"
read -p "Enter choice (1-2): " endpoint_choice

case $endpoint_choice in
    1)
        ENDPOINT_TYPE="aistudio"
        echo "Using AI Studio endpoint"
        read -p "Enter your AI Studio API key: " -s API_KEY
        echo ""
        if [ -z "$API_KEY" ]; then
            echo "Error: API key cannot be empty."
            exit 1
        fi
        models_json=$(get_aistudio_models)
        ;;
    2)
        ENDPOINT_TYPE="vertex"
        echo "Using Vertex AI endpoint"
        models_json=$(discover_vertex_models)
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

# --- Model Selection ---

models_array=()

# Build array for selection
while IFS= read -r line; do
    models_array+=("$line")
done < <(echo "$models_json" | jq -r '.[] | "\(.publisher)/\(.model):\(.method)"')

if [[ ${#models_array[@]} -eq 0 ]]; then
    echo "Error: No models available"
    exit 1
fi

echo "Please select a model to use:"
PS3="Enter number (1-${#models_array[@]}): "
select selection in "${models_array[@]}"; do
  if [[ -n "$selection" ]]; then
    echo "You selected: $selection"
    
    # Check if model might require EULA (Vertex AI only)
    if [[ "$ENDPOINT_TYPE" == "vertex" ]] && [[ "$selection" == *"opus"* ]]; then
        echo ""
        echo "⚠️  WARNING: This model requires EULA acceptance."
        echo "   If you haven't accepted the EULA yet, the API call will fail."
        echo "   Accept it through Vertex AI UI or gcloud CLI before proceeding."
        read -p "Continue? (y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Exiting..."
            exit 0
        fi
    fi
    break
  else
    echo "Invalid selection. Please try again."
  fi
done

# Parse the selection to get the publisher and model ID
PUBLISHER=${selection%%/*}      # Gets everything before the first "/"
MODEL=${selection#*/}           # Gets everything after the first "/"

# Check if the selected model is a Sonnet variant for 1M context window support
IS_SONNET=false
if [[ "$MODEL" == *"sonnet"* ]]; then
  IS_SONNET=true
  echo "Note: This Sonnet model supports 1M context window."
  read -p "Enable 1M context window? (y/n, default: n): " ENABLE_1M
  ENABLE_1M=${ENABLE_1M:-n}
fi

# This block replaces the need for request-*.json files.
echo -e "\nPlease enter your prompt. Press Ctrl+D when you are finished."
USER_PROMPT=$(cat)

# Check if the prompt is empty
if [ -z "$USER_PROMPT" ]; then
    echo "Error: Prompt cannot be empty."
    exit 1
fi

# Get access token for Vertex AI
if [[ "$ENDPOINT_TYPE" == "vertex" ]]; then
    ACCESS_TOKEN=$(gcloud auth print-access-token)
    if [ -z "$ACCESS_TOKEN" ]; then
      echo "Error: Access token is empty. Please authenticate with gcloud auth login."
      exit 1
    fi
fi

# Dynamically build the JSON payload ---
# Use jq to safely inject the user's prompt into the correct JSON structure.
# This handles all special characters, quotes, and newlines automatically.
if [[ "$PUBLISHER" == "anthropic" ]]; then
  # Build base payload
  if [[ "$IS_SONNET" == true && ( "$ENABLE_1M" == "y" || "$ENABLE_1M" == "Y" ) ]]; then
    # Include the beta header for 1M context window
    JSON_PAYLOAD=$(jq -n \
                     --arg prompt "$USER_PROMPT" \
                     '{anthropic_version: "vertex-2023-10-16", messages: [{role: "user", content: $prompt}], max_tokens: 32000, stream: true}')
    ANTHROPIC_BETA_HEADER="context-1m-2025-08-07"
  else
    JSON_PAYLOAD=$(jq -n \
                     --arg prompt "$USER_PROMPT" \
                     '{anthropic_version: "vertex-2023-10-16", messages: [{role: "user", content: $prompt}], max_tokens: 32000, stream: true}')
  fi
else
  # For Google, Meta, Mistral, Cohere models
  JSON_PAYLOAD=$(jq -n \
                   --arg prompt "$USER_PROMPT" \
                   '{contents: [{role: "user", parts: [{text: $prompt}]}]}')
fi

# --- API Call ---

echo -e "\nSending request..."

# Build the appropriate URL and curl command based on endpoint type
if [[ "$ENDPOINT_TYPE" == "aistudio" ]]; then
    # AI Studio endpoint
    API_URL="${AISTUDIO_ENDPOINT}/v1beta/models/${MODEL##*:}:streamGenerateContent?key=${API_KEY}"
    
    HTTP_CODE=$(curl -w "%{http_code}" -o "$OUTFILE" \
        -X POST \
        -H "Content-Type: application/json; charset=utf-8" \
        -d "$JSON_PAYLOAD" \
        "$API_URL")
else
    # Vertex AI endpoint
    # Build curl command with conditional beta header
    if [[ "$PUBLISHER" == "anthropic" && -n "$ANTHROPIC_BETA_HEADER" ]]; then
      HTTP_CODE=$(curl -w "%{http_code}" -o "$OUTFILE" \
        -X POST \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json; charset=utf-8" \
        -H "anthropic-beta: ${ANTHROPIC_BETA_HEADER}" \
        -d "$JSON_PAYLOAD" \
        "${VERTEX_ENDPOINT}/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/${PUBLISHER}/models/${MODEL##*:}")
    else
      HTTP_CODE=$(curl -w "%{http_code}" -o "$OUTFILE" \
        -X POST \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json; charset=utf-8" \
        -d "$JSON_PAYLOAD" \
        "${VERTEX_ENDPOINT}/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/${PUBLISHER}/models/${MODEL##*:}")
    fi
fi

if [[ "$HTTP_CODE" -ne 200 ]]; then
    echo "Error: API call failed with HTTP status code $HTTP_CODE."
    
    # Check for EULA-related error (Vertex AI only)
    if [[ "$ENDPOINT_TYPE" == "vertex" ]] && ([[ "$HTTP_CODE" -eq 403 ]] || [[ "$HTTP_CODE" -eq 400 ]]); then
        echo ""
        echo "⚠️  This might be an EULA acceptance issue."
        echo "   Please ensure you've accepted the EULA for this model."
    fi
    
    echo "API Response:"
    cat "$OUTFILE"
    exit 1
fi

echo "Response saved to $OUTFILE."

# --- Format Output ---

echo -e "\n--- Formatted Output ---"
# Use the correct parser based on the publisher
if [[ "$PUBLISHER" == "anthropic" ]]; then
  # Parser for Anthropic's streaming format (Server-Sent Events)
  cat "$OUTFILE" | grep '^data:' | sed 's/^data: //' | jq -j 'select(.type == "content_block_delta") | .delta.text' 2>/dev/null; echo
else
  # Parser for Google, Meta, Mistral, Cohere streaming format (a stream of JSON objects)
  cat "$OUTFILE" | jq -r 'map(.candidates[0].content.parts[0].text) | join("")' 2>/dev/null || \
  cat "$OUTFILE" | jq -r '.candidates[0].content.parts[0].text' 2>/dev/null || \
  echo "Could not parse response. Check $OUTFILE for raw output."
fi
