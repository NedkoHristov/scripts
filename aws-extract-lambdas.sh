#!/bin/bash
# =============================================================================
# Extract Lambda Functions from AWS Account
# =============================================================================
# Usage:
#   ./scripts/extract-lambdas.sh [output-dir] [filter-prefix]
#
# Example:
#   ./scripts/extract-lambdas.sh extracted-lambdas XXX
#   ./scripts/extract-lambdas.sh extracted-lambdas ""  # all lambdas
#
# This script will:
#   1. List all Lambda functions in the account
#   2. Download the deployment package for each
#   3. Extract and organize the code
#
# Uses default AWS credentials (set via aws configure, env vars, or assume-role)
# =============================================================================

set -euo pipefail

# Configuration
AWS_REGION="${AWS_REGION:-eu-central-1}"
OUTPUT_DIR="${1:-extracted-lambdas}"
FILTER_PREFIX="${2:-XXX}"  # Only extract lambdas matching this prefix

echo "=============================================="
echo "Lambda Function Extractor"
echo "=============================================="
echo "AWS Region:  $AWS_REGION"
echo "Output Dir:  $OUTPUT_DIR"
if [ -n "$FILTER_PREFIX" ]; then
    echo "Filter:      $FILTER_PREFIX*"
else
    echo "Filter:      (all lambdas)"
fi
echo "=============================================="
echo ""

# Verify AWS credentials
echo "🔐 Checking AWS credentials..."
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "   Account: $ACCOUNT_ID"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Get list of Lambda functions
echo "📋 Fetching Lambda functions..."
if [ -n "$FILTER_PREFIX" ]; then
    FUNCTIONS=$(aws lambda list-functions \
        --region "$AWS_REGION" \
        --query "Functions[?starts_with(FunctionName, \`$FILTER_PREFIX\`)].FunctionName" \
        --output text)
else
    FUNCTIONS=$(aws lambda list-functions \
        --region "$AWS_REGION" \
        --query "Functions[*].FunctionName" \
        --output text)
fi

if [ -z "$FUNCTIONS" ]; then
    echo "❌ No Lambda functions found matching prefix: $FILTER_PREFIX"
    exit 1
fi

# Count functions
FUNC_COUNT=$(echo "$FUNCTIONS" | wc -w)
echo "✅ Found $FUNC_COUNT Lambda functions"
echo ""

# Process each function
for FUNC_NAME in $FUNCTIONS; do
    echo "----------------------------------------"
    echo "📦 Processing: $FUNC_NAME"
    
    # Create directory for this function (sanitize name)
    SAFE_NAME=$(echo "$FUNC_NAME" | sed 's/[^a-zA-Z0-9_-]/_/g')
    FUNC_DIR="$OUTPUT_DIR/$SAFE_NAME"
    mkdir -p "$FUNC_DIR"
    
    # Get function details
    echo "   Fetching function details..."
    FUNC_INFO=$(aws lambda get-function \
        --region "$AWS_REGION" \
        --function-name "$FUNC_NAME" \
        --output json)
    
    # Save function configuration
    echo "$FUNC_INFO" | jq '.Configuration' > "$FUNC_DIR/config.json"
    
    # Extract key info
    RUNTIME=$(echo "$FUNC_INFO" | jq -r '.Configuration.Runtime')
    HANDLER=$(echo "$FUNC_INFO" | jq -r '.Configuration.Handler')
    MEMORY=$(echo "$FUNC_INFO" | jq -r '.Configuration.MemorySize')
    TIMEOUT=$(echo "$FUNC_INFO" | jq -r '.Configuration.Timeout')
    ARCH=$(echo "$FUNC_INFO" | jq -r '.Configuration.Architectures[0] // "x86_64"')
    
    echo "   Runtime: $RUNTIME | Handler: $HANDLER | Memory: ${MEMORY}MB | Timeout: ${TIMEOUT}s | Arch: $ARCH"
    
    # Get download URL
    DOWNLOAD_URL=$(echo "$FUNC_INFO" | jq -r '.Code.Location')
    
    if [ "$DOWNLOAD_URL" != "null" ] && [ -n "$DOWNLOAD_URL" ]; then
        # Download the deployment package
        echo "   Downloading code..."
        curl -sL "$DOWNLOAD_URL" -o "$FUNC_DIR/code.zip"
        
        # Extract the code
        echo "   Extracting..."
        unzip -qo "$FUNC_DIR/code.zip" -d "$FUNC_DIR/src"
        rm "$FUNC_DIR/code.zip"
        
        # Count files
        FILE_COUNT=$(find "$FUNC_DIR/src" -type f | wc -l)
        echo "   ✅ Extracted $FILE_COUNT files"
    else
        echo "   ⚠️  No code location (might be container image or inline)"
    fi
    
    # Save environment variables (redacted)
    ENV_VARS=$(echo "$FUNC_INFO" | jq '.Configuration.Environment.Variables // {}')
    if [ "$ENV_VARS" != "{}" ]; then
        echo "$ENV_VARS" | jq 'to_entries | map({key: .key, value: "***REDACTED***"}) | from_entries' > "$FUNC_DIR/env_vars_template.json"
        echo "   📝 Environment variables template saved (values redacted)"
    fi
    
    echo ""
done

echo "=============================================="
echo "✅ Extraction complete!"
echo "=============================================="
echo ""
echo "Output structure:"
tree -L 2 "$OUTPUT_DIR" 2>/dev/null || find "$OUTPUT_DIR" -maxdepth 2 -type d
echo ""
