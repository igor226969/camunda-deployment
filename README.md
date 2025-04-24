# Camunda CI/CD Script

This repository contains scripts for downloading and deploying Camunda BPMN, DMN, and Form files to Zeebe clusters.

## 📋 Prerequisites

Before using the scripts in this repository, ensure you have the following installed:

- **Git Bash** - Required for running the scripts on Windows
  - Download and install from [Git for Windows](https://gitforwindows.org/)
  
- **jq** - JSON processor for parsing API responses
  - Download and install from [Download jq](https://jqlang.org/download/)
  - Make sure jq is in your PATH or in the same directory as the scripts
  - I recommend using [scoop](https://scoop.sh/) for windows

The scripts also use curl, which comes pre-installed with Git Bash, so no additional installation is required.

## 🔐 Environment Setup

The download script requires authentication credentials, which should be stored in a `.env` file.

### Setting up your environment file:

1. Copy the template file to create your own environment file:
   ```bash
   cp .env.template .env
   ```

2. Edit the `.env` file and fill in your Camunda credentials:
   ```
   CAMUNDA_CONSOLE_CLIENT_ID="your-client-id"
   CAMUNDA_CONSOLE_CLIENT_SECRET="your-client-secret"
   CAMUNDA_CONSOLE_OAUTH_AUDIENCE="api.cloud.camunda.io"
   ```

> ⚠️ **Important**: The `.env` file contains sensitive information and should never be committed to the repository. It's already added to `.gitignore` to prevent accidental commits.

## 🔄 Workflow Process

### 1. Always Pull Latest Changes First

> ⚠️ **Important**: Always run `git pull` before running any scripts to ensure you have the latest version of the codebase:

```bash
git pull origin dev
```

### 2. Download BPMN files from Camunda Modeler

To download files from a specific folder in your Camunda project using Git Bash:

```bash
./scripts/camunda-deploy-downloader.sh -p YOUR_PROJECT_ID -f FOLDER_NAME
```

Example:
```bash
./scripts/camunda-deploy-downloader.sh -p e3195c12-25f3-4fd2-a5a6-af0d0d2ac4fd -f "WTR-123"
```

Make sure to run this command from the root directory of the project in Git Bash.

This will:
- Connect to Camunda using your credentials
- Find the specified folder in your project
- Download all BPMN, DMN, and Form files to the `src` directory

### 3. Handling Process Renaming

> ⚠️ **Important**: File renaming and deletion is not automatically tracked by the system. Process renaming should be done in Camunda Modeler first, then handled properly in your IDE:

#### For Deprecated Processes:
- When a process needs to be deprecated, rename it in Camunda Modeler to include "(DEPRECATED)" in the file name:
  ```
  Original: "Payment Process.bpmn"
  Renamed: "Payment Process (DEPRECATED).bpmn"
  ```
- After downloading the files, you must manually delete the original file in your IDE as the renaming cannot be tracked automatically
- GitHub will try to match files based on content similarity and will interpret this as a rename operation

#### For Regular Name Changes:
- If you're changing a process name in Camunda Modeler for any other reason:
  ```
  Original: "Payment Process.bpmn"
  Renamed: "Updated Payment Process.bpmn"
  ```
- After downloading the files, you must manually delete the original file in your IDE as the renaming cannot be tracked automatically
- GitHub will try to match files based on content similarity and may interpret this as a rename operation

### 4. Review & Commit Changes

After downloading, review the files in the `src` directory:

```bash
git status
```

Then commit and push your changes:

```bash
git add src/
git commit -m "Add workflow files for WTR-123"
git push origin dev
```

### 5. Promote to Higher Environments

After successful testing:

1. Create a pull request from your branch to the target environment branch (uat, staging, pre-prod, or prod)
2. Add relevant reviewers
3. Include testing evidence in the PR description

```
Target branch options:
- uat: User Acceptance Testing
- staging: Pre-production testing
- pre-prod: Final verification
- prod: Production
```

### 6. Automatic Deployment

When your pull request is merged:

- The GitHub Actions workflow will automatically trigger
- Files will be deployed to the Zeebe cluster for the target environment
- Deployment status will be visible in the Actions tab

## 📊 Monitoring Deployments

You can monitor all deployments in the GitHub Actions tab of your repository. Each deployment creates an artifact containing the deployment response for troubleshooting.

## 🔧 Troubleshooting

If you encounter issues:

1. Check the GitHub Actions logs for detailed error messages
2. Verify your credentials in the `.env` file
3. Ensure your project ID and folder name are correct
4. Confirm that the files in the src directory are valid BPMN, DMN, or Form files