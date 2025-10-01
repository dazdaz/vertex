#!/bin/bash

# Added: 01 Oct 2025 - 1M context window support for Claude Sonnet models
# Added: 30 Sep 2025 - Added support for Claude Sonnet 4.5
# Claude Opus 4.1 - Accept the EULA for this model in Vertex UI or from gcloud ai ...
# https://cloud.google.com/vertex-ai/pricing

PROJECT_ID="daev-playground"
OUTFILE="out.json"
LOCATION="global"
ENDPOINT="https://aiplatform.googleapis.com"

# --- Model Selection ---

# 1. Define the list of available models in an array
MODELS=(
  "anthropic/claude-3-7-sonnet@20250219:streamRawPredict"
  "anthropic/claude-sonnet-4@20250514:streamRawPredict"
  "anthropic/claude-opus-4-1@20250805:streamRawPredict"
  "anthropic/claude-sonnet-4-5@20250929:streamRawPredict"
  "google/gemini-2.5-flash@default:streamGenerateContent"
  "google/gemini-2.5-pro@default:streamGenerateContent"
)

# 2. Display a menu and prompt the user for a selection
echo "Please select a model to use:"
PS3="Enter number (1-6): "
select selection in "${MODELS[@]}"; do
  if [[ -n "$selection" ]]; then
    echo "You selected: $selection"
    break
  else
    echo "Invalid selection. Please try again."
  fi
done

# 3. Parse the selection to get the publisher and model ID
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


ACCESS_TOKEN=$(gcloud auth print-access-token)
if [ -z "$ACCESS_TOKEN" ]; then
  echo "Error: Access token is empty. Please authenticate with gcloud auth login."
  exit 1
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
elif [[ "$PUBLISHER" == "google" ]]; then
  JSON_PAYLOAD=$(jq -n \
                   --arg prompt "$USER_PROMPT" \
                   '{contents: [{role: "user", parts: [{text: $prompt}]}]}')
fi

# --- API Call ---

echo -e "\nSending request..."

# Build curl command with conditional beta header
if [[ "$PUBLISHER" == "anthropic" && -n "$ANTHROPIC_BETA_HEADER" ]]; then
  HTTP_CODE=$(curl -w "%{http_code}" -o "$OUTFILE" \
    -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json; charset=utf-8" \
    -H "anthropic-beta: ${ANTHROPIC_BETA_HEADER}" \
    -d "$JSON_PAYLOAD" \
    "${ENDPOINT}/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/${PUBLISHER}/models/${MODEL}")
else
  HTTP_CODE=$(curl -w "%{http_code}" -o "$OUTFILE" \
    -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$JSON_PAYLOAD" \
    "${ENDPOINT}/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/${PUBLISHER}/models/${MODEL}")
fi

if [[ "$HTTP_CODE" -ne 200 ]]; then
    echo "Error: API call failed with HTTP status code $HTTP_CODE."
    echo "API Response:"
    cat "$OUTFILE"
    exit 1
fi

echo "Response saved to $OUTFILE."

# --- Format Output ---

echo -e "\n--- Formatted Output ---"
# 5. Use the correct parser based on the publisher
if [[ "$PUBLISHER" == "anthropic" ]]; then
  # Parser for Anthropic's streaming format (Server-Sent Events)
  cat "$OUTFILE" | grep '^data:' | sed 's/^data: //' | jq -j 'select(.type == "content_block_delta") | .delta.text'; echo
elif [[ "$PUBLISHER" == "google" ]]; then
  # Parser for Google's streaming format (a stream of JSON objects)
  cat "$OUTFILE" | jq -r 'map(.candidates[0].content.parts[0].text) | join("")'
fi
