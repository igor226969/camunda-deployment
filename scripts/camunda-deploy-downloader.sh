#!/bin/bash
# camunda-deploy-downloader.sh
# This script downloads files from a specified folder in a Camunda project and saves them to the src directory

# Get the script's directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$SCRIPT_DIR/.."

# Define the target directory (src folder at root level)
SRC_DIR="$ROOT_DIR/src"

# Load environment variables from .env file
ENV_FILE="$ROOT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    echo "🔹 Loading environment variables from $ENV_FILE..."
    # Export all variables from the .env file
    export $(grep -v '^#' "$ENV_FILE" | xargs)
else
    echo "❌ Environment file $ENV_FILE not found!"
    echo "Please create a .env file based on the .env.template file."
    exit 1
fi

# Define the API URLs
CAMUNDA_OAUTH_URL="https://login.cloud.camunda.io/oauth/token"
CAMUNDA_API_URL="https://modeler.cloud.camunda.io/api/v1/files"
CAMUNDA_PROJECT_API_URL="https://modeler.cloud.camunda.io/api/v1/projects"

# Check if required environment variables are set
if [ -z "$CAMUNDA_CONSOLE_CLIENT_ID" ] || [ -z "$CAMUNDA_CONSOLE_CLIENT_SECRET" ] || [ -z "$CAMUNDA_CONSOLE_OAUTH_AUDIENCE" ]; then
    echo "❌ Required environment variables are missing in .env file."
    echo "Please make sure CAMUNDA_CONSOLE_CLIENT_ID, CAMUNDA_CONSOLE_CLIENT_SECRET, and CAMUNDA_CONSOLE_OAUTH_AUDIENCE are set."
    exit 1
fi

# Project ID and folder name
PROJECT_ID=""
DEPLOY_FOLDER_NAME=""  # This will be set via command-line parameter

# Token storage
TOKEN=""

# Function to display usage information
usage() {
    echo "Usage: $0 -p <project_id> -f <folder_name>"
    echo "  -p  Camunda Project ID (required)"
    echo "  -f  Camunda folder name to download from (required)"
    echo "  -h  Display this help message"
    exit 1
}

# Parse command line arguments
while getopts "p:f:h" opt; do
    case $opt in
        p) PROJECT_ID=$OPTARG ;;
        f) DEPLOY_FOLDER_NAME=$OPTARG ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate required parameters
if [ -z "$PROJECT_ID" ] || [ -z "$DEPLOY_FOLDER_NAME" ]; then
    echo "❌ Error: Missing required parameters"
    if [ -z "$PROJECT_ID" ]; then
        echo "   - Project ID (-p) is required"
    fi
    if [ -z "$DEPLOY_FOLDER_NAME" ]; then
        echo "   - Folder name (-f) is required"
    fi
    usage
fi

# Function to get OAuth token
get_oauth_token() {
    echo "🔹 Requesting OAuth token..."
    
    # Make the request to get the OAuth token
    RESPONSE=$(curl -s --request POST ${CAMUNDA_OAUTH_URL} \
        --header 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode 'grant_type=client_credentials' \
        --data-urlencode "audience=${CAMUNDA_CONSOLE_OAUTH_AUDIENCE}" \
        --data-urlencode "client_id=${CAMUNDA_CONSOLE_CLIENT_ID}" \
        --data-urlencode "client_secret=${CAMUNDA_CONSOLE_CLIENT_SECRET}")

    # Extract the token using jq
    TOKEN=$(echo "$RESPONSE" | jq -r '.access_token')
    
    # Check if the token was obtained successfully
    if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
        echo "❌ Failed to get OAuth token!"
        echo "Response: $RESPONSE"
        exit 1
    else
        echo "🔹 OAuth token obtained successfully!"
    fi
}

# Function to get project details and files
get_project_files() {
    echo "🔹 Fetching project details and file list..."

    # Make the request to get the project details
    PROJECT_RESPONSE=$(curl -s --header "Authorization: Bearer $TOKEN" \
        "$CAMUNDA_PROJECT_API_URL/$PROJECT_ID")
    
    # Save the response to a file for parsing
    echo "$PROJECT_RESPONSE" > "$SCRIPT_DIR/project_response.json"
    
    # Check if the response has valid JSON
    if ! jq empty "$SCRIPT_DIR/project_response.json" 2>/dev/null; then
        echo "❌ Invalid JSON response received!"
        exit 1
    fi
    
    # Check if project exists
    if [ "$(jq -r '.error' "$SCRIPT_DIR/project_response.json")" != "null" ]; then
        echo "❌ Error fetching project: $(jq -r '.error' "$SCRIPT_DIR/project_response.json")"
        exit 1
    fi
    
    echo "🔹 Project details fetched!"
}

# Function to find the specified folder ID
find_deploy_folder_id() {
    echo "🔹 Looking for '$DEPLOY_FOLDER_NAME' folder in Camunda project..."
    
    # Check if folders array exists
    if [ "$(jq -r '.content.folders' "$SCRIPT_DIR/project_response.json")" == "null" ]; then
        echo "❌ No folders found in project"
        return 1
    fi
    
    # Find the folder ID
    DEPLOY_FOLDER_ID=$(jq -r --arg folder_name "$DEPLOY_FOLDER_NAME" '.content.folders[] | select(.name == $folder_name) | .id' "$SCRIPT_DIR/project_response.json")
    
    if [ -z "$DEPLOY_FOLDER_ID" ] || [ "$DEPLOY_FOLDER_ID" == "null" ]; then
        echo "❌ '$DEPLOY_FOLDER_NAME' folder not found in project"
        return 1
    else
        echo "🔹 Found '$DEPLOY_FOLDER_NAME' folder with ID: $DEPLOY_FOLDER_ID"
        return 0
    fi
}

# Function to find files in the specified folder
find_deploy_files() {
    echo "🔹 Finding files in '$DEPLOY_FOLDER_NAME' folder..."
    
    # Check if files array exists
    if [ "$(jq -r '.content.files' "$SCRIPT_DIR/project_response.json")" == "null" ]; then
        echo "🔸 No files found in project."
        return 1
    fi
    
    # Count files in the folder
    FILE_COUNT=$(jq -r --arg folder_id "$DEPLOY_FOLDER_ID" '.content.files[] | select(.folderId == $folder_id) | .id' "$SCRIPT_DIR/project_response.json" | wc -l)
    
    if [ "$FILE_COUNT" -eq 0 ]; then
        echo "❌ No files found in '$DEPLOY_FOLDER_NAME' folder"
        return 1
    else
        echo "🔹 Found $FILE_COUNT files in '$DEPLOY_FOLDER_NAME' folder"
        return 0
    fi
}

# Function to download files from the specified folder to the src directory
download_deploy_files() {
    echo "🔹 Downloading files from '$DEPLOY_FOLDER_NAME' folder to src directory..."
    
    # Ensure src directory exists
    if [ ! -d "$SRC_DIR" ]; then
        echo "🔹 Creating src directory..."
        mkdir -p "$SRC_DIR"
        if [ $? -ne 0 ]; then
            echo "❌ Failed to create src directory. Exiting."
            exit 1
        fi
    fi
    
    # Count for tracking downloads
    success_count=0
    total_count=0
    
    # Save file IDs to a temporary file to avoid subshell issues
    jq -r --arg folder_id "$DEPLOY_FOLDER_ID" '.content.files[] | select(.folderId == $folder_id) | @json' "$SCRIPT_DIR/project_response.json" > "$SCRIPT_DIR/temp_files.json"
    
    # Read the file line by line
    while IFS= read -r file_json; do
        # Extract file ID, name, and type
        file_id=$(echo "$file_json" | jq -r '.id')
        file_name=$(echo "$file_json" | jq -r '.name')
        file_type=$(echo "$file_json" | jq -r '.type')
        
        total_count=$((total_count + 1))
        echo "🔸 Downloading file: $file_name (ID: $file_id, Type: $file_type)"
        
        # Download file content
        FILE_RESPONSE=$(curl -s --header "Authorization: Bearer $TOKEN" \
            "$CAMUNDA_API_URL/$file_id")
        
        # Extract only the content part from the response (if it's JSON)
        if echo "$FILE_RESPONSE" | jq empty 2>/dev/null; then
            # It's valid JSON, extract content field if it exists
            if [[ $(echo "$FILE_RESPONSE" | jq 'has("content")') == "true" ]]; then
                FILE_CONTENT=$(echo "$FILE_RESPONSE" | jq -r '.content')
            else
                # No content field, save the entire response
                FILE_CONTENT="$FILE_RESPONSE"
            fi
        else
            # Not JSON or invalid JSON, save as is
            FILE_CONTENT="$FILE_RESPONSE"
        fi
        
        # Determine file extension based on type
        local extension
        case "$file_type" in
            "BPMN") extension=".bpmn" ;;
            "DMN") extension=".dmn" ;;
            "FORM") extension=".form" ;;
            *) extension=".json" ;;
        esac
        
        # Set output path to src directory
        OUTPUT_PATH="${SRC_DIR}/${file_name}${extension}"
        
        # Save file content
        echo "$FILE_CONTENT" > "$OUTPUT_PATH"
        
        if [ -s "$OUTPUT_PATH" ]; then
            echo "🔹 File saved to: $OUTPUT_PATH"
            success_count=$((success_count + 1))
        else
            echo "⚠️ Warning: File may be empty: $file_name"
        fi
    done < <(cat "$SCRIPT_DIR/temp_files.json")
    
    # Clean up temporary file
    rm -f "$SCRIPT_DIR/temp_files.json"
    
    # Report download results
    if [ $success_count -gt 0 ]; then
        echo "✅ Downloaded $success_count files successfully!"
        return 0
    else
        echo "❌ No files were downloaded successfully."
        return 1
    fi
}

# Main function
main() {
    echo "🔷 Starting Camunda folder downloader for '$DEPLOY_FOLDER_NAME'..."
    
    # Check if jq is installed
    if ! command -v jq &> /dev/null; then
        echo "❌ The 'jq' command is required but not installed. Please install it and try again."
        exit 1
    fi
    
    # Check if curl is installed
    if ! command -v curl &> /dev/null; then
        echo "❌ The 'curl' command is required but not installed. Please install it and try again."
        exit 1
    fi
    
    # Get OAuth token
    get_oauth_token
    
    # Get project details
    get_project_files
    
    # Find the specified folder
    find_deploy_folder_id
    if [ $? -ne 0 ]; then
        echo "❌ Failed to find '$DEPLOY_FOLDER_NAME' folder. Exiting."
        exit 1
    fi
    
    # Find files in the specified folder
    find_deploy_files
    if [ $? -ne 0 ]; then
        echo "❌ No files found in '$DEPLOY_FOLDER_NAME' folder. Exiting."
        exit 1
    fi
    
    # Download files from the specified folder to src directory
    download_deploy_files
    
    # Clean up project_response.json file
    if [ -f "$SCRIPT_DIR/project_response.json" ]; then
        echo "🧹 Removing temporary project_response.json file..."
        rm "$SCRIPT_DIR/project_response.json"
    fi
    
    echo "🔷 Download completed successfully!"
    echo "💡 Files from '$DEPLOY_FOLDER_NAME' folder have been saved to the src directory."
    echo "💡 You can now use Git commands to commit and push these changes."
}

# Run the main function
main