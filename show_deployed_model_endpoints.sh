#!/bin/bash

# A script to display AI Studio and Vertex AI endpoint information across multiple GCP regions.

# Function to display help
show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Display endpoint information for Google AI Studio and Vertex AI.

OPTIONS:
    -h, --help          Show this help message and exit
    -a, --aistudio      Show only AI Studio endpoint information
    -v, --vertex        Show only Vertex AI endpoint information
    -r, --region REGION Show Vertex AI endpoints for a specific region only

EXAMPLES:
    $0                  # Show both AI Studio and Vertex AI endpoints
    $0 --aistudio       # Show only AI Studio endpoints
    $0 --vertex         # Show only Vertex AI endpoints
    $0 -r us-central1   # Show Vertex AI endpoints for us-central1 only

EOF
}

# Function to display AI Studio endpoint information
show_aistudio_endpoints() {
    echo "================================================="
    echo "🌐 Google AI Studio Endpoints"
    echo "================================================="
    echo ""
    echo "Base Endpoint:"
    echo "  https://generativelanguage.googleapis.com"
    echo ""
    echo "API Versions:"
    echo "  • v1beta - Latest features and experimental models"
    echo "  • v1     - Stable API (when available)"
    echo ""
    echo "Common Endpoints:"
    echo "  • List Models:"
    echo "    GET https://generativelanguage.googleapis.com/v1beta/models"
    echo ""
    echo "  • Generate Content (Streaming):"
    echo "    POST https://generativelanguage.googleapis.com/v1beta/models/{model}:streamGenerateContent"
    echo ""
    echo "  • Generate Content (Non-streaming):"
    echo "    POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    echo ""
    echo "Authentication:"
    echo "  • API Key (query parameter): ?key=YOUR_API_KEY"
    echo ""
    echo "Available Models:"
    echo "  • gemini-2.0-flash-exp"
    echo "  • gemini-exp-1206"
    echo "  • gemini-2.0-flash-thinking-exp-1219"
    echo "  • gemini-1.5-flash"
    echo "  • gemini-1.5-flash-8b"
    echo "  • gemini-1.5-pro"
    echo ""
    echo "Documentation:"
    echo "  https://ai.google.dev/api"
    echo ""
}

# Function to display Vertex AI endpoint information
show_vertex_endpoints() {
    local specific_region="$1"
    
    echo "================================================="
    echo "☁️  Google Cloud Vertex AI Endpoints"
    echo "================================================="
    echo ""
    echo "Base Endpoint:"
    echo "  https://aiplatform.googleapis.com"
    echo ""
    echo "API Version:"
    echo "  • v1 - Current stable version"
    echo ""
    echo "Endpoint Format:"
    echo "  POST https://aiplatform.googleapis.com/v1/projects/{PROJECT_ID}/locations/{LOCATION}/publishers/{PUBLISHER}/models/{MODEL}:streamGenerateContent"
    echo ""
    echo "Authentication:"
    echo "  • OAuth 2.0 Bearer Token (gcloud auth print-access-token)"
    echo ""
    echo "Supported Publishers:"
    echo "  • anthropic - Claude models"
    echo "  • google    - Gemini models"
    echo "  • meta      - Llama models"
    echo "  • mistral   - Mistral models"
    echo "  • cohere    - Cohere models"
    echo ""
    
    if [[ -n "$specific_region" ]]; then
        # Show only specific region
        regions=("$specific_region")
    else
        # All available regions
        regions=(
            "global"
            "africa-south1"
            "asia-east1"
            "asia-east2"
            "asia-northeast1"
            "asia-northeast2"
            "asia-northeast3"
            "asia-south1"
            "asia-south2"
            "asia-southeast1"
            "asia-southeast2"
            "australia-southeast1"
            "australia-southeast2"
            "europe-central2"
            "europe-north1"
            "europe-southwest1"
            "europe-west1"
            "europe-west2"
            "europe-west3"
            "europe-west4"
            "europe-west6"
            "europe-west8"
            "europe-west9"
            "europe-west12"
            "me-central1"
            "me-central2"
            "me-west1"
            "northamerica-northeast1"
            "northamerica-northeast2"
            "southamerica-east1"
            "southamerica-west1"
            "us-central1"
            "us-east1"
            "us-east4"
            "us-east5"
            "us-south1"
            "us-west1"
            "us-west2"
            "us-west3"
            "us-west4"
        )
    fi
    
    echo "Checking deployed endpoints across regions..."
    echo ""
    
    # Loop through each region in the array.
    for region in "${regions[@]}"; do
        echo "================================================="
        echo "🔍 Region: $region"
        echo "================================================="
        
        # Execute the gcloud command for the current region.
        gcloud ai endpoints list --region="$region" 2>/dev/null
        
        if [[ $? -ne 0 ]]; then
            echo "  (No endpoints or unable to query this region)"
        fi
        echo ""
    done
    
    echo "✅ All regions have been checked."
    echo ""
    echo "Documentation:"
    echo "  https://cloud.google.com/vertex-ai/docs/reference/rest"
    echo ""
}

# Parse command line arguments
SHOW_AISTUDIO=true
SHOW_VERTEX=true
SPECIFIC_REGION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -a|--aistudio)
            SHOW_AISTUDIO=true
            SHOW_VERTEX=false
            shift
            ;;
        -v|--vertex)
            SHOW_AISTUDIO=false
            SHOW_VERTEX=true
            shift
            ;;
        -r|--region)
            SPECIFIC_REGION="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Display endpoints based on flags
if [[ "$SHOW_AISTUDIO" == true ]]; then
    show_aistudio_endpoints
fi

if [[ "$SHOW_VERTEX" == true ]]; then
    show_vertex_endpoints "$SPECIFIC_REGION"
fi
