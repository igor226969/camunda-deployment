#!/bin/bash
# zeebe-deploy-cicd.sh
# This script deploys BPMN, DMN, and Form files to a Zeebe cluster in a CI/CD environment

set -e  # Exit immediately if a command exits with a non-zero status

# Default settings
ZEEBE_AUTHORIZATION_SERVER_URL="https://login.cloud.camunda.io/oauth/token"
ZEEBE_TOKEN_AUDIENCE="zeebe.camunda.io"

# Environment variables expected from GitHub Actions
# ZEEBE_CLIENT_ID - Set from GitHub secrets based on environment
# ZEEBE_CLIENT_SECRET - Set from GitHub secrets based on environment
# REGION_ID - Set from GitHub secrets based on environment
# CLUSTER_ID - Set from GitHub secrets based on environment

# Deployment configuration
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-deploy-$(date +%Y%m%d-%H%M%S)}"
SOURCE_DIR="${SOURCE_DIR:-.}"
GITHUB_ENV="${GITHUB_ENV:-/dev/null}"  # GitHub Actions env file or fallback
ENVIRONMENT="${ENVIRONMENT:-local}"     # GitHub environment or default

# Hard-coded file extensions to deploy
FILE_PATTERN="*.bpmn *.dmn *.form"

# Token storage
TOKEN=""

# Log function for better output in GitHub Actions
log() {
  local level="$1"
  local message="$2"
  if [ "$level" = "notice" ] || [ "$level" = "warning" ] || [ "$level" = "error" ]; then
    echo "::$level::$message"
  fi
  echo "$message"
}

log_group_start() {
  echo "::group::$1"
  echo "🔹 $1"
}

log_group_end() {
  echo "::endgroup::"
}

# Validate required parameters from environment
validate_env() {
  local missing=false

  if [ -z "$ZEEBE_CLIENT_ID" ]; then
    log "error" "Missing ZEEBE_CLIENT_ID environment variable"
    missing=true
  fi

  if [ -z "$ZEEBE_CLIENT_SECRET" ]; then
    log "error" "Missing ZEEBE_CLIENT_SECRET environment variable"
    missing=true
  fi

  if [ -z "$REGION_ID" ]; then
    log "error" "Missing REGION_ID environment variable"
    missing=true
  fi

  if [ -z "$CLUSTER_ID" ]; then
    log "error" "Missing CLUSTER_ID environment variable"
    missing=true
  fi

  if [ "$missing" = true ]; then
    log "error" "Required environment variables are missing, cannot proceed."
    exit 1
  fi
}

# Function to get OAuth token
get_oauth_token() {
  log_group_start "Requesting OAuth token..."
  
  # Make the request to get the OAuth token
  RESPONSE=$(curl -s --request POST ${ZEEBE_AUTHORIZATION_SERVER_URL} \
      --header 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode 'grant_type=client_credentials' \
      --data-urlencode "audience=${ZEEBE_TOKEN_AUDIENCE}" \
      --data-urlencode "client_id=${ZEEBE_CLIENT_ID}" \
      --data-urlencode "client_secret=${ZEEBE_CLIENT_SECRET}")

  # Check if we got a valid JSON response
  if echo "$RESPONSE" | jq empty 2>/dev/null; then
    # It's valid JSON, try to extract the token
    TOKEN=$(echo "$RESPONSE" | jq -r '.access_token')
    
    # Check if the token was obtained successfully
    if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
      log "error" "Failed to get OAuth token!"
      log "error" "Response: $(echo "$RESPONSE" | jq '.')"
      log_group_end
      return 1
    else
      log "notice" "OAuth token obtained successfully!"
      echo "  Token type: $(echo "$RESPONSE" | jq -r '.token_type')"
      echo "  Expires in: $(echo "$RESPONSE" | jq -r '.expires_in') seconds"
      log_group_end
      return 0
    fi
  else
    # Not valid JSON
    log "error" "Failed to get OAuth token! Invalid response format."
    log "error" "Response: $RESPONSE"
    log_group_end
    return 1
  fi
}

# Function to find files to deploy
find_deployment_files() {
  log_group_start "Looking for BPMN, DMN, and Form files in directory: $SOURCE_DIR"
  
  # Create a temporary file to store the list of files
  files_list=$(mktemp)
  
  # Split FILE_PATTERN into array
  IFS=' ' read -r -a patterns <<< "$FILE_PATTERN"
  
  # Find files matching each pattern
  for pattern in "${patterns[@]}"; do
    # Use find with -name for each pattern and append to files_list
    find "$SOURCE_DIR" -maxdepth 1 -type f -name "$pattern" >> "$files_list" 2>/dev/null
  done
  
  # Count files found
  files_found=$(wc -l < "$files_list")
  
  if [ "$files_found" -eq 0 ]; then
    log "error" "No BPMN, DMN, or Form files found in $SOURCE_DIR"
    rm "$files_list"
    log_group_end
    return 1
  else
    log "notice" "Found $files_found files to deploy:"
    # List files that will be deployed
    while IFS= read -r file; do
      echo "  - $(basename "$file")"
    done < "$files_list"
    log_group_end
    return 0
  fi
}

# Function to deploy files
deploy_files() {
  log_group_start "Deploying files to Zeebe cluster ($ENVIRONMENT environment)"
  
  # Construct deploy URL
  ZEEBE_DEPLOY_URL="https://${REGION_ID}.zeebe.camunda.io:443/${CLUSTER_ID}/v2/deployments"
  echo "🔹 Using deploy URL: $ZEEBE_DEPLOY_URL"
  
  # Prepare curl command
  curl_cmd="curl -sv -X POST \"$ZEEBE_DEPLOY_URL\" -H \"Authorization: Bearer $TOKEN\" -H \"Accept: application/json\" -F \"deployment-name=$DEPLOYMENT_NAME\""
  
  # Add each file as a resource
  file_count=0
  while IFS= read -r file; do
    # Get just the filename without path
    filename=$(basename "$file")
    curl_cmd="$curl_cmd -F \"resources=@$file;filename=$filename\""
    file_count=$((file_count + 1))
  done < "$files_list"
  
  # Execute the curl command and capture response
  echo "🔹 Sending deployment request with $file_count files..."
  # Save both stdout and stderr from curl
  RESPONSE=$(eval "$curl_cmd" 2>&1)
  
  # Extract just the JSON response (after the headers in stderr)
  JSON_RESPONSE=$(echo "$RESPONSE" | sed -n '/^{/,$p')
  
  # Save full response to a file for debugging
  echo "$RESPONSE" > "deployment-full-response.txt"
  
  # Save JSON response to a file for debugging in GitHub Actions
  echo "$JSON_RESPONSE" > "deployment-response.json"

  # Display response headers for debugging
  echo "🔹 Curl response headers (for debugging):"
  echo "$RESPONSE" | grep -v "^{" | sed 's/^/  /'
  
  # Check if deployment was successful
  if echo "$JSON_RESPONSE" | jq empty 2>/dev/null; then
    # Valid JSON response
    if echo "$JSON_RESPONSE" | jq -e '.' > /dev/null 2>&1; then
      # Print the full response structure for debugging
      echo "🔹 Full response structure:"
      echo "$JSON_RESPONSE" | jq '.'
      
      # Check specifically for the exact structure provided
      echo "🔹 Analyzing deployment resources:"
      
      # Each resource type is counted separately
      local process_count=0
      local decision_count=0
      local drd_count=0
      local form_count=0
      
      # Count processDefinition entries
      if echo "$JSON_RESPONSE" | jq -e '.deployments[] | select(.processDefinition)' > /dev/null 2>&1; then
        process_count=$(echo "$JSON_RESPONSE" | jq '[.deployments[] | select(.processDefinition)] | length')
        echo "  Found $process_count process definitions"
        
        # List all processes
        if [ "$process_count" -gt 0 ]; then
          echo "  Process details:"
          echo "$JSON_RESPONSE" | jq -r '.deployments[] | select(.processDefinition) | 
            "    - " + .processDefinition.processDefinitionId + 
            " (v" + (.processDefinition.processDefinitionVersion|tostring) + ") from " + 
            .processDefinition.resourceName'
        fi
      fi
      
      # Process decision resources hierarchically
      # First collect all decision requirements (DRDs)
      local drd_list=()
      local drd_count=0
      if echo "$JSON_RESPONSE" | jq -e '.deployments[] | select(.decisionRequirements)' > /dev/null 2>&1; then
        # Get list of DRDs with their keys
        readarray -t drd_list < <(echo "$JSON_RESPONSE" | jq -c '.deployments[] | select(.decisionRequirements) | .decisionRequirements')
        drd_count=${#drd_list[@]}
      fi
      
      # Count decision definition entries (we'll display them with their parent DRDs)
      local decision_count=0
      if echo "$JSON_RESPONSE" | jq -e '.deployments[] | select(.decisionDefinition)' > /dev/null 2>&1; then
        decision_count=$(echo "$JSON_RESPONSE" | jq '[.deployments[] | select(.decisionDefinition)] | length')
      fi
      
      # Display DMN resources hierarchically
      if [ "$drd_count" -gt 0 ]; then
        echo "  Found $drd_count Decision Requirements Diagram(s) with $decision_count Decision Definition(s)"
        echo "  DMN Details:"
        
        # Process each DRD
        for drd_json in "${drd_list[@]}"; do
          # Extract DRD details
          local drd_id=$(echo "$drd_json" | jq -r '.decisionRequirementsId')
          local drd_key=$(echo "$drd_json" | jq -r '.decisionRequirementsKey')
          local drd_version=$(echo "$drd_json" | jq -r '.version')
          local drd_name=$(echo "$drd_json" | jq -r '.decisionRequirementsName')
          local drd_resource=$(echo "$drd_json" | jq -r '.resourceName')
          
          # Display DRD info
          echo "    📋 $drd_name (DRD ID: $drd_id, v$drd_version) from $drd_resource"
          
          # Find all decision definitions that belong to this DRD
          local decisions=$(echo "$JSON_RESPONSE" | jq -c --arg drd_key "$drd_key" \
            '.deployments[] | select(.decisionDefinition) | select(.decisionDefinition.decisionRequirementsKey == ($drd_key | tonumber)) | .decisionDefinition')
          
          # Display each decision under this DRD
          echo "$decisions" | while read -r decision; do
            if [ ! -z "$decision" ] && [ "$decision" != "null" ]; then
              local decision_id=$(echo "$decision" | jq -r '.decisionDefinitionId')
              local decision_version=$(echo "$decision" | jq -r '.version')
              local decision_name=$(echo "$decision" | jq -r '.name')
              echo "      ↪ $decision_name (Decision ID: $decision_id, v$decision_version)"
            fi
          done
        done
      elif [ "$decision_count" -gt 0 ]; then
        # Fallback if we have decisions but no DRDs (unusual but possible)
        echo "  Found $decision_count decision definition(s) (without parent DRD information)"
        echo "  Decision details:"
        echo "$JSON_RESPONSE" | jq -r '.deployments[] | select(.decisionDefinition) | 
          "    - " + .decisionDefinition.decisionDefinitionId + 
          " (v" + (.decisionDefinition.version|tostring) + ")" + 
          if .decisionDefinition.name then ": " + .decisionDefinition.name else "" end'
      fi
      
      # Count form entries
      if echo "$JSON_RESPONSE" | jq -e '.deployments[] | select(.form)' > /dev/null 2>&1; then
        form_count=$(echo "$JSON_RESPONSE" | jq '[.deployments[] | select(.form)] | length')
        echo "  Found $form_count forms"
        
        # List all forms
        if [ "$form_count" -gt 0 ]; then
          echo "  Form details:"
          echo "$JSON_RESPONSE" | jq -r '.deployments[] | select(.form) | 
            "    - " + .form.formId + 
            " (v" + (.form.version|tostring) + ")" + 
            " from " + .form.resourceName'
        fi
      fi
      
      # Calculate total resources
      local total_resources=$((process_count + decision_count + drd_count + form_count))
      
      # Get deployment key from response
      local deployment_key=""
      if echo "$JSON_RESPONSE" | jq -e '.deploymentKey' > /dev/null 2>&1; then
        deployment_key=$(echo "$JSON_RESPONSE" | jq -r '.deploymentKey')
        echo "  Deployment key: $deployment_key"
      fi
      
      # Calculate total resources
      local total_resources=$((process_count + decision_count + drd_count + form_count))
      echo "  Total resources deployed: $total_resources"
      
      # Set GitHub output variables
      success_message="✅ Deployment to $ENVIRONMENT successful! Deployed $total_resources resources from $file_count files."
      
      # Add key to message if available
      if [ ! -z "$deployment_key" ]; then
        success_message="$success_message (Deployment key: $deployment_key)"
      fi
      echo "DEPLOYMENT_SUCCESS=true" >> $GITHUB_ENV
      echo "DEPLOYMENT_STATUS=$success_message" >> $GITHUB_ENV
      
      log "notice" "$success_message"
      echo "🔹 Resource breakdown:"
      [ "$process_count" -gt 0 ] && echo "   - $process_count process definition$([ "$process_count" -ne 1 ] && echo "s")"
      [ "$decision_count" -gt 0 ] && echo "   - $decision_count decision definition$([ "$decision_count" -ne 1 ] && echo "s")"
      [ "$drd_count" -gt 0 ] && echo "   - $drd_count decision requirements diagram$([ "$drd_count" -ne 1 ] && echo "s") (DRD)"
      [ "$form_count" -gt 0 ] && echo "   - $form_count form$([ "$form_count" -ne 1 ] && echo "s")"
      
      log_group_end
      return 0
    else
      # Deployment probably failed, but check for specific cases
      
      # Check if it's the case where the process hasn't changed
      if echo "$JSON_RESPONSE" | jq -e '.key' > /dev/null 2>&1; then
        local key=$(echo "$JSON_RESPONSE" | jq -r '.key')
        log "notice" "✅ Deployment to $ENVIRONMENT successful! Deployed files are unchanged (deployment key: $key)"
        echo "DEPLOYMENT_SUCCESS=true" >> $GITHUB_ENV
        echo "DEPLOYMENT_STATUS=Deployment successful (no changes detected)" >> $GITHUB_ENV
        
        echo "🔹 Note: Deployed $file_count files but no changes were detected since the last deployment."
        echo "  Deployment key: $key"
        
        log_group_end
        return 0
      fi
      
      # Otherwise, treat as a failure
      error_message="❌ Deployment to $ENVIRONMENT failed! See logs for details."
      if echo "$JSON_RESPONSE" | jq -e '.message' > /dev/null 2>&1; then
        error_details=$(echo "$JSON_RESPONSE" | jq -r '.message')
      else
        error_details="Unknown error - see deployment-response.json for details"
      fi
      
      # Set GitHub output variables
      echo "DEPLOYMENT_SUCCESS=false" >> $GITHUB_ENV
      echo "DEPLOYMENT_STATUS=$error_message" >> $GITHUB_ENV
      echo "DEPLOYMENT_ERROR=$error_details" >> $GITHUB_ENV
      
      log "error" "$error_message"
      log "error" "Error details: $error_details"
      log_group_end
      return 1
    fi
  else
    # Not a valid JSON response
    error_message="❌ Deployment to $ENVIRONMENT failed with unexpected response!"
    
    # Set GitHub output variables
    echo "DEPLOYMENT_SUCCESS=false" >> $GITHUB_ENV
    echo "DEPLOYMENT_STATUS=$error_message" >> $GITHUB_ENV
    echo "DEPLOYMENT_ERROR=Invalid response format" >> $GITHUB_ENV
    
    log "error" "$error_message"
    log "error" "Raw response: $JSON_RESPONSE"
    log_group_end
    return 1
  fi
}

# Main function
main() {
  echo "🔷 Starting Zeebe deployment process for $ENVIRONMENT environment..."
  
  # Check if jq is installed
  if ! command -v jq &> /dev/null; then
    log "error" "The 'jq' command is required but not installed. Please install it and try again."
    exit 1
  fi
  
  # Check if curl is installed
  if ! command -v curl &> /dev/null; then
    log "error" "The 'curl' command is required but not installed. Please install it and try again."
    exit 1
  fi
  
  # Validate environment variables
  validate_env
  
  # Get OAuth token
  get_oauth_token
  if [ $? -ne 0 ]; then
    log "error" "Authentication failed! Cannot proceed with deployment."
    exit 1
  fi
  
  # Find files to deploy
  find_deployment_files
  if [ $? -ne 0 ]; then
    log "error" "No files found to deploy. Exiting."
    exit 1
  fi
  
  # Deploy the files
  deploy_files
  result=$?
  
  # Clean up
  rm -f "$files_list"
  
  if [ $result -eq 0 ]; then
    echo "🔷 Deployment to $ENVIRONMENT completed successfully!"
    exit 0
  else
    echo "🔷 Deployment to $ENVIRONMENT failed!"
    exit 1
  fi
}

# Run the main function
main