#!/usr/bin/env python3
"""
Script to discover Vertex AI models available via the global endpoint.

The global endpoint provides:
- Direct API access without deployment
- Pay per request (no infrastructure costs)
- Higher availability than single regions

Usage:
    python vertex_on_demand.py           # Discover models
    python vertex_on_demand.py --test    # Test a model

Requirements:
    pip install requests
"""

import argparse
import json
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

# Check for requests module
try:
    import requests
except ImportError:
    print("Error: 'requests' module is required.")
    print()
    print("Install with: pip install requests")
    sys.exit(1)


# Publishers to check for LLM models
PUBLISHERS = ["google", "anthropic", "meta", "mistral-ai", "ai21"]

# Model name patterns that indicate LLM/chat models (for filtering)
LLM_PATTERNS = [
    r"gemini",
    r"claude",
    r"llama",
    r"mistral",
    r"mixtral",
    r"codestral",
    r"jamba",
]

# Continent to regions mapping (all regions per continent)
# Based on: https://cloud.google.com/vertex-ai/generative-ai/docs/learn/locations
CONTINENT_REGIONS = {
    "us": [
        "us-central1",
        "us-east1",
        "us-east4",
        "us-east5",
        "us-south1",
        "us-west1",
        "us-west4",
    ],
    "europe": [
        "europe-west1",
        "europe-west4",
        "europe-west9",
    ],
    "asia": [
        "asia-east1",
        "asia-east2",
        "asia-northeast1",
        "asia-northeast3",
        "asia-south1",
        "asia-southeast1",
    ],
}

CONTINENT_NAMES = {
    "us": "United States",
    "europe": "Europe",
    "asia": "Asia Pacific",
}


def get_access_token() -> str:
    """Get access token from gcloud."""
    try:
        result = subprocess.run(
            ["gcloud", "auth", "print-access-token"],
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"Error getting access token: {e}")
        print("Please run: gcloud auth application-default login")
        sys.exit(1)


def get_current_project() -> str | None:
    """Get the current gcloud project."""
    try:
        result = subprocess.run(
            ["gcloud", "config", "get-value", "project"],
            capture_output=True,
            text=True,
            check=True
        )
        project = result.stdout.strip()
        return project if project else None
    except subprocess.CalledProcessError:
        return None


def check_model_availability(project: str, publisher: str, model_id: str, access_token: str, region: str | None = None) -> dict[str, Any] | None:
    """
    Check if a model is available on an endpoint by attempting a minimal API call.
    
    Args:
        region: If provided, check regional endpoint; if None, check global
    """
    location = region if region else "global"
    base_url = f"https://{location}-aiplatform.googleapis.com" if region else "https://aiplatform.googleapis.com"
    
    # Build the URL - different publishers use different API formats
    if publisher == "anthropic":
        url = f"{base_url}/v1/projects/{project}/locations/{location}/publishers/{publisher}/models/{model_id}:rawPredict"
        payload = {
            "anthropic_version": "vertex-2023-10-16",
            "max_tokens": 1,
            "messages": [{"role": "user", "content": "hi"}]
        }
    elif publisher == "mistral-ai":
        url = f"{base_url}/v1/projects/{project}/locations/{location}/publishers/{publisher}/models/{model_id}:rawPredict"
        payload = {
            "model": model_id,
            "max_tokens": 1,
            "messages": [{"role": "user", "content": "hi"}]
        }
    else:
        url = f"{base_url}/v1/projects/{project}/locations/{location}/publishers/{publisher}/models/{model_id}:generateContent"
        payload = {
            "contents": [{"role": "user", "parts": [{"text": "hi"}]}],
            "generationConfig": {"maxOutputTokens": 1}
        }
    
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json"
    }
    
    try:
        response = requests.post(url, headers=headers, json=payload, timeout=15)
        
        if response.status_code == 200:
            return {
                "publisher": publisher,
                "model_id": model_id,
                "status": "available",
                "endpoint": region if region else "global",
                "requires_eula": publisher not in ["google"],
            }
        elif response.status_code == 403:
            error_text = response.text.lower()
            if "agreement" in error_text or "eula" in error_text or "terms" in error_text:
                return {
                    "publisher": publisher,
                    "model_id": model_id,
                    "status": "needs_eula",
                    "endpoint": region if region else "global",
                    "requires_eula": True,
                }
            else:
                return {
                    "publisher": publisher,
                    "model_id": model_id,
                    "status": "needs_permission",
                    "endpoint": region if region else "global",
                    "requires_eula": publisher not in ["google"],
                }
        elif response.status_code == 404:
            # Model not available on this endpoint
            return None
        else:
            # Other error
            return None
    except requests.exceptions.Timeout:
        return None
    except Exception:
        return None


def fetch_model_garden_models() -> list[tuple[str, str]]:
    """
    Dynamically fetch LLM models from Model Garden using gcloud.
    Returns list of (publisher, model_id) tuples.
    """
    try:
        result = subprocess.run(
            [
                "gcloud", "alpha", "ai", "model-garden", "models", "list",
                "--limit=1000",
                "--full-resource-name",
                "--format=value(name)"
            ],
            capture_output=True,
            text=True,
            timeout=60
        )
        
        if result.returncode != 0:
            print(f"Warning: gcloud command failed: {result.stderr}")
            return []
        
        models = []
        llm_regex = re.compile("|".join(LLM_PATTERNS), re.IGNORECASE)
        
        for line in result.stdout.strip().split("\n"):
            if not line:
                continue
            
            # Parse: publishers/PUBLISHER/models/MODEL_ID
            match = re.match(r"publishers/([^/]+)/models/(.+)", line)
            if not match:
                continue
            
            publisher, model_id = match.groups()
            
            # Only include models from target publishers
            if publisher not in PUBLISHERS:
                continue
            
            # Only include LLM-type models
            if not llm_regex.search(model_id):
                continue
            
            models.append((publisher, model_id))
        
        return models
        
    except subprocess.TimeoutExpired:
        print("Warning: gcloud command timed out")
        return []
    except FileNotFoundError:
        print("Warning: gcloud not found")
        return []


def get_model_patterns(use_dynamic: bool = True) -> list[tuple[str, str]]:
    """
    Return model patterns to scan on the global endpoint.
    
    If use_dynamic is True, fetches from Model Garden API.
    Falls back to static list if API fails.
    """
    if use_dynamic:
        models = fetch_model_garden_models()
        if models:
            # Add common version variations that might work on global endpoint
            expanded = set(models)
            for publisher, model_id in models:
                # Add the base model without version suffix
                base_model = re.sub(r"@.*$", "", model_id)
                if base_model != model_id:
                    expanded.add((publisher, base_model))
                # For Claude models, also try with common version suffixes
                if publisher == "anthropic":
                    expanded.add((publisher, model_id))
            
            # Add specific Mistral model IDs (API returns generic names, not versions)
            mistral_specific_models = [
                "mistral-medium-3",
                "mistral-small-2503",
                "mistral-ocr",
                "mistral-large-2407",
                "codestral-2",
                "codestral-2405",
            ]
            for model_id in mistral_specific_models:
                expanded.add(("mistral-ai", model_id))
            
            return list(expanded)
    
    # Fallback to static list
    patterns = []
    
    # Google Gemini models (static fallback)
    google_models = [
        "gemini-3-pro-preview",
        "gemini-3-flash-preview",
        "gemini-2.5-pro",
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite",
        "gemini-2.0-flash",
        "gemini-2.0-flash-001",
        "gemini-2.0-flash-lite",
    ]
    patterns.extend([("google", m) for m in google_models])
    
    # Anthropic Claude models (static fallback)
    anthropic_models = [
        "claude-opus-4-5",
        "claude-sonnet-4-5",
        "claude-haiku-4-5",
        "claude-opus-4",
        "claude-sonnet-4",
        "claude-3-7-sonnet",
        "claude-3-5-sonnet",
        "claude-3-5-haiku",
        "claude-3-haiku",
    ]
    patterns.extend([("anthropic", m) for m in anthropic_models])
    
    # Meta Llama models (static fallback)
    meta_models = [
        "llama-4-maverick-17b-128e-instruct-maas",
        "llama-3.3-70b-instruct-maas",
        "llama-3.2-90b-vision-instruct-maas",
        "llama-3.1-405b-instruct-maas",
    ]
    patterns.extend([("meta", m) for m in meta_models])
    
    # Mistral models (static fallback)
    mistral_models = [
        "mistral-medium-3",
        "mistral-small-2503",
        "mistral-ocr",
        "mistral-large-2407",
        "codestral-2",
        "codestral-2405",
    ]
    patterns.extend([("mistral-ai", m) for m in mistral_models])
    
    # AI21 models (static fallback)
    ai21_models = [
        "jamba-large-1.6",
    ]
    patterns.extend([("ai21", m) for m in ai21_models])
    
    return patterns


def check_model_in_regions(
    project: str,
    publisher: str,
    model_id: str,
    access_token: str,
    regions: list[str]
) -> dict[str, Any] | None:
    """
    Check which regions a model is available in.
    Returns model info with list of available regions.
    """
    available_regions = []
    needs_eula_regions = []
    needs_perm_regions = []
    
    for region in regions:
        result = check_model_availability(project, publisher, model_id, access_token, region)
        if result:
            if result["status"] == "available":
                available_regions.append(region)
            elif result["status"] == "needs_eula":
                needs_eula_regions.append(region)
            elif result["status"] == "needs_permission":
                needs_perm_regions.append(region)
    
    # Return result if found in any region
    if available_regions or needs_eula_regions or needs_perm_regions:
        # Priority: available > needs_eula > needs_permission
        if available_regions:
            status = "available"
            regions_list = available_regions
        elif needs_eula_regions:
            status = "needs_eula"
            regions_list = needs_eula_regions
        else:
            status = "needs_permission"
            regions_list = needs_perm_regions
        
        return {
            "publisher": publisher,
            "model_id": model_id,
            "status": status,
            "regions": regions_list,
            "requires_eula": publisher not in ["google"],
        }
    
    return None


def discover_models(project: str, use_static: bool = False, continent: str | None = None) -> list[dict[str, Any]]:
    """
    Discover all models available on the specified endpoint.
    
    Args:
        continent: If provided (us/europe/asia), check all regions in that continent; if None, check global
    """
    access_token = get_access_token()
    
    regions = CONTINENT_REGIONS.get(continent) if continent else None
    
    if continent:
        continent_name = CONTINENT_NAMES.get(continent, continent)
        endpoint_name = f"{continent_name}"
        emoji = "üìç"
    else:
        endpoint_name = "Global"
        emoji = "üåç"
    
    print("=" * 120)
    print(f"{emoji} Discovering Vertex AI Models on {endpoint_name} Endpoint")
    print("=" * 120)
    print()
    print(f"Project: {project}")
    if regions:
        print(f"Scanning regions: {', '.join(regions)}")
    else:
        print(f"Endpoint: https://aiplatform.googleapis.com")
    print()
    
    use_dynamic = not use_static
    if use_dynamic:
        print("Fetching models from Model Garden API...")
    
    patterns = get_model_patterns(use_dynamic=use_dynamic)
    
    if not patterns:
        print("Warning: No models found from API, using static fallback list")
        patterns = get_model_patterns(use_dynamic=False)
    
    if regions:
        print(f"Scanning {len(patterns)} models across {len(regions)} regions...")
    else:
        print(f"Scanning {len(patterns)} models...")
    print()
    
    all_models = []
    
    if regions:
        # Regional scanning: check each model across all regions
        with ThreadPoolExecutor(max_workers=10) as executor:
            futures = {
                executor.submit(
                    check_model_in_regions,
                    project, publisher, model_id, access_token, regions
                ): (publisher, model_id)
                for publisher, model_id in patterns
            }
            
            completed = 0
            for future in as_completed(futures):
                completed += 1
                publisher, model_id = futures[future]
                print(f"  [{completed}/{len(patterns)}] {publisher}/{model_id}...", end="\r")
                
                result = future.result()
                if result:
                    all_models.append(result)
    else:
        # Global endpoint scanning
        with ThreadPoolExecutor(max_workers=20) as executor:
            futures = {
                executor.submit(
                    check_model_availability,
                    project, publisher, model_id, access_token, None
                ): (publisher, model_id)
                for publisher, model_id in patterns
            }
            
            completed = 0
            for future in as_completed(futures):
                completed += 1
                publisher, model_id = futures[future]
                print(f"  [{completed}/{len(patterns)}] {publisher}/{model_id}...", end="\r")
                
                result = future.result()
                if result:
                    all_models.append(result)
    
    print(" " * 80)
    
    print(f"Found {len(all_models)} models")
    print()
    
    # Sort by publisher, then model_id
    all_models.sort(key=lambda x: (x["publisher"], x["model_id"]))
    
    # Display results - different format for regional vs global
    if regions:
        # Regional display with endpoints column
        region_header = f"Endpoints in {endpoint_name}"
        print("-" * 120)
        print(f"{'Publisher':<12} {'Model ID':<45} {'Status':<15} {region_header:<40}")
        print("-" * 120)
        
        current_publisher = None
        for model in all_models:
            publisher = model["publisher"]
            
            if publisher != current_publisher:
                if current_publisher is not None:
                    print()
                current_publisher = publisher
            
            model_id = model["model_id"]
            status = model.get("status", "")
            model_regions = model.get("regions", [])
            
            # Format status
            if status == "available":
                status_str = "‚úÖ Available"
            elif status == "needs_eula":
                status_str = "üìù Needs EULA"
            elif status == "needs_permission":
                status_str = "üîê Needs Perm"
            else:
                status_str = f"‚ùì {status}"
            
            # Format regions - show all or truncate
            if len(model_regions) <= 3:
                regions_str = ", ".join(model_regions)
            else:
                regions_str = f"{model_regions[0]}, {model_regions[1]}... (+{len(model_regions)-2} more)"
            
            print(f"{publisher:<12} {model_id:<45} {status_str:<15} {regions_str:<40}")
        
        print("-" * 120)
    else:
        # Global display
        print("-" * 105)
        print(f"{'Publisher':<12} {'Model ID':<55} {'Status':<18} {'EULA':<6}")
        print("-" * 105)
        
        current_publisher = None
        for model in all_models:
            publisher = model["publisher"]
            
            if publisher != current_publisher:
                if current_publisher is not None:
                    print()
                current_publisher = publisher
            
            model_id = model["model_id"]
            status = model.get("status", "")
            requires_eula = model.get("requires_eula", False)
            
            # Format status
            if status == "available":
                status_str = "‚úÖ Available"
            elif status == "needs_eula":
                status_str = "üìù Needs EULA"
            elif status == "needs_permission":
                status_str = "üîê Needs Perm"
            else:
                status_str = f"‚ùì {status}"
            
            eula_str = "üìù" if requires_eula else "‚Äî"
            
            print(f"{publisher:<12} {model_id:<55} {status_str:<18} {eula_str:<6}")
        
        print("-" * 105)
    
    print()
    
    # Summary
    publisher_counts = {}
    for model in all_models:
        pub = model["publisher"]
        status = model["status"]
        if pub not in publisher_counts:
            publisher_counts[pub] = {"available": 0, "needs_action": 0}
        if status == "available":
            publisher_counts[pub]["available"] += 1
        else:
            publisher_counts[pub]["needs_action"] += 1
    
    print("Summary by Publisher:")
    for pub in sorted(publisher_counts.keys()):
        counts = publisher_counts[pub]
        parts = []
        if counts["available"]:
            parts.append(f"{counts['available']} available")
        if counts["needs_action"]:
            parts.append(f"{counts['needs_action']} need action")
        print(f"  {pub}: {', '.join(parts)}")
    
    print()
    print(f"Total models: {len(all_models)}")
    print()
    print("Legend:")
    print("  ‚úÖ Available      = Ready to use")
    print("  üìù Needs EULA     = Must accept End User License Agreement")
    print("  üîê Needs Perm     = Missing permissions or API not enabled")
    print()
    print("To accept EULA for a model, run:")
    print(f"  gcloud alpha ai models describe publishers/PUBLISHER/models/MODEL_ID \\")
    print(f"    --project {project} --region us-central1")
    print()
    print("Note: Partner models (Mistral, Meta, AI21) may not appear until you accept their")
    print("terms in Model Garden: https://console.cloud.google.com/vertex-ai/model-garden")
    print()
    
    return all_models


def test_model(publisher: str, model_id: str, project: str | None = None):
    """
    Test if a model works via the global endpoint.
    """
    if not project:
        project = get_current_project()
        if not project:
            print("Error: Project ID required.")
            print("Set with: gcloud config set project YOUR_PROJECT_ID")
            sys.exit(1)
    
    access_token = get_access_token()
    
    print(f"Testing model: {publisher}/{model_id}")
    print(f"Project: {project}")
    print("-" * 50)
    
    # Build URL for global endpoint
    if publisher == "anthropic":
        url = f"https://aiplatform.googleapis.com/v1/projects/{project}/locations/global/publishers/{publisher}/models/{model_id}:rawPredict"
        payload = {
            "anthropic_version": "vertex-2023-10-16",
            "max_tokens": 100,
            "messages": [{"role": "user", "content": "Say hello in one word!"}]
        }
    elif publisher == "mistral-ai":
        url = f"https://aiplatform.googleapis.com/v1/projects/{project}/locations/global/publishers/{publisher}/models/{model_id}:rawPredict"
        payload = {
            "model": model_id,
            "max_tokens": 100,
            "messages": [{"role": "user", "content": "Say hello in one word!"}]
        }
    else:
        url = f"https://aiplatform.googleapis.com/v1/projects/{project}/locations/global/publishers/{publisher}/models/{model_id}:generateContent"
        payload = {
            "contents": [{"role": "user", "parts": [{"text": "Say hello in one word!"}]}]
        }
    
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json"
    }
    
    try:
        response = requests.post(url, headers=headers, json=payload, timeout=30)
        
        if response.status_code == 200:
            print(f"‚úÖ Model works on global endpoint!")
            print()
            data = response.json()
            if "candidates" in data:
                text = data["candidates"][0]["content"]["parts"][0]["text"]
                print(f"Response: {text}")
            elif "content" in data:
                if isinstance(data["content"], list):
                    text = data["content"][0].get("text", str(data["content"]))
                else:
                    text = str(data["content"])
                print(f"Response: {text}")
        else:
            print(f"‚ùå Model returned status {response.status_code}")
            try:
                error_data = response.json()
                error_msg = error_data.get("error", {}).get("message", "Unknown error")
                print(f"Error: {error_msg[:400]}")
                
                if "agreement" in error_msg.lower() or "eula" in error_msg.lower():
                    print()
                    print("üí° Accept EULA with:")
                    print(f"   gcloud alpha ai models describe publishers/{publisher}/models/{model_id} \\")
                    print(f"     --project {project} --region us-central1")
            except Exception:
                print(f"Response: {response.text[:400]}")
    except Exception as e:
        print(f"‚ùå Error: {e}")


def main():
    parser = argparse.ArgumentParser(
        description="Discover Vertex AI models on the global endpoint",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    python vertex_on_demand.py                              # Discover models on global endpoint
    python vertex_on_demand.py --continent us               # Check United States regional endpoint
    python vertex_on_demand.py --continent europe           # Check Europe regional endpoint
    python vertex_on_demand.py --continent asia             # Check Asia Pacific regional endpoint
    python vertex_on_demand.py --json                       # JSON output
    python vertex_on_demand.py --test google/gemini-2.0-flash

Global Endpoint Benefits:
    - No private endpoint deployment needed
    - Pay per request only (no infrastructure costs)
    - Higher availability (routes to nearest region)

Documentation:
    https://cloud.google.com/vertex-ai/generative-ai/docs/learn/locations
        """
    )
    
    parser.add_argument("--test", "-t", type=str, metavar="PUBLISHER/MODEL",
                        help="Test a model (e.g., google/gemini-2.0-flash)")
    parser.add_argument("--json", "-j", action="store_true", help="JSON output")
    parser.add_argument("--static", "-s", action="store_true",
                        help="Use static model list instead of fetching from Model Garden API")
    parser.add_argument("--continent", "-c", type=str, choices=["us", "europe", "asia"],
                        metavar="CONTINENT",
                        help="Check regional endpoint instead of global (us=United States, europe=Europe, asia=Asia Pacific)")
    
    args = parser.parse_args()
    
    project = get_current_project()
    if not project:
        print("Error: Project ID required.")
        print("Set with: gcloud config set project YOUR_PROJECT_ID")
        sys.exit(1)
    
    if args.test:
        if "/" not in args.test:
            print("Error: Format must be publisher/model-id")
            sys.exit(1)
        publisher, model_id = args.test.split("/", 1)
        test_model(publisher, model_id, project)
        return
    
    models = discover_models(project, args.static, args.continent)
    
    if args.json:
        print(json.dumps(models, indent=2))


if __name__ == "__main__":
    main()
