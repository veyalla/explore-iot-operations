#!/bin/bash

# Strict Mode
set -e  # Exit immediately if a command exits with a non-zero status.
set -o pipefail  # The return value of a pipeline is the status of the last command to exit with a non-zero status.

# --- Configuration & Defaults ---
DEFAULT_LOCATION="westus2"
DEFAULT_CLUSTER_NAME="iotops-quickstart-cluster"
SUPPORTED_LOCATIONS=("eastus" "eastus2" "westus2" "westus" "westeurope" "northeurope")
ENV_VARS_FILENAME="iotops_env_vars.sh"
CODESPACE_NAME_FILE=".iotops_codespace_name"  # File to store a stable codespace name

# --- Global Variables (will be set by functions/args) ---
SCRIPT_DIR="$(dirname "$0")"
ENV_VARS_FILE="${SCRIPT_DIR}/${ENV_VARS_FILENAME}"
LOCATION=""
RESOURCE_GROUP=""
CLUSTER_NAME=""
CODESPACE_NAME=""  # Will be resolved
UNIQUE_SUFFIX=""
STORAGE_ACCOUNT=""
SCHEMA_REGISTRY=""
SCHEMA_REGISTRY_NAMESPACE=""
INSTANCE_NAME=""
SA_RESOURCE_ID=""
SR_RESOURCE_ID=""
CURRENT_SUBSCRIPTION=""
CURRENT_SUBSCRIPTION_ID=""

# Flags
NON_INTERACTIVE=false
CLEANUP_REQUESTED=false
CLEANUP_CONFIRMED=false

# --- Helper Functions ---
# Colors
COLOR_RESET='\033[0m'
COLOR_GREEN='\033[32m'
COLOR_RED='\033[31m'
COLOR_YELLOW='\033[33m'
COLOR_BLUE='\033[34m'

print_info() { echo -e "${COLOR_BLUE}INFO: $1${COLOR_RESET}"; }
print_success() { echo -e "${COLOR_GREEN}SUCCESS: $1${COLOR_RESET}"; }
print_warning() { echo -e "${COLOR_YELLOW}WARN: $1${COLOR_RESET}"; }
print_error() { echo -e "${COLOR_RED}ERROR: $1${COLOR_RESET}" >&2; }

error_exit() {
    print_error "$1"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

array_contains() {
    local seeking=$1; shift
    local in=1
    for element; do
        if [[ "$element" == "$seeking" ]]; then
            in=0
            break
        fi
    done
    return $in
}

confirm() {
    local prompt="$1 (y/n): "
    local response

    if [ "$NON_INTERACTIVE" = true ]; then
        print_warning "Non-interactive mode: Assuming 'yes' for confirmation: '$1'"
        return 0
    fi

    while true; do
        read -p "$(echo -e "${COLOR_YELLOW}CONFIRM: ${prompt}${COLOR_RESET}")" response
        case "$response" in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer yes (y) or no (n).";;
        esac
    done
}

# --- Prerequisite Checks ---
check_prerequisites() {
    print_info "Checking prerequisites..."

    command_exists az || error_exit "'az' CLI not found. Please install Azure CLI (https://aka.ms/InstallAzureCli)."
    print_success "Azure CLI found."

    local required_extensions=("connectedk8s" "azure-iot-ops")
    local missing_extensions=()
    for ext in "${required_extensions[@]}"; do
        if ! az extension show -n "$ext" &> /dev/null; then
            missing_extensions+=("$ext")
        fi
    done

    if [ ${#missing_extensions[@]} -gt 0 ]; then
        print_warning "Missing required Azure CLI extensions: ${missing_extensions[*]}"
        if confirm "Attempt to install missing extensions?"; then
            for ext in "${missing_extensions[@]}"; do
                print_info "Installing extension '$ext'..."
                az extension add --name "$ext" || error_exit "Failed to install extension '$ext'."
                print_success "Extension '$ext' installed."
            done
        else
            error_exit "Required extensions missing. Please install them manually and rerun."
        fi
    else
        print_success "Required Azure CLI extensions found (${required_extensions[*]})."
    fi
    print_info "Prerequisites check complete."
}

# --- Argument Parsing & Usage ---
usage() {
cat << EOF
Usage: $0 [options]

Sets up Azure resources for IoT Operations Quickstart.

Options:
  -l, --location <location>       Azure location for resources (default: $DEFAULT_LOCATION). Must be in supported list.
  -g, --resource-group <name>     Azure Resource Group name. If provided, location must match the RG location if it exists,
                                  and you will be asked to confirm usage of the existing group.
                                  If not provided, you will be prompted to enter one (or press Enter to derive one).
  -c, --cluster-name <name>       Name of the existing Kubernetes cluster to connect via Arc (default: $DEFAULT_CLUSTER_NAME).
  -y, --non-interactive           Run without prompts, using defaults or provided arguments.
      --cleanup                   Delete the resources created by this script (reads from $ENV_VARS_FILENAME).
      --confirm-cleanup           Must be used with --cleanup in non-interactive mode to confirm deletion.
  -h, --help                      Display this help message and exit.

Supported Locations: ${SUPPORTED_LOCATIONS[*]}
EOF
}

parse_args() {
    LOCATION="$DEFAULT_LOCATION"
    CLUSTER_NAME="$DEFAULT_CLUSTER_NAME"
    RESOURCE_GROUP=""

    local options
    options=$(getopt -o hyl:g:c: --long help,non-interactive,cleanup,confirm-cleanup,location:,resource-group:,cluster-name: -n "$0" -- "$@")
    if [ $? -ne 0 ]; then
        usage
        error_exit "Failed to parse arguments."
    fi

    eval set -- "$options"

    while true; do
        case "$1" in
            -l|--location) LOCATION_ARG="$2"; shift 2;;
            -g|--resource-group) RESOURCE_GROUP_ARG="$2"; shift 2;;
            -c|--cluster-name) CLUSTER_NAME_ARG="$2"; shift 2;;
            -y|--non-interactive) NON_INTERACTIVE=true; shift;;
            --cleanup) CLEANUP_REQUESTED=true; shift;;
            --confirm-cleanup) CLEANUP_CONFIRMED=true; shift;;
            -h|--help) usage; exit 0;;
            --) shift; break;;
            *) error_exit "Internal error! Unrecognized option '$1'";;
        esac
    done

    if [ -n "$LOCATION_ARG" ]; then
        LOCATION="$LOCATION_ARG"
    fi
    if [ -n "$RESOURCE_GROUP_ARG" ]; then
        RESOURCE_GROUP="$RESOURCE_GROUP_ARG"
    fi
    if [ -n "$CLUSTER_NAME_ARG" ]; then
        CLUSTER_NAME="$CLUSTER_NAME_ARG"
    fi

    if [ -z "$RESOURCE_GROUP" ]; then
        array_contains "$LOCATION" "${SUPPORTED_LOCATIONS[@]}" || error_exit "Specified location '$LOCATION' is not supported."
    fi

    if [ "$CLEANUP_REQUESTED" = true ] && [ "$NON_INTERACTIVE" = true ] && [ "$CLEANUP_CONFIRMED" = false ]; then
        error_exit "--confirm-cleanup flag is required when using --cleanup in non-interactive mode."
    fi

    print_info "Arguments parsed. Using Location: $LOCATION, Cluster: $CLUSTER_NAME, Resource Group: ${RESOURCE_GROUP:-'(To be determined)'}"
}

# --- Core Logic Functions ---

confirm_subscription() {
    print_info "Checking current Azure subscription..."
    CURRENT_SUBSCRIPTION=$(az account show --query "name" -o tsv 2>/dev/null) || true
    CURRENT_SUBSCRIPTION_ID=$(az account show --query "id" -o tsv 2>/dev/null) || true

    if [ -z "$CURRENT_SUBSCRIPTION" ]; then
        error_exit "No active Azure subscription found. Please run 'az login' to log in and then rerun the script."
    fi

    print_success "Current subscription: '$CURRENT_SUBSCRIPTION' ($CURRENT_SUBSCRIPTION_ID)"
    confirm "Is this the correct subscription?" || error_exit "Please use 'az account set -s <subscription_id_or_name>' and rerun."
}

resolve_codespace_name() {
    print_info "Resolving CODESPACE_NAME..."
    if [ -n "$CODESPACE_NAME" ]; then
        print_success "Using existing CODESPACE_NAME: $CODESPACE_NAME"
        return
    fi

    if [ -f "${SCRIPT_DIR}/${CODESPACE_NAME_FILE}" ]; then
        CODESPACE_NAME=$(cat "${SCRIPT_DIR}/${CODESPACE_NAME_FILE}")
        print_success "Using persistent CODESPACE_NAME from file: $CODESPACE_NAME"
    else
        if [ -f /etc/machine-id ]; then
            stable_suffix=$(cat /etc/machine-id | tr -d '\n' | cut -c1-5)
        else
            stable_suffix=$(hostname | tr '[:upper:]' '[:lower:]' | sha256sum | cut -c1-5)
        fi
        CODESPACE_NAME="iotops-${stable_suffix}"
        echo "$CODESPACE_NAME" > "${SCRIPT_DIR}/${CODESPACE_NAME_FILE}"
        print_success "Generated and stored stable CODESPACE_NAME: $CODESPACE_NAME"
    fi
}

resolve_resource_names() {
    print_info "Resolving resource names..."

    # Compute additional randomness from hostname (first 4 characters of SHA256 hash)
    RANDOM_SUFFIX=$(echo "$HOSTNAME" | tr '[:upper:]' '[:lower:]' | sha256sum | cut -c1-4)
    print_info "Using additional random suffix from hostname: $RANDOM_SUFFIX"

    # Resource Group
    if [ -z "$RESOURCE_GROUP" ]; then
        if [ "$NON_INTERACTIVE" = false ]; then
            read -p "$(echo -e "${COLOR_YELLOW}Enter an existing Resource Group name (or press Enter to derive one): ${COLOR_RESET}")" input_rg
            if [ -n "$input_rg" ]; then
                RESOURCE_GROUP="$input_rg"
                print_info "Using provided Resource Group name: $RESOURCE_GROUP"
            else
                RESOURCE_GROUP="${CODESPACE_NAME}${RANDOM_SUFFIX}-rg"
                print_info "No Resource Group provided. Derived name: $RESOURCE_GROUP"
            fi
        else
            RESOURCE_GROUP="${CODESPACE_NAME}${RANDOM_SUFFIX}-rg"
            print_info "Non-interactive mode: Derived Resource Group name: $RESOURCE_GROUP"
        fi
    else
        print_info "Using user-provided Resource Group name: $RESOURCE_GROUP"
    fi

    # Unique Suffix based on CODESPACE_NAME
    UNIQUE_SUFFIX=$(echo "$CODESPACE_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')
    if [ ${#UNIQUE_SUFFIX} -lt 5 ]; then
        UNIQUE_SUFFIX="${UNIQUE_SUFFIX}pad$RANDOM"
    fi
    UNIQUE_SUFFIX=${UNIQUE_SUFFIX:0:16}
    print_info "Using Unique Suffix: $UNIQUE_SUFFIX"

    # Derive Storage Account name (max 24 characters).
    STORAGE_ACCOUNT="st${UNIQUE_SUFFIX}${RANDOM_SUFFIX}"
    STORAGE_ACCOUNT=${STORAGE_ACCOUNT:0:24}

    # Derive Schema Registry name and namespace.
    SCHEMA_REGISTRY="sr${UNIQUE_SUFFIX}${RANDOM_SUFFIX}"
    SCHEMA_REGISTRY=${SCHEMA_REGISTRY:0:24}
    SCHEMA_REGISTRY_NAMESPACE="srn${UNIQUE_SUFFIX}${RANDOM_SUFFIX}"
    SCHEMA_REGISTRY_NAMESPACE=${SCHEMA_REGISTRY_NAMESPACE:0:50}

    INSTANCE_NAME="${CLUSTER_NAME}-instance"

    print_success "Resolved names:"
    echo "  Resource Group: $RESOURCE_GROUP"
    echo "  Storage Account: $STORAGE_ACCOUNT"
    echo "  Schema Registry: $SCHEMA_REGISTRY (Namespace: $SCHEMA_REGISTRY_NAMESPACE)"
    echo "  IoT Ops Instance: $INSTANCE_NAME"
}

ensure_resource_group() {
    print_info "Ensuring Resource Group '$RESOURCE_GROUP' in location '$LOCATION'..."
    local rg_exists=false
    local existing_location=""
    existing_location=$(az group show --name "$RESOURCE_GROUP" --query "location" -o tsv 2>/dev/null || true)

    if [ -n "$existing_location" ]; then
        rg_exists=true
        print_info "Resource Group '$RESOURCE_GROUP' already exists in location '$existing_location'."
    fi

    if [ "$rg_exists" = true ]; then
        if ! confirm "Use this existing Resource Group '$RESOURCE_GROUP' for deployment?"; then
             error_exit "Aborted. Please specify a different Resource Group name."
        fi
        print_info "User confirmed usage of existing Resource Group '$RESOURCE_GROUP'."
        if [ "$existing_location" != "$LOCATION" ]; then
            print_warning "Existing Resource Group '$RESOURCE_GROUP' is in '$existing_location', but target location was '$LOCATION'."
            if confirm "Use existing location '$existing_location' for deployment?"; then
                LOCATION="$existing_location"
                print_info "Updated deployment location to '$LOCATION'."
            else
                error_exit "Resource Group location mismatch and user chose not to use existing location."
            fi
        fi
        array_contains "$LOCATION" "${SUPPORTED_LOCATIONS[@]}" || error_exit "Resource Group location '$LOCATION' is not supported."
        print_success "Using existing Resource Group '$RESOURCE_GROUP' in location '$LOCATION'."
    else
        print_info "Creating Resource Group '$RESOURCE_GROUP' in location '$LOCATION'..."
        array_contains "$LOCATION" "${SUPPORTED_LOCATIONS[@]}" || error_exit "Cannot create Resource Group: Location '$LOCATION' is not supported."
        az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none || error_exit "Failed to create Resource Group '$RESOURCE_GROUP'."
        print_success "Resource Group '$RESOURCE_GROUP' created successfully."
    fi
}

ensure_arc_connection() {
    print_info "Ensuring Kubernetes cluster '$CLUSTER_NAME' is connected to Azure Arc..."
    if az connectedk8s show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --output none &> /dev/null; then
        print_success "Cluster '$CLUSTER_NAME' is already connected to Arc."
    else
        print_info "Cluster '$CLUSTER_NAME' not found connected in '$RESOURCE_GROUP'. Attempting to connect..."
        print_warning "This requires context to be set for the target Kubernetes cluster ('kubectl config use-context <your-cluster-context>')."
        print_warning "The 'az connectedk8s connect' command may take several minutes."
        confirm "Proceed with connecting '$CLUSTER_NAME' via Arc?" || error_exit "Arc connection cancelled by user."
        az connectedk8s connect --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --location "$LOCATION" || error_exit "Failed to connect cluster '$CLUSTER_NAME' to Azure Arc."
        print_success "Cluster '$CLUSTER_NAME' connected successfully."
    fi
}

ensure_storage_account() {
    print_info "Ensuring Storage Account '$STORAGE_ACCOUNT' exists..."
    local sa_id
    sa_id=$(az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query id -o tsv 2>/dev/null || true)
    if [ -n "$sa_id" ]; then
        print_success "Storage Account '$STORAGE_ACCOUNT' already exists."
        SA_RESOURCE_ID="$sa_id"
    else
        print_info "Creating Storage Account '$STORAGE_ACCOUNT' in '$LOCATION' (this may take a minute)..."
        az storage account create \
            --name "$STORAGE_ACCOUNT" \
            --location "$LOCATION" \
            --resource-group "$RESOURCE_GROUP" \
            --enable-hierarchical-namespace true \
            --sku Standard_RAGRS \
            --kind StorageV2 || error_exit "Failed to create Storage Account '$STORAGE_ACCOUNT'."
        sa_id=$(az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
        if [ -z "$sa_id" ]; then
             error_exit "Storage Account '$STORAGE_ACCOUNT' created but failed to retrieve its ID."
        fi
        print_success "Storage Account '$STORAGE_ACCOUNT' created."
        SA_RESOURCE_ID="$sa_id"
    fi
}

ensure_schema_registry() {
    print_info "Ensuring IoT Ops Schema Registry '$SCHEMA_REGISTRY' exists..."
    local sr_id
    sr_id=$(az iot ops schema registry show --name "$SCHEMA_REGISTRY" --resource-group "$RESOURCE_GROUP" --query id -o tsv 2>/dev/null || true)
    if [ -n "$sr_id" ]; then
        print_success "Schema Registry '$SCHEMA_REGISTRY' already exists."
        SR_RESOURCE_ID="$sr_id"
    else
        print_info "Creating Schema Registry '$SCHEMA_REGISTRY'..."
        az iot ops schema registry create \
            --name "$SCHEMA_REGISTRY" \
            --resource-group "$RESOURCE_GROUP" \
            --location "$LOCATION" \
            --registry-namespace "$SCHEMA_REGISTRY_NAMESPACE" \
            --sa-resource-id "$SA_RESOURCE_ID" || error_exit "Failed to create Schema Registry '$SCHEMA_REGISTRY'."
        sr_id=$(az iot ops schema registry show --name "$SCHEMA_REGISTRY" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
         if [ -z "$sr_id" ]; then
             error_exit "Schema Registry '$SCHEMA_REGISTRY' created but failed to retrieve its ID."
        fi
        print_success "Schema Registry '$SCHEMA_REGISTRY' created."
        SR_RESOURCE_ID="$sr_id"
    fi
}

initialize_iot_ops() {
    print_info "Ensuring IoT Operations components are initialized on cluster '$CLUSTER_NAME'..."
    if az iot ops show --cluster "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --name "$INSTANCE_NAME" &> /dev/null; then
        print_success "IoT Operations instance '$INSTANCE_NAME' already exists."
        return 0
    fi
    print_info "IoT Operations instance not found. Running 'az iot ops init' (this may take several minutes)..."
    # Removed --no-progress flag to show CLI progress
    az iot ops init --cluster "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" || error_exit "Failed to initialize IoT Operations components on cluster '$CLUSTER_NAME'."
    print_success "IoT Operations components initialized."
    print_warning "It might take a few more minutes for all pods to become ready."
}

ensure_iot_ops_instance() {
    print_info "Ensuring IoT Ops instance '$INSTANCE_NAME' exists..."
    if az iot ops show --cluster "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --name "$INSTANCE_NAME" --output none &> /dev/null; then
        print_success "IoT Ops instance '$INSTANCE_NAME' already exists."
    else
        print_info "Creating IoT Ops instance '$INSTANCE_NAME'..."
        # Removed --output none flag to display progress/status and added --add-insecure-listener true
        az iot ops create \
            --cluster "$CLUSTER_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --name "$INSTANCE_NAME" \
            --location "$LOCATION" \
            --sr-resource-id "$SR_RESOURCE_ID" \
            --add-insecure-listener true \
            --broker-frontend-replicas 1 \
            --broker-frontend-workers 1 \
            --broker-backend-part 1 \
            --broker-backend-workers 1 \
            --broker-backend-rf 2 \
            --broker-mem-profile Low || error_exit "Failed to create IoT Operations instance '$INSTANCE_NAME'."
        print_success "IoT Ops instance '$INSTANCE_NAME' created."
    fi
}

save_env_vars() {
    print_info "Saving environment variables to '$ENV_VARS_FILE'..."
    cat <<EOL > "$ENV_VARS_FILE"
# Environment variables for IoT Operations setup generated on $(date)
# Source this file to load variables into your shell: source $ENV_VARS_FILENAME

export AZURE_SUBSCRIPTION_ID="$CURRENT_SUBSCRIPTION_ID"
export AZURE_SUBSCRIPTION_NAME="$CURRENT_SUBSCRIPTION"
export AZURE_RESOURCE_GROUP="$RESOURCE_GROUP"
export AZURE_LOCATION="$LOCATION"
export ARC_CLUSTER_NAME="$CLUSTER_NAME"
export CODESPACE_NAME="$CODESPACE_NAME"
export UNIQUE_SUFFIX="$UNIQUE_SUFFIX"
export AZURE_STORAGE_ACCOUNT="$STORAGE_ACCOUNT"
export AZURE_SA_RESOURCE_ID="$SA_RESOURCE_ID"
export AZURE_SCHEMA_REGISTRY="$SCHEMA_REGISTRY"
export AZURE_SCHEMA_REGISTRY_NAMESPACE="$SCHEMA_REGISTRY_NAMESPACE"
export AZURE_SR_RESOURCE_ID="$SR_RESOURCE_ID"
export AZURE_IOT_OPS_INSTANCE_NAME="$INSTANCE_NAME"

# End of variables
EOL
    chmod u=rwX "$ENV_VARS_FILE"
    print_success "Environment variables saved."
    print_info "To load these variables into your current shell session, run:"
    echo -e "${COLOR_GREEN}  source \"$ENV_VARS_FILE\"${COLOR_RESET}"
}

cleanup_resources() {
    print_warning "Initiating resource cleanup..."

    if [ ! -f "$ENV_VARS_FILE" ]; then
        error_exit "Environment file '$ENV_VARS_FILE' not found. Cannot determine resources to clean up."
    fi

    print_info "Loading variables from '$ENV_VARS_FILE' for cleanup..."
    local rg_cleanup=$(grep 'export AZURE_RESOURCE_GROUP=' "$ENV_VARS_FILE" | head -n 1 | cut -d'=' -f2 | tr -d '"')
    local cluster_cleanup=$(grep 'export ARC_CLUSTER_NAME=' "$ENV_VARS_FILE" | head -n 1 | cut -d'=' -f2 | tr -d '"')
    local instance_cleanup=$(grep 'export AZURE_IOT_OPS_INSTANCE_NAME=' "$ENV_VARS_FILE" | head -n 1 | cut -d'=' -f2 | tr -d '"')
    local sr_cleanup=$(grep 'export AZURE_SCHEMA_REGISTRY=' "$ENV_VARS_FILE" | head -n 1 | cut -d'=' -f2 | tr -d '"')
    local sa_cleanup=$(grep 'export AZURE_STORAGE_ACCOUNT=' "$ENV_VARS_FILE" | head -n 1 | cut -d'=' -f2 | tr -d '"')

    local missing_vars=""
    [ -z "$rg_cleanup" ] && missing_vars+=" Resource Group"
    [ -z "$cluster_cleanup" ] && missing_vars+=" Cluster Name"
    if [ -n "$missing_vars" ]; then
        error_exit "Could not determine required variables ($missing_vars) from '$ENV_VARS_FILE' for full cleanup."
    fi

    print_warning "This will attempt to delete the following resources:"
    [ -n "$instance_cleanup" ] && echo "  - IoT Ops Instance: $instance_cleanup (in cluster $cluster_cleanup, RG $rg_cleanup)"
    [ -n "$sr_cleanup" ] && echo "  - Schema Registry: $sr_cleanup (in RG $rg_cleanup)"
    [ -n "$sa_cleanup" ] && echo "  - Storage Account: $sa_cleanup (in RG $rg_cleanup)"
    [ -n "$cluster_cleanup" ] && echo "  - Arc K8s Connection: $cluster_cleanup (in RG $rg_cleanup)"
    print_warning "Resource Group '$rg_cleanup' will NOT be deleted automatically."
    print_warning "Deletion can take several minutes and is irreversible."

    if [ "$CLEANUP_CONFIRMED" = false ] && ! confirm "Proceed with deleting these resources?"; then
         error_exit "Cleanup aborted by user."
    fi

    local error_occurred=false

    if [ -n "$instance_cleanup" ]; then
        print_info "Deleting IoT Ops instance '$instance_cleanup'..."
        if az iot ops show --resource-group "$rg_cleanup" --name "$instance_cleanup" &> /dev/null; then
            az iot ops delete --resource-group "$rg_cleanup" --name "$instance_cleanup" --yes --include-deps --force || { print_error "Failed to start deletion of IoT Ops instance."; error_occurred=true; }
            print_success "Deletion command issued for IoT Ops instance '$instance_cleanup'."
        else
            print_warning "IoT Ops instance '$instance_cleanup' not found, skipping deletion."
        fi
    fi

    if [ -n "$sr_cleanup" ]; then
        print_info "Deleting Schema Registry '$sr_cleanup'..."
        if az iot ops schema registry show --name "$sr_cleanup" --resource-group "$rg_cleanup" &> /dev/null; then
            az iot ops schema registry delete --name "$sr_cleanup" --resource-group "$rg_cleanup" --yes || { print_error "Failed to delete Schema Registry '$sr_cleanup'."; error_occurred=true; }
            print_success "Schema Registry '$sr_cleanup' deleted."
        else
            print_warning "Schema Registry '$sr_cleanup' not found, skipping deletion."
        fi
    fi

    if [ -n "$sa_cleanup" ]; then
        print_info "Deleting Storage Account '$sa_cleanup'..."
        if az storage account show --name "$sa_cleanup" --resource-group "$rg_cleanup" &> /dev/null; then
            az storage account delete --name "$sa_cleanup" --resource-group "$rg_cleanup" --yes || { print_error "Failed to delete Storage Account '$sa_cleanup'."; error_occurred=true; }
            print_success "Storage Account '$sa_cleanup' deleted."
        else
            print_warning "Storage Account '$sa_cleanup' not found, skipping deletion."
        fi
    fi

    if [ -n "$cluster_cleanup" ]; then
        print_info "Deleting Arc connection for cluster '$cluster_cleanup'..."
        if az connectedk8s show --name "$cluster_cleanup" --resource-group "$rg_cleanup" &> /dev/null; then
            az connectedk8s delete --name "$cluster_cleanup" --resource-group "$rg_cleanup" --yes || { print_error "Failed to delete Arc connection for '$cluster_cleanup'."; error_occurred=true; }
            print_success "Arc connection for '$cluster_cleanup' deleted."
        else
            print_warning "Arc connection '$cluster_cleanup' not found, skipping deletion."
        fi
    fi

    if [ "$error_occurred" = true ]; then
        print_warning "One or more errors occurred during cleanup. Please check the Azure portal."
        exit 1
    else
        print_success "Resource cleanup complete (excluding Resource Group '$rg_cleanup')."
        print_info "You may want to manually delete the Resource Group '$rg_cleanup' if it's no longer needed."
        print_info "You can also delete the environment file: rm \"$ENV_VARS_FILE\""
    fi
}

# --- Main Execution Logic ---
main() {
    print_info "Starting IoT Operations Quickstart Setup Script..."

    confirm_subscription
    resolve_codespace_name
    resolve_resource_names
    ensure_resource_group
    ensure_arc_connection
    ensure_storage_account
    ensure_schema_registry
    initialize_iot_ops
    ensure_iot_ops_instance

    save_env_vars

    print_success "-----------------------------------------------------"
    print_success " Azure IoT Operations Setup Completed Successfully! "
    print_success "-----------------------------------------------------"
}

# --- Script Entry Point ---
parse_args "$@"

should_check_prereqs=true
for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        should_check_prereqs=false
        break
    fi
done

if [ "$should_check_prereqs" = true ]; then
    check_prerequisites
fi

if [ "$CLEANUP_REQUESTED" = true ]; then
    cleanup_resources
else
    if [ "$should_check_prereqs" = true ]; then
        main
    fi
fi

exit 0
