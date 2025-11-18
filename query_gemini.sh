#!/bin/bash

# Multi-endpoint script for querying AI models via Google AI Studio or Vertex AI
# Updated: 18 Nov 2025 - Changed to use GLOBAL Vertex AI endpoint.

PROJECT_ID="genosis-prod"
OUTFILE="out.json"
LOCATION="global" # Set to global location for the global endpoint (Vertex AI)
VERTEX_ENDPOINT="https://aiplatform.googleapis.com" # Global Vertex AI endpoint
AISTUDIO_ENDPOINT="https://generativelanguage.googleapis.com"
MODEL_CACHE_FILE="/tmp/vertex_models_cache.json"

# --- Function Definitions ---

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

# Function to check and enable Vertex AI API
check_enable_api() {
    echo "Checking Vertex AI API status..." >&2
    if ! gcloud services list --enabled --project="$PROJECT_ID" | grep -q "aiplatform.googleapis.com"; then
        echo "Vertex AI API is not enabled. Enabling it now..." >&2
        gcloud services enable aiplatform.googleapis.com --project="$PROJECT_ID"
        if [ $? -eq 0 ]; then
            echo "Vertex AI API enabled successfully." >&2
        else
            echo "Error: Failed to enable Vertex AI API." >&2
            exit 1
        fi
    else
        echo "Vertex AI API is already enabled." >&2
    fi
}

# Function to discover all available models from Vertex AI API (FIXED FOR JQ ERROR)
discover_vertex_models() {
    local cache_file="$MODEL_CACHE_FILE"
    local cache_age=$((60 * 60 * 24)) # 24 hours in seconds
    local force_refresh="$1"
    
    # Check if cache exists and is fresh
    if [[ -f "$cache_file" ]] && [[ $(find "$cache_file" -mtime -1 2>/dev/null) ]] && [[ "$force_refresh" != "force" ]]; then
        echo "Using cached model list (use -r to refresh)" >&2
        cat "$cache_file"
        return
    fi
    
    echo "Discovering available models from Vertex AI API..." >&2
    
    # Ensure API is enabled before discovery
    check_enable_api

    ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null)
    if [ -z "$ACCESS_TOKEN" ]; then
        echo "Error: gcloud authentication required. Run 'gcloud auth application-default login'." >&2
        exit 1
    fi
    
    local RAW_RESPONSE_FILE="/tmp/raw_vertex_response.json"
    local HTTP_CODE

    # API call to list all models from all publishers
    HTTP_CODE=$(curl -s -w "%{http_code}" -X GET \
      -o "$RAW_RESPONSE_FILE" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      "${VERTEX_ENDPOINT}/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/google/models")

    if [[ "$HTTP_CODE" -ne 200 ]]; then
        echo "Warning: Vertex AI model listing failed with HTTP status code $HTTP_CODE." >&2
        echo "Falling back to hardcoded model list." >&2
        
        # Create a fallback cache file
        cat <<EOF > "$cache_file"
google/gemini-1.5-pro-002
google/gemini-1.5-flash-002
google/gemini-1.0-pro
google/gemini-1.0-pro-001
google/gemini-1.0-pro-002
google/gemini-1.5-pro-preview-0409
google/gemini-1.5-flash-preview-0514
EOF
        
        # Append known third-party models
        echo "anthropic/claude-3-opus-20240229" >> "$cache_file"
        echo "anthropic/claude-3-sonnet-20240229" >> "$cache_file"
        echo "anthropic/claude-3-haiku-20240307" >> "$cache_file"
        echo "anthropic/claude-3-5-sonnet-v2@20241022" >> "$cache_file"
        
        cat "$cache_file"
        return
    fi

    # Pipe the raw file to jq for parsing and saving to cache
    cat "$RAW_RESPONSE_FILE" | jq -r '
        .models[] | 
        # Filter for models that are ready to use
        select(.launchStage != "BETA" and .launchStage != "ALPHA" and .launchStage != "UNSPECIFIED") |
        # Format as publisher_name/model_name
        "\(.publisher)/\(.name)"
      ' > "$cache_file" 
      
    # Append known third-party models (simulated discovery)
    echo "anthropic/claude-3-opus-20240229" >> "$cache_file"
    echo "anthropic/claude-3-sonnet-20240229" >> "$cache_file"
    echo "anthropic/claude-3-haiku-20240307" >> "$cache_file"
    
    # Add Google AI Studio models (predefined)
    echo "google/gemini-2.5-flash" >> "$cache_file"
    echo "google/gemini-2.5-pro" >> "$cache_file"
    echo "google/gemini-3-pro-preview" >> "$cache_file"

    cat "$cache_file"
}

# Function to select an endpoint
select_endpoint() {
    echo ""
    echo "--- Select API Endpoint ---"
    echo "1) Google AI Studio (Gemini models only, requires API_KEY)"
    echo "2) Vertex AI (Multi-model provider, requires gcloud auth)"
    read -r -p "Select endpoint (1 or 2): " ENDPOINT_CHOICE
    
    case "$ENDPOINT_CHOICE" in
        1)
            ENDPOINT_TYPE="aistudio"
            # Check for API key in environment variable first
            if [ -n "$GEMINI_API_KEY" ]; then
                API_KEY="$GEMINI_API_KEY"
                echo "Using API key from GEMINI_API_KEY environment variable."
            elif [ -z "$API_KEY" ]; then
                read -r -s -p "Enter Google AI Studio API Key: " API_KEY
                echo
            fi
            ;;
        2)
            ENDPOINT_TYPE="vertex"
            ;;
        *)
            echo "Invalid choice. Exiting."
            exit 1
            ;;
    esac
}

# Function to select the model
select_model() {
    local models
    
    if [[ "$ENDPOINT_TYPE" == "aistudio" ]]; then
        # Hardcoded list for AI Studio (Includes Gemini 3 Pro Preview)
        models="google/gemini-2.5-flash google/gemini-2.5-pro google/gemini-3-pro-preview"
    else
        # Discover models for Vertex AI
        models=$(discover_vertex_models)
    fi
    
    if [ -z "$models" ]; then
        echo "Error: No models found for the selected endpoint." >&2
        exit 1
    fi
    
    echo "" >&2
    echo "--- Available Models ---" >&2
    
    # Create an indexed menu
    local model_array=($models)
    for i in "${!model_array[@]}"; do
        printf "%3d) %s\n" $((i+1)) "${model_array[i]}" >&2
    done
    
    echo "------------------------" >&2
    read -r -p "Select model number: " MODEL_CHOICE
    
    if ! [[ "$MODEL_CHOICE" =~ ^[0-9]+$ ]] || [ "$MODEL_CHOICE" -lt 1 ] || [ "$MODEL_CHOICE" -gt ${#model_array[@]} ]; then
        echo "Invalid model selection. Exiting." >&2
        exit 1
    fi
    
    # Return the selected model name
    echo "${model_array[MODEL_CHOICE-1]}"
}

# --- Main Execution ---

# Parse command line arguments
while getopts "hlr" opt; do
    case "$opt" in
        h)
            show_help
            exit 0
            ;;
        l)
            echo "Listing Vertex AI models..."
            discover_vertex_models
            exit 0
            ;;
        r)
            echo "Refreshing Vertex AI model cache..."
            discover_vertex_models force
            exit 0
            ;;
        *)
            show_help >&2
            exit 1
            ;;
    esac
done

# Start script
select_endpoint

# Get the selected model name
selection=$(select_model)
if [ -z "$selection" ]; then
    echo "Model selection failed. Exiting."
    exit 1
fi

# Parse the selection to get the publisher and model ID
PUBLISHER=${selection%%/*}       # Gets everything before the first "/"
MODEL=${selection#*/}            # Gets everything after the first "/"

# Check if the selected model is a Sonnet variant for 1M context window support
IS_SONNET=false
if [[ "$MODEL" == *"sonnet"* ]]; then
    IS_SONNET=true
    echo "Note: This Sonnet model supports 1M context window."
    read -r -p "Enable 1M context window? (y/n, default: n): " ENABLE_1M
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
    # Ensure API is enabled before making requests
    check_enable_api

    ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null)
    if [ -z "$ACCESS_TOKEN" ]; then
        echo "Error: Access token is empty. Please authenticate with 'gcloud auth application-default login'."
        exit 1
    fi
fi

# Dynamically build the JSON payload ---
# Use jq to safely inject the user's prompt into the correct JSON structure.
if [[ "$PUBLISHER" == "anthropic" ]]; then
    # Build base payload for Anthropic
    ANTHROPIC_BETA_HEADER=""
    if [[ "$IS_SONNET" == true && ( "$ENABLE_1M" == "y" || "$ENABLE_1M" == "Y" ) ]]; then
        # Include the beta header for 1M context window
        ANTHROPIC_BETA_HEADER="context-1m-2025-08-07"
    fi
    
    JSON_PAYLOAD=$(jq -n \
        --arg prompt "$USER_PROMPT" \
        '{anthropic_version: "vertex-2023-10-16", messages: [{role: "user", content: $prompt}], max_tokens: 32000, stream: true}')
else
    # For Google, Meta, Mistral, Cohere models (Gemini format)
    JSON_PAYLOAD=$(jq -n \
        --arg prompt "$USER_PROMPT" \
        '{contents: [{role: "user", parts: [{text: $prompt}]}]}')
fi

# --- API Call ---

echo -e "\nSending request..."

# Build the appropriate URL and curl command based on endpoint type
if [[ "$ENDPOINT_TYPE" == "aistudio" ]]; then
    # AI Studio endpoint (Note: MODEL needs cleanup for API)
    API_MODEL_NAME=${MODEL##*:}
    API_URL="${AISTUDIO_ENDPOINT}/v1beta/models/${API_MODEL_NAME}:streamGenerateContent?key=${API_KEY}"
    
    echo "Request URL: $API_URL"
    
    HTTP_CODE=$(curl -w "%{http_code}" -o "$OUTFILE" \
        -s -X POST \
        -H "Content-Type: application/json; charset=utf-8" \
        -d "$JSON_PAYLOAD" \
        "$API_URL")
else
    # Vertex AI endpoint
    # The API call for Vertex AI uses the global endpoint and global location
    API_URL="${VERTEX_ENDPOINT}/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/${PUBLISHER}/models/${MODEL##*:}:streamGenerateContent"
    
    echo "Request URL: $API_URL"
    
    # Build curl command with conditional beta header
    CURL_HEADERS=(-H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json; charset=utf-8")
    if [[ "$PUBLISHER" == "anthropic" && -n "$ANTHROPIC_BETA_HEADER" ]]; then
      CURL_HEADERS+=(-H "anthropic-beta: ${ANTHROPIC_BETA_HEADER}")
    fi

    HTTP_CODE=$(curl -w "%{http_code}" -o "$OUTFILE" \
        -s -X POST \
        "${CURL_HEADERS[@]}" \
        -d "$JSON_PAYLOAD" \
        "$API_URL")
fi

if [[ "$HTTP_CODE" -ne 200 ]]; then
    echo "Error: API call failed with HTTP status code $HTTP_CODE."
    
    # Check for EULA-related error (Vertex AI only)
    if [[ "$ENDPOINT_TYPE" == "vertex" ]] && ([[ "$HTTP_CODE" -eq 403 ]] || [[ "$HTTP_CODE" -eq 400 ]]); then
        echo ""
        echo "⚠️  This might be an EULA acceptance issue."
        echo "    Please ensure you've accepted the EULA for this model."
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
    # The jq path is complex to handle the streaming response structure (array of objects)
    cat "$OUTFILE" | jq -r '
        if type == "array" then
            # Handle streaming response: map over chunks and extract text
            map(.candidates[0].content.parts[0].text) | join("")
        else
            # Handle non-streaming (single-object) response
            .candidates[0].content.parts[0].text
        end
    ' 2>/dev/null || \
    echo "Could not parse response. Check $OUTFILE for raw output."
fi

# End of script
