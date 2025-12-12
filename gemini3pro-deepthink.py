#!/usr/bin/env python3
"""
==============================================================================
 GEMINI 3.0: DEEP THINKING + GOOGLE SEARCH GROUNDING (Python Client)
==============================================================================
Description:
  Interacts with the Gemini 3.0 API.
  Automatically manages the "Thinking Budget vs Thinking Level" conflict.
  Uses standard libraries only (no pip install required).
"""

import sys
import json
import os
import argparse
import time
import urllib.request
import urllib.error

# --- Configuration Defaults ---
DEFAULT_MODEL = "gemini-3-pro-preview"
DEFAULT_TOKENS = 65536

# --- ANSI Colors for Terminal Output ---
class Colors:
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    BOLD = '\033[1m'
    ENDC = '\033[0m'

def print_header(msg):
    print(f"{Colors.HEADER}{Colors.BOLD}{msg}{Colors.ENDC}")

def print_error(msg):
    print(f"{Colors.RED}{Colors.BOLD}Error:{Colors.ENDC} {msg}", file=sys.stderr)

def get_api_key(arg_key):
    # Check argument first, then environment variable
    key = arg_key or os.environ.get("GEMINI_API_KEY")
    if not key or key == "1234":
        print_error("No valid API Key found.")
        print("Please set the GEMINI_API_KEY environment variable or use --api-key.")
        sys.exit(1)
    return key

def main():
    parser = argparse.ArgumentParser(
        description="Gemini 3.0 Deep Thinking Client",
        epilog="Example:\n  python3 gemini_deepthink.py -p 'Prove the Riemann Hypothesis' -b 4000"
    )
    
    # Input
    parser.add_argument("-p", "--prompt", help="The prompt to send.")
    parser.add_argument("-s", "--stdin", action="store_true", help="Read prompt from stdin.")
    
    # Model & Auth
    parser.add_argument("--model", default=DEFAULT_MODEL, help=f"Model ID (Default: {DEFAULT_MODEL})")
    parser.add_argument("--api-key", help="API Key (overrides env var).")
    parser.add_argument("-m", "--max-tokens", type=int, default=DEFAULT_TOKENS, help="Max output tokens.")

    # Thinking Config
    parser.add_argument("-t", "--thinking-level", choices=["low", "medium", "high"], default="high",
                        help="Thinking Level (Ignored if budget > 0).")
    parser.add_argument("-b", "--thinking-budget", type=int, default=0,
                        help="Token budget for thinking. If > 0, overrides thinking-level.")
    parser.add_argument("--no-thoughts", action="store_true", help="Hide the raw thinking process.")
    
    # Tools
    parser.add_argument("--no-search", action="store_true", help="Disable Google Search grounding.")
    
    # Debug
    parser.add_argument("-v", "--verbose", action="store_true", help="Print raw JSON payload.")
    parser.add_argument("-r", "--raw", action="store_true", help="Print raw JSON response.")

    args = parser.parse_args()

    # 1. Get Prompt
    prompt_text = args.prompt
    if args.stdin:
        if not sys.stdin.isatty():
            prompt_text = sys.stdin.read().strip()
    
    if not prompt_text:
        print_error("No prompt provided. Use -p or --stdin.")
        sys.exit(1)

    api_key = get_api_key(args.api_key)

    # 2. Construct Payload (Handling Mutual Exclusivity)
    thinking_config = {
        "includeThoughts": not args.no_thoughts
    }

    # CRITICAL LOGIC: Send EITHER budget OR level
    # The API will return a 400 error if both fields are present.
    if args.thinking_budget > 0:
        thinking_config["thinkingBudget"] = args.thinking_budget
        think_status = f"Budget={args.thinking_budget} tokens (Overrides Level)"
    else:
        thinking_config["thinkingLevel"] = args.thinking_level
        think_status = f"Level={args.thinking_level}"

    payload = {
        "contents": [{"parts": [{"text": prompt_text}]}],
        "generationConfig": {
            "maxOutputTokens": args.max_tokens,
            "thinkingConfig": thinking_config
        }
    }

    # Add Tools
    grounding_status = f"{Colors.RED}DISABLED{Colors.ENDC}"
    if not args.no_search:
        payload["tools"] = [{"googleSearch": {}}]
        grounding_status = f"{Colors.GREEN}ENABLED (Google Search){Colors.ENDC}"

    # 3. Display Info
    if not args.raw:
        print("-" * 60)
        print(f"{Colors.BOLD}Model:{Colors.ENDC} {args.model}")
        print(f"{Colors.BOLD}Thinking:{Colors.ENDC} {think_status}")
        print(f"{Colors.BOLD}Grounding:{Colors.ENDC} {grounding_status}")
        print(f"{Colors.BOLD}Prompt:{Colors.ENDC} \"{prompt_text[:60]}{'...' if len(prompt_text)>60 else ''}\"")
        print("-" * 60)
        print("Sending query... (Deep Thinking + Search takes time)")

    if args.verbose:
        print(f"{Colors.YELLOW}[DEBUG] Payload:{Colors.ENDC}\n{json.dumps(payload, indent=2)}")

    # 4. Send Request (Standard Library)
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{args.model}:generateContent?key={api_key}"
    headers = {"Content-Type": "application/json"}
    data = json.dumps(payload).encode("utf-8")

    start_time = time.time()
    try:
        req = urllib.request.Request(url, data=data, headers=headers, method="POST")
        with urllib.request.urlopen(req) as response:
            result_body = response.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        print_error(f"HTTP {e.code}: {e.reason}")
        try:
            err = json.loads(e.read().decode("utf-8"))
            print(f"{Colors.RED}{json.dumps(err, indent=2)}{Colors.ENDC}")
        except: pass
        sys.exit(1)
    except Exception as e:
        print_error(f"Request failed: {e}")
        sys.exit(1)
        
    duration = time.time() - start_time

    # 5. Output Handling
    if args.raw:
        print(result_body)
        sys.exit(0)

    try:
        response_json = json.loads(result_body)
        if "candidates" not in response_json or not response_json["candidates"]:
            print(f"{Colors.YELLOW}No candidates returned.{Colors.ENDC}")
            sys.exit(0)

        candidate = response_json["candidates"][0]
        parts = candidate.get("content", {}).get("parts", [])
        grounding = candidate.get("groundingMetadata", {})

        # A. Thoughts
        if not args.no_thoughts:
            print_header("\n--- üß† DEEP THINKING PROCESS ---")
            has_thoughts = False
            for part in parts:
                if part.get("thought", False):
                    print(f"{Colors.CYAN}{part.get('text', '').strip()}{Colors.ENDC}")
                    has_thoughts = True
            if not has_thoughts:
                print("(No distinct thought blocks returned)")

        # B. Sources
        if grounding and "groundingChunks" in grounding:
            print_header("\n--- üåç SEARCH SOURCES ---")
            for i, chunk in enumerate(grounding.get("groundingChunks", [])):
                web = chunk.get("web", {})
                print(f"[{i+1}] {web.get('title', 'Source')} ({web.get('uri', '#')})")

        # C. Answer
        print_header("\n--- üìù FINAL ANSWER ---")
        for part in parts:
            if not part.get("thought", False) and "text" in part:
                print(part["text"].strip())

        print(f"\n{Colors.BOLD}Query completed in: {duration:.2f} seconds{Colors.ENDC}")

    except Exception as e:
        print_error(f"Failed to parse response: {e}")

if __name__ == "__main__":
    main()
