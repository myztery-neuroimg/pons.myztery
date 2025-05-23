#!/usr/bin/env bash
#
# environment.sh - Environment setup for the brain MRI processing pipeline
#
# This module contains:
# - Environment variables (paths, directories)
# - Logging functions
# - Configuration parameters
# - Dependency checks
#

# ------------------------------------------------------------------------------
# Logging & Color Setup (needs to be defined first)
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function for logging with timestamps
log_message() {
  local text="$1"
  # Write to both stderr and the LOG_FILE if it exists
  if [ -n "${LOG_FILE:-}" ]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $text" | tee -a "$LOG_FILE" >&2
  else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $text" >&2
  fi
}

log_formatted() {
  local level=$1
  local message=$2
  case $level in
    "INFO")    echo -e "${BLUE}[INFO]${NC} $message" >&2 ;;
    "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message" >&2 ;;
    "WARNING") echo -e "${YELLOW}[WARNING]${NC} $message" >&2 ;;
    "ERROR")   echo -e "${RED}[ERROR]${NC} $message" >&2 ;;
    *)         echo -e "[LOG] $message" >&2 ;;
  esac
}

# Log error and increment error counter
log_error() {
  local message="$1"
  local error_code="${2:-1}"  # Default error code is 1
  
  log_formatted "ERROR" "$message"
  
  # Update pipeline status if defined
  if [ -n "${PIPELINE_SUCCESS:-}" ]; then
    PIPELINE_SUCCESS=false
    PIPELINE_ERROR_COUNT=$((PIPELINE_ERROR_COUNT + 1))
  fi
  
  return $error_code
}

# Function for diagnostic output (only to log file, not to stdout)
log_diagnostic() {
  local message="$1"
  # Only write to log file, not to stdout/stderr
  if [ -n "${LOG_FILE:-}" ]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] DIAGNOSTIC: $message" >> "$LOG_FILE"
  fi
}

# Function to execute commands with diagnostic output redirection
execute_with_logging() {
  local cmd="$1"
  local log_prefix="${2:-cmd}"
  local diagnostic_log="${LOG_DIR}/${log_prefix}_diagnostic.log"
  
  # Create diagnostic log directory if needed
  mkdir -p "$LOG_DIR"
  
  # Log the command that will be executed
  log_message "Executing: $cmd (diagnostic output redirected to $diagnostic_log)"
  
  # Execute command:
  # - Stdout is filtered to remove diagnostic lines, then sent to stdout AND the main log
  # - Stderr is sent to both the diagnostic log AND stderr
  # Remove quotes to avoid passing them directly to the command
  cmd=$(echo "$cmd" | sed -e 's/\\"/"/g')
  eval "$cmd" > >(grep -v "^2DIAGNOSTIC" | tee -a "$LOG_FILE") 2> >(tee -a "$diagnostic_log" >&2)
  
  # Return the exit code of the command (not of the tee/grep pipeline)
  return ${PIPESTATUS[0]}
}

# Function specifically for ANTs commands with enhanced explanations
execute_ants_command() {
  local log_prefix="${1:-ants_cmd}"
  local step_description="${2:-ANTs processing step}"  # New parameter for step description
  local diagnostic_log="${LOG_DIR}/${log_prefix}_diagnostic.log"
  local cmd=("${@:3}") # Get all arguments except the first two as the command
  
  # Create diagnostic log directory if needed
  mkdir -p "$LOG_DIR"
  
  # IMPROVEMENT: Better description of what's happening
  log_formatted "INFO" "==== $step_description ===="
  log_message "Running: ${cmd[0]} (full details in log file)"
  log_message "Diagnostic output saved to: $diagnostic_log"
  
  # Show primary parameters in a simplified form if available
  local cmd_str="${cmd[*]}"
  if [[ "$cmd_str" == *"-d "* ]]; then
    local dim=$(echo "$cmd_str" | grep -o -- "-d [0-9]" | cut -d ' ' -f 2)
    log_message "Processing ${dim}D image data"
  fi
  
  # Extract common parameters for better visibility
  [[ "$cmd_str" == *"-f "* ]] && log_message "Fixed (reference) image: $(echo "$cmd_str" | grep -o -- "-f [^ ]*" | cut -d ' ' -f 2)"
  [[ "$cmd_str" == *"-m "* ]] && log_message "Moving (source) image: $(echo "$cmd_str" | grep -o -- "-m [^ ]*" | cut -d ' ' -f 2)"
  [[ "$cmd_str" == *"-o "* ]] && log_message "Output prefix: $(echo "$cmd_str" | grep -o -- "-o [^ ]*" | cut -d ' ' -f 2)"
  
  # Create named pipes for better output handling
  local stdout_pipe=$(mktemp -u)
  local stderr_pipe=$(mktemp -u)
  mkfifo "$stdout_pipe"
  mkfifo "$stderr_pipe"
  
  # Enhanced progress tracking
  local start_time=$(date +%s)
  
  # Print initial progress indicator
  echo -n "Progress: " >&2
  
  # Start background processes to handle output
  # This improved filter removes verbose registration output and shows progress
  (
    # Progress indicator counter
    local line_count=0
    local major_step=""
    
    while IFS= read -r line; do
      # Check for major step changes to provide better feedback
      if echo "$line" | grep -q "Running.*Transform registration"; then
        major_step=$(echo "$line" | sed -E 's/.*Running (.*)Transform registration.*/\1/')
        echo -e "\n${BLUE}[PROGRESS]${NC} Starting $major_step registration phase" >&2
        echo -n "Progress: " >&2
        line_count=0
      fi
      
      # Filter out diagnostic and verbose registration messages
      if ! echo "$line" | grep -qE "^(2)?DIAGNOSTIC|^XXDIAGNOSTIC|convergenceValue|metricValue|ITERATION_TIME|Running.*Transform registration|DIAGNOSTIC|CurrentIteration"; then
        echo "$line" | tee -a "$LOG_FILE"
      else
        # Print a dot to show progress without the verbose output
        line_count=$((line_count + 1))
        if [ $((line_count % 10)) -eq 0 ]; then
          echo -n "." >&2
        fi
        # Still save the diagnostic info to the log file
        echo "$line" >> "$diagnostic_log"
      fi
    done
  ) < "$stdout_pipe" &
  local stdout_pid=$!
  
  tee -a "$diagnostic_log" < "$stderr_pipe" >&2 &
  local stderr_pid=$!
  
  # Execute command directly without eval with improved output redirection
  "${cmd[@]}" > "$stdout_pipe" 2> "$stderr_pipe"
  local status=$?
  
  # Wait for output handling processes to complete
  wait $stdout_pid
  wait $stderr_pid
  
  # Calculate elapsed time
  local end_time=$(date +%s)
  local elapsed=$((end_time - start_time))
  local minutes=$((elapsed / 60))
  local seconds=$((elapsed % 60))
  
  # Add newline to separate progress dots from completion message
  echo "" >&2
  
  # Add better status reporting after command completes
  if [ $status -eq 0 ]; then
    log_formatted "SUCCESS" "$step_description completed successfully (${minutes}m ${seconds}s)"
    
    # Look for output files to suggest visualization
    if [[ "$cmd_str" == *"-o "* ]]; then
      local output_prefix=$(echo "$cmd_str" | grep -o -- "-o [^ ]*" | cut -d ' ' -f 2)
      
      # For brain extraction
      if [[ "$step_description" == *"brain extraction"* ]] && [[ -f "${output_prefix}BrainExtractionBrain.nii.gz" ]]; then
        log_formatted "INFO" "--------------------------------------------------------"
        log_formatted "INFO" "VISUALIZATION SUGGESTION"
        log_message "To view the extracted brain, run:"
        log_message "  freeview ${output_prefix}BrainExtractionBrain.nii.gz ${output_prefix}BrainExtractionMask.nii.gz"
        log_formatted "INFO" "--------------------------------------------------------"
      
      # For registration
      elif [[ "$step_description" == *"registration"* ]] && [[ -f "${output_prefix}Warped.nii.gz" ]]; then
        local fixed_img=$(echo "$cmd_str" | grep -o -- "-f [^ ]*" | cut -d ' ' -f 2)
        log_formatted "INFO" "--------------------------------------------------------"
        log_formatted "INFO" "VISUALIZATION SUGGESTION"
        log_message "To check registration quality, run:"
        log_message "  freeview ${output_prefix}Warped.nii.gz $fixed_img"
        log_formatted "INFO" "--------------------------------------------------------"
      fi
    fi
    
  else
    log_formatted "ERROR" "$step_description failed with status $status after ${minutes}m ${seconds}s"
    # Extract important error lines from the diagnostic log
    tail -n 10 "$diagnostic_log" | grep -v -E "^(2)?DIAGNOSTIC|^XXDIAGNOSTIC|convergenceValue" | tail -n 3
  fi
  
  # Remove named pipes
  rm -f "$stdout_pipe" "$stderr_pipe"
  
  # Return the exit code of the command
  return $status
}

# Export logging functions so they're available to subshells
export -f log_message log_formatted log_error log_diagnostic execute_with_logging execute_ants_command

# ------------------------------------------------------------------------------
# Shell Options
# ------------------------------------------------------------------------------
#set -e
#set -u
#set -o pipefail

# ------------------------------------------------------------------------------
# Key Environment Variables (Paths & Directories)
# ------------------------------------------------------------------------------
export SRC_DIR="../DICOM"          # DICOM input directory
export DICOM_PRIMARY_PATTERN='Image"*"'   # Filename pattern for your DICOM files, might be .dcm on some scanners, Image- for Siemens
export PIPELINE_SUCCESS=true       # Track overall pipeline success
export PIPELINE_ERROR_COUNT=0      # Count of errors in pipeline
export EXTRACT_DIR="../extracted"  # Where NIfTI files land after dcm2niix

# Parallelization configuration (defaults, can be overridden by config file)
export PARALLEL_JOBS=1             # Number of parallel jobs to use
export MAX_CPU_INTENSIVE_JOBS=1    # Number of jobs for CPU-intensive operations
export PARALLEL_TIMEOUT=0          # Timeout for parallel operations (0 = no timeout)
export PARALLEL_HALT_MODE="soon"   # How to handle failed parallel jobs

export RESULTS_DIR="../mri_results"
mkdir -p "$RESULTS_DIR"
# Set ANTs Path relative to the script location
export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJ_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Ensure ANTS_PATH is properly expanded
export ANTS_PATH="${ANTS_PATH:-"$PROJ_ROOT/ants"}"
# Replace tilde with $HOME if present
export ANTS_PATH="${ANTS_PATH/#\~/$HOME}"
export ANTS_BIN="${ANTS_PATH}/bin"
# Log ANTs paths for debugging
log_message "ANTs paths: ANTS_PATH=$ANTS_PATH, ANTS_BIN=$ANTS_BIN"

# Set SUIT directory for cerebellum and brainstem segmentation
export SUIT_DIR="${SUIT_DIR:-$HOME/SUIT}"
# Replace tilde with $HOME if present
export SUIT_DIR="${SUIT_DIR/#\~/$HOME}"
log_message "SUIT directory: SUIT_DIR=$SUIT_DIR"

export LOG_DIR="${RESULTS_DIR}/logs"
mkdir -p "$LOG_DIR"
mkdir -p "$RESULTS_DIR"

# Log file capturing pipeline-wide logs
export LOG_FILE="${LOG_DIR}/processing_$(date +"%Y%m%d_%H%M%S").log"

# ------------------------------------------------------------------------------
# Export environment variables just defined above
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Pipeline Parameters / Presets
# ------------------------------------------------------------------------------
PROCESSING_DATATYPE="float"  # internal float
OUTPUT_DATATYPE="int"        # final int16

# Quality settings (LOW, MEDIUM, HIGH)
QUALITY_PRESET="HIGH"

# Add ANTs to PATH if it exists
if [ -d "$ANTS_BIN" ]; then
  export PATH="$PATH:${ANTS_BIN}"
  log_formatted "INFO" "Added ANTs bin directory to PATH: $ANTS_BIN"
  export ANTS_THREADS=28
  # Set ANTs/ITK threading variables for proper parallelization
  export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$ANTS_THREADS"
  export OMP_NUM_THREADS="$ANTS_THREADS"
  export ANTS_RANDOM_SEED=1234
  log_formatted "INFO" "Set parallel processing variables: ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=$ANTS_THREADS, OMP_NUM_THREADS=$ANTS_THREADS"
else
  log_formatted "ERROR" "ANTs bin directory not found: $ANTS_BIN"
fi

# N4 Bias Field Correction presets: "iterations,convergence,bspline,shrink"
export N4_PRESET_LOW="20x20x25,0.0001,150,4"
export N4_PRESET_MEDIUM="50x50x50x50,0.000001,200,4"
export N4_PRESET_HIGH="100x100x100x50,0.0000001,300,2"
export N4_PRESET_FLAIR="$N4_PRESET_HIGH"  # override if needed

# Set default N4_PARAMS by QUALITY_PRESET
if [ "$QUALITY_PRESET" = "HIGH" ]; then
    export N4_PARAMS="$N4_PRESET_HIGH"
elif [ "$QUALITY_PRESET" = "MEDIUM" ]; then
    export N4_PARAMS="$N4_PRESET_MEDIUM"
else
    export N4_PARAMS="$N4_PRESET_LOW"
fi

# Parse out the fields for general sequences
N4_ITERATIONS=$(echo "$N4_PARAMS"      | cut -d',' -f1)
N4_CONVERGENCE=$(echo "$N4_PARAMS"    | cut -d',' -f2)
N4_BSPLINE=$(echo "$N4_PARAMS"        | cut -d',' -f3)
N4_SHRINK=$(echo "$N4_PARAMS"         | cut -d',' -f4)

# Parse out FLAIR-specific fields
N4_ITERATIONS_FLAIR=$(echo "$N4_PRESET_FLAIR"  | cut -d',' -f1)
N4_CONVERGENCE_FLAIR=$(echo "$N4_PRESET_FLAIR" | cut -d',' -f2)
N4_BSPLINE_FLAIR=$(echo "$N4_PRESET_FLAIR"     | cut -d',' -f3)
N4_SHRINK_FLAIR=$(echo "$N4_PRESET_FLAIR"      | cut -d',' -f4)

# Multi-axial integration parameters (antsMultivariateTemplateConstruction2.sh)
TEMPLATE_ITERATIONS=2
TEMPLATE_GRADIENT_STEP=0.2
TEMPLATE_TRANSFORM_MODEL="SyN"
TEMPLATE_SIMILARITY_METRIC="CC"
TEMPLATE_SHRINK_FACTORS="6x4x2x1"
TEMPLATE_SMOOTHING_SIGMAS="3x2x1x0"
TEMPLATE_WEIGHTS="100x50x50x10"

# Registration & motion correction
REG_TRANSFORM_TYPE=2  # antsRegistrationSyN.sh: 2 => rigid+affine+syn
REG_METRIC_CROSS_MODALITY="MI"
REG_METRIC_SAME_MODALITY="CC"
ANTS_THREADS=12
REG_PRECISION=1

# White matter guided registration parameters
WM_GUIDED_DEFAULT=true  # Default to use white matter guided registration
WM_INIT_TRANSFORM_PREFIX="_wm_init"  # Prefix for WM-guided initialization transforms
WM_MASK_SUFFIX="_wm_mask.nii.gz"  # Suffix for white matter mask files
WM_THRESHOLD_VAL=3  # Threshold value for white matter segmentation (class 3 in Atropos)

# Orientation distortion correction parameters
# Main toggle
ORIENTATION_PRESERVATION_ENABLED=true

# Topology preservation parameters
TOPOLOGY_CONSTRAINT_WEIGHT=0.5
TOPOLOGY_CONSTRAINT_FIELD="1x1x1"

# Jacobian regularization parameters
JACOBIAN_REGULARIZATION_WEIGHT=1.0
REGULARIZATION_GRADIENT_FIELD_WEIGHT=0.5

# Correction thresholds
ORIENTATION_CORRECTION_THRESHOLD=0.3
ORIENTATION_SCALING_FACTOR=0.05
ORIENTATION_SMOOTH_SIGMA=1.5

# Quality assessment thresholds
ORIENTATION_EXCELLENT_THRESHOLD=0.1
ORIENTATION_GOOD_THRESHOLD=0.2
ORIENTATION_ACCEPTABLE_THRESHOLD=0.3
SHEARING_DETECTION_THRESHOLD=0.05

# Hyperintensity detection
THRESHOLD_WM_SD_MULTIPLIER=2.3
MIN_HYPERINTENSITY_SIZE=4

# Tissue segmentation parameters
ATROPOS_T1_CLASSES=3
ATROPOS_FLAIR_CLASSES=4
ATROPOS_CONVERGENCE="5,0.0"
ATROPOS_MRF="[0.1,1x1x1]"
ATROPOS_INIT_METHOD="kmeans"

# Cropping & padding
PADDING_X=5
PADDING_Y=5
PADDING_Z=5
C3D_CROP_THRESHOLD=0.1
C3D_PADDING_MM=5

# Reference templates from FSL or other sources
if [ -z "${FSLDIR:-}" ]; then
  log_formatted "WARNING" "FSLDIR not set. Using default paths for templates."
  export TEMPLATE_DIR="/usr/local/fsl/data/standard"
  # Don't exit - allow pipeline to continue with default paths
else
  export TEMPLATE_DIR="${FSLDIR}/data/standard"
fi
EXTRACTION_TEMPLATE="MNI152_T1_1mm.nii.gz"
PROBABILITY_MASK="MNI152_T1_1mm_brain_mask.nii.gz"
REGISTRATION_MASK="MNI152_T1_1mm_brain_mask_dil.nii.gz"

# ------------------------------------------------------------------------------
# Dependency Checks
# ------------------------------------------------------------------------------
check_command() {
  local cmd=$1
  local package=$2
  local hint=${3:-""}

  if command -v "$cmd" &> /dev/null; then
    log_formatted "SUCCESS" "✓ $package is installed ($(command -v "$cmd"))"
    return 0
  else
    # Use log_error instead of log_formatted for consistent error tracking
    log_error "✗ $package is not installed or not in PATH" 127
    
    [ -n "$hint" ] && log_formatted "INFO" "$hint"
    return 1
  fi
}

check_ants() {
  log_formatted "INFO" "Checking ANTs tools..."
  local ants_tools=("antsRegistrationSyN.sh" "N4BiasFieldCorrection" \
                     "antsApplyTransforms" "antsBrainExtraction.sh" "MeasureImageSimilarity")
  local missing=0
  for tool in "${ants_tools[@]}"; do
    if ! check_command "$tool" "ANTs ($tool)"; then
      missing=$((missing+1))
    fi
  done
  [ $missing -gt 0 ] && return 1 || return 0
}

check_fsl() {
  log_formatted "INFO" "Checking FSL..."
  local fsl_tools=("fslinfo" "fslstats" "fslmaths" "bet" "flirt" "fast" "fslcc")
  local missing=0
  for tool in "${fsl_tools[@]}"; do
    if ! check_command "$tool" "FSL ($tool)"; then
      missing=$((missing+1))
    fi
  done
  [ $missing -gt 0 ] && return 1 || return 0
}

check_freesurfer() {
  log_formatted "INFO" "Checking FreeSurfer..."
  local fs_tools=("mri_convert" "freeview")
  local missing=0
  for tool in "${fs_tools[@]}"; do
    if ! check_command "$tool" "FreeSurfer ($tool)"; then
      missing=$((missing+1))
    fi
  done
  [ $missing -gt 0 ] && return 1 || return 0
}

check_c3d() {
  log_formatted "INFO" "Checking Convert3D..."
  if ! check_command "c3d" "Convert3D" "Download from: http://www.itksnap.org/pmwiki/pmwiki.php?n=Downloads.C3D"; then
    return 1
  fi
  return 0
}

check_dcm2niix() {
  log_formatted "INFO" "Checking dcm2niix..."
  if ! check_command "dcm2niix" "dcm2niix" "Try: brew install dcm2niix"; then
    return 1
  fi
  return 0
}

check_os() {
  log_formatted "INFO" "Checking operating system..."
  local os_name=$(uname -s)
  case "$os_name" in
    "Darwin")
      log_formatted "SUCCESS" "✓ Running on macOS"
      ;;
    "Linux")
      log_formatted "SUCCESS" "✓ Running on Linux"
      ;;
    *)
      log_formatted "WARNING" "⚠ Running on unknown OS: $os_name"
      ;;
  esac
  return 0
}

check_dependencies() {
  log_formatted "INFO" "==== MRI Processing Dependency Checker ===="
  
  local error_count=0
  
  check_command "dcm2niix" "dcm2niix" "Try: brew install dcm2niix" || error_count=$((error_count+1))
  check_ants || error_count=$((error_count+1))
  check_fsl || error_count=$((error_count+1))
  check_freesurfer || error_count=$((error_count+1))
  check_c3d || error_count=$((error_count+1))
  check_os
  
  log_formatted "INFO" "==== Checking optional but recommended tools ===="
  
  # Check for ImageMagick (useful for image manipulation)
  check_command "convert" "ImageMagick" "Install with: brew install imagemagick" || log_formatted "WARNING" "ImageMagick is recommended for image conversions"
  
  # Check for parallel (useful for parallel processing)
  check_command "parallel" "GNU Parallel" "Install with: brew install parallel" || log_formatted "ERROR" "GNU Parallel is required for faster processing"
  
  # Summary
  log_formatted "INFO" "==== Dependency Check Summary ===="
  
  if [ $error_count -eq 0 ]; then
    log_formatted "SUCCESS" "All required dependencies are installed!"
    return 0
  else
    log_error "$error_count required dependencies are missing." 127
    log_formatted "INFO" "Please install the missing dependencies before running the processing pipeline."
    
    return 1
  fi
}

# Comprehensive check of all dependencies needed by the pipeline
check_all_dependencies() {
  log_formatted "INFO" "==== Comprehensive Pipeline Dependency Check ===="
  
  local error_count=0
  local warning_count=0
  
  # Required core tools
  log_formatted "INFO" "==== Checking core processing tools ===="
  
  # DICOM Conversion
  check_command "dcm2niix" "dcm2niix (DICOM converter)" "Install with: brew install dcm2niix" || error_count=$((error_count+1))
  if command -v dcmdump &>/dev/null; then
    log_formatted "SUCCESS" "✓ DCMTK (dcmdump) is installed ($(command -v dcmdump))"
  else
    log_formatted "WARNING" "⚠ DCMTK (dcmdump) is not installed - DICOM header analysis will be limited"
    warning_count=$((warning_count+1))
  fi
  
  # Check ANTs tools - critical for most operations
  check_ants || error_count=$((error_count+1))
  
  # Check FSL tools - critical for basic operations
  check_fsl || error_count=$((error_count+1))
  
  # FreeSurfer tools - used for visualization and some analyses
  check_freesurfer || error_count=$((error_count+1))
  
  # Convert3D - used for some preprocessing
  check_c3d || error_count=$((error_count+1))
  
  # Check operating system
  check_os
  
  # Check for Python (needed for analyze_dicom_headers.py)
  log_formatted "INFO" "==== Checking Python environment ===="
  local python_cmd=""
  if command -v python3 &>/dev/null; then
    python_cmd="python3"
    log_formatted "SUCCESS" "✓ Python 3 is installed ($(command -v python3))"
  elif command -v python &>/dev/null; then
    python_cmd="python"
    log_formatted "SUCCESS" "✓ Python is installed ($(command -v python))"
  else
    log_formatted "ERROR" "✗ Python is not installed or not in PATH"
    error_count=$((error_count+1))
  fi
  
  # Check for required scripts
  log_formatted "INFO" "==== Checking for required scripts ===="
  
  # Check for fix_dcm2niix_duplicates.sh
  local script_paths=(
    "./src/fix_dcm2niix_duplicates.sh"
    "../src/fix_dcm2niix_duplicates.sh"
    "$(dirname "${BASH_SOURCE[0]}")/../fix_dcm2niix_duplicates.sh"
  )
  
  local script_found=false
  for path in "${script_paths[@]}"; do
    if [ -f "$path" ]; then
      script_found=true
      log_formatted "SUCCESS" "✓ fix_dcm2niix_duplicates.sh found at $path"
      break
    fi
  done
  
  if [ "$script_found" = false ]; then
    log_formatted "WARNING" "⚠ fix_dcm2niix_duplicates.sh not found in any expected location"
    warning_count=$((warning_count+1))
  fi
  
  # Check for analyze_dicom_headers.py
  script_paths=(
    "./src/analyze_dicom_headers.py"
    "../src/analyze_dicom_headers.py"
    "$(dirname "${BASH_SOURCE[0]}")/../analyze_dicom_headers.py"
  )
  
  script_found=false
  for path in "${script_paths[@]}"; do
    if [ -f "$path" ]; then
      script_found=true
      log_formatted "SUCCESS" "✓ analyze_dicom_headers.py found at $path"
      break
    fi
  done
  
  if [ "$script_found" = false ]; then
    log_formatted "WARNING" "⚠ analyze_dicom_headers.py not found in any expected location"
    warning_count=$((warning_count+1))
  fi
  
  # Check for optional but recommended tools
  log_formatted "INFO" "==== Checking optional but recommended tools ===="
  
  # Check for ImageMagick (useful for image manipulation)
  check_command "convert" "ImageMagick" "Install with: brew install imagemagick" || {
    log_formatted "WARNING" "⚠ ImageMagick is recommended for image conversions"
    warning_count=$((warning_count+1))
  }
  
  # Check for GNU Parallel - REQUIRED for DICOM parallel processing
  if ! check_command "parallel" "GNU Parallel" "Install with: brew install parallel"; then
    log_formatted "ERROR" "✗ GNU Parallel is required for DICOM parallel processing"
    error_count=$((error_count+1))
  else
    # Verify this is GNU parallel and not the one from moreutils
    if ! parallel --version 2>&1 | grep -q "GNU parallel"; then
      log_formatted "ERROR" "✗ Found 'parallel' command, but it doesn't appear to be GNU parallel"
      log_formatted "INFO" "On some systems, 'moreutils' provides a different 'parallel' command"
      log_formatted "INFO" "Install GNU Parallel: https://www.gnu.org/software/parallel/"
      error_count=$((error_count+1))
    fi
  fi
  
  # Summary
  log_formatted "INFO" "==== Dependency Check Summary ===="
  
  if [ $error_count -eq 0 ] && [ $warning_count -eq 0 ]; then
    log_formatted "SUCCESS" "All required dependencies are installed and configured correctly!"
    return 0
  elif [ $error_count -eq 0 ]; then
    log_formatted "SUCCESS" "✓ All required dependencies are installed!"
    log_formatted "WARNING" "⚠ $warning_count non-critical dependencies are missing or misconfigured."
    log_formatted "INFO" "The pipeline will work, but some features might be limited."
    return 0
  else
    log_error "$error_count critical dependencies are missing!" 127
    [ $warning_count -gt 0 ] && log_formatted "WARNING" "Additionally, $warning_count non-critical dependencies are missing."
    log_formatted "INFO" "Please install the missing dependencies before running the processing pipeline."
    return 1
  fi
}

# ------------------------------------------------------------------------------
# Utility Functions
# ------------------------------------------------------------------------------

# Get the directory path for a specific module
get_module_dir() {
  local module="$1"
  
  # Standard module directories
  case "$module" in
    "metadata")
      echo "${RESULTS_DIR}/metadata"
      ;;
    "combined")
      echo "${RESULTS_DIR}/combined"
      ;;
    "bias_corrected")
      echo "${RESULTS_DIR}/bias_corrected"
      ;;
    "brain_extraction")
      echo "${RESULTS_DIR}/brain_extraction"
      ;;
    "standardized")
      echo "${RESULTS_DIR}/standardized"
      ;;
    "registered")
      echo "${RESULTS_DIR}/registered"
      ;;
    "segmentation")
      echo "${RESULTS_DIR}/segmentation"
      ;;
    "hyperintensities")
      echo "${RESULTS_DIR}/hyperintensities"
      ;;
    "validation")
      echo "${RESULTS_DIR}/validation"
      ;;
    "qc")
      echo "${RESULTS_DIR}/qc_visualizations"
      ;;
    *)
      echo "${RESULTS_DIR}/${module}"
      ;;
  esac
}

# Create directory for a module if it doesn't exist
create_module_dir() {
  local module="$1"
  local dir=$(get_module_dir "$module")
  
  if [ ! -d "$dir" ]; then
    log_formatted "INFO" "Creating directory for module '$module': $dir"
    mkdir -p "$dir"
  fi
  
  echo "$dir"
}

# Generate standardized output file path
get_output_path() {
  local module="$1"       # Module name (e.g., "bias_corrected")
  local basename="$2"     # Base filename
  local suffix="$3"       # Suffix to add (e.g., "_n4")
  
  echo "$(get_module_dir "$module")/${basename}${suffix}.nii.gz"
}

# ------------------------------------------------------------------------------
# Error Codes
# ------------------------------------------------------------------------------
# 1-9: General errors
export ERR_GENERAL=1          # General error
export ERR_INVALID_ARGS=2     # Invalid arguments
export ERR_FILE_NOT_FOUND=3   # File not found
export ERR_PERMISSION=4       # Permission denied
export ERR_IO_ERROR=5         # I/O error
export ERR_TIMEOUT=6          # Operation timed out
export ERR_VALIDATION=7       # Validation failed

# 10-19: Module-specific errors
export ERR_IMPORT=10          # Import module error
export ERR_PREPROC=11         # Preprocessing module error
export ERR_REGISTRATION=12    # Registration module error
export ERR_SEGMENTATION=13    # Segmentation module error
export ERR_ANALYSIS=14        # Analysis module error
export ERR_VISUALIZATION=15   # Visualization module error
export ERR_QA=16              # QA module error

# 20-29: External tool errors
export ERR_ANTS=20            # ANTs tool error
export ERR_FSL=21             # FSL tool error
export ERR_FREESURFER=22      # FreeSurfer tool error
export ERR_C3D=23             # Convert3D error
export ERR_DCM2NIIX=24        # dcm2niix error

# 30-39: Data errors
export ERR_DATA_CORRUPT=30    # Data corruption
export ERR_DATA_MISSING=31    # Missing data
export ERR_DATA_INCOMPATIBLE=32 # Incompatible data

# 127: Environment/dependency errors
export ERR_DEPENDENCY=127     # Missing dependency

# ------------------------------------------------------------------------------
# Validation Functions
# ------------------------------------------------------------------------------

# Validate that a file exists and is readable
validate_file() {
  local file="$1"
  local description="${2:-file}"
  
  if [ ! -f "$file" ]; then
    log_error "$description not found: $file" $ERR_FILE_NOT_FOUND
    return $ERR_FILE_NOT_FOUND
  fi
  
  if [ ! -r "$file" ]; then
    log_error "$description is not readable: $file" $ERR_PERMISSION
    return $ERR_PERMISSION
  fi
  
  return 0
}

# Validate NIfTI file with additional checks
validate_nifti() {
  local file="$1"
  local description="${2:-NIfTI file}"
  local min_size="${3:-10240}"  # Minimum file size in bytes (10KB default)
  
  # First check if file exists and is readable
  validate_file "$file" "$description" || return $?
  
  # Check file size
  local file_size=$(stat -f "%z" "$file" 2>/dev/null || stat --format="%s" "$file" 2>/dev/null)
  if [ -z "$file_size" ] || [ "$file_size" -lt "$min_size" ]; then
    log_error "$description has suspicious size ($file_size bytes): $file" $ERR_DATA_CORRUPT
    return $ERR_DATA_CORRUPT
  fi
  
  # Check if file can be read by FSL
  if ! fslinfo "$file" &>/dev/null; then
    log_error "$description appears to be corrupt or invalid: $file" $ERR_DATA_CORRUPT
    return $ERR_DATA_CORRUPT
  fi
  
  return 0
}

# Validate that a directory exists and is writable
validate_directory() {
  local dir="$1"
  local description="${2:-directory}"
  local create="${3:-false}"
  
  if [ ! -d "$dir" ]; then
    if [ "$create" = "true" ]; then
      log_formatted "INFO" "Creating $description: $dir"
      mkdir -p "$dir" || {
        log_error "Failed to create $description: $dir" $ERR_PERMISSION
        return $ERR_PERMISSION
      }
    else
      log_error "$description not found: $dir" $ERR_FILE_NOT_FOUND
      return $ERR_FILE_NOT_FOUND
    fi
  fi
  
  return 0
}

standardize_datatype() {
  local input_file="$1"
  local output_file="$2"
  local datatype="${3:-$PROCESSING_DATATYPE}"  # Default to PROCESSING_DATATYPE
  
  log_message "Standardizing datatype of $input_file to $datatype"
  
  # Use fslmaths to convert datatype
  fslmaths "$input_file" -dt "$datatype" "$output_file"
  
  # Verify the conversion
  local new_dt=$(fslinfo "$output_file" | grep datatype | awk '{print $2}')
  log_message "Datatype conversion complete: $new_dt"
}

set_sequence_params() {
  local sequence_type="$1"
  
  case "$sequence_type" in
    "T1")
      # T1 parameters
      export CURRENT_N4_PARAMS="$N4_PARAMS"
      ;;
    "FLAIR")
      # FLAIR-specific parameters
      export CURRENT_N4_PARAMS="$N4_PRESET_FLAIR"
      ;;
    *)
      # Default parameters
      export CURRENT_N4_PARAMS="$N4_PARAMS"
      log_formatted "WARNING" "Unknown sequence type: $sequence_type. Using default parameters."
      ;;
  esac
  
  log_message "Set sequence parameters for $sequence_type: $CURRENT_N4_PARAMS"
}

# Create necessary directories
create_directories() {
  mkdir -p "$EXTRACT_DIR"
  mkdir -p "$RESULTS_DIR"
  mkdir -p "$RESULTS_DIR/metadata"
  mkdir -p "$RESULTS_DIR/combined"
  mkdir -p "$RESULTS_DIR/bias_corrected"
  mkdir -p "$RESULTS_DIR/brain_extraction"
  mkdir -p "$RESULTS_DIR/standardized"
  mkdir -p "$RESULTS_DIR/registered"
  mkdir -p "$RESULTS_DIR/segmentation/tissue"
  mkdir -p "$RESULTS_DIR/segmentation/brainstem"
  mkdir -p "$RESULTS_DIR/segmentation/pons"
  mkdir -p "$RESULTS_DIR/hyperintensities/thresholds"
  mkdir -p "$RESULTS_DIR/hyperintensities/clusters"
  mkdir -p "$RESULTS_DIR/validation/registration"
  mkdir -p "$RESULTS_DIR/validation/segmentation"
  mkdir -p "$RESULTS_DIR/validation/hyperintensities"
  mkdir -p "$RESULTS_DIR/qc_visualizations"
  mkdir -p "$RESULTS_DIR/reports"
  mkdir -p "$RESULTS_DIR/summary"
  
  log_message "Created directory structure"
}

# Validate an entire module execution
validate_module_execution() {
  local module="$1"
  local expected_outputs="$2"  # Comma-separated list of expected output files
  local module_dir="${3:-$(get_module_dir "$module")}"
  
  log_formatted "INFO" "Validating $module module execution..."
  
  # Check if directory exists
  validate_directory "$module_dir" "$module directory" || return $?
  
  # Track validation status
  local validation_status=0
  local missing_files=()
  local invalid_files=()
  
  # Check each expected output
  IFS=',' read -ra files <<< "$expected_outputs"
  for file in "${files[@]}"; do
    # Trim whitespace
    file="$(echo "$file" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    
    # Skip empty entries
    [ -z "$file" ] && continue
    
    # Add module_dir if path is not absolute
    [[ "$file" != /* ]] && file="${module_dir}/${file}"
    
    if [ ! -f "$file" ]; then
      missing_files+=("$file")
      validation_status=$ERR_VALIDATION
      continue
    fi
    
    # Validate file contents if it's a NIfTI file
    if [[ "$file" == *.nii || "$file" == *.nii.gz ]]; then
      if ! validate_nifti "$file" >/dev/null; then
        invalid_files+=("$file")
        validation_status=$ERR_VALIDATION
      fi
    fi
  done
  
  # Report validation results
  if [ ${#missing_files[@]} -gt 0 ]; then
    log_error "Module $module is missing expected output files: ${missing_files[*]}" $ERR_VALIDATION
  fi
  
  if [ ${#invalid_files[@]} -gt 0 ]; then
    log_error "Module $module produced invalid output files: ${invalid_files[*]}" $ERR_VALIDATION
  fi
  
  [ $validation_status -eq 0 ] && log_formatted "SUCCESS" "Module $module validation successful"
  return $validation_status
}

# ------------------------------------------------------------------------------
# Parallel Processing Functions
# ------------------------------------------------------------------------------

# Check if GNU parallel is installed and available
check_parallel() {
  log_formatted "INFO" "Checking for GNU parallel..."
  
  if ! command -v parallel &> /dev/null; then
    log_formatted "WARNING" "GNU parallel not found. Parallel processing will be disabled."
    return 1
  fi
  
  # Check if this is GNU parallel and not moreutils parallel
  if ! parallel --version 2>&1 | grep -q "GNU parallel"; then
    log_formatted "WARNING" "Found 'parallel' command, but it doesn't appear to be GNU parallel. Parallel processing may not work correctly."
    return 2
  fi
  
  log_formatted "SUCCESS" "GNU parallel is available: $(command -v parallel)"
  return 0
}

# Function to load parallel configuration from config file
load_parallel_config() {
  local config_file="${1:-config/parallel_config.sh}"
  
  if [ -f "$config_file" ]; then
    log_formatted "INFO" "Loading parallel configuration from $config_file"
    source "$config_file"
    
    # Auto-detect cores if enabled in config
    if [ "${AUTO_DETECT_CORES:-false}" = true ]; then
      auto_detect_cores
    fi
    
    log_formatted "INFO" "Parallel configuration loaded. PARALLEL_JOBS=$PARALLEL_JOBS, MAX_CPU_INTENSIVE_JOBS=$MAX_CPU_INTENSIVE_JOBS"
    return 0
  else
    log_formatted "WARNING" "Parallel configuration file not found: $config_file. Using defaults."
    return 1
  fi
}

# Run a function in parallel across multiple files
run_parallel() {
  local func_name="$1"        # Function to run in parallel
  local find_pattern="$2"     # Find pattern for input files
  local find_path="$3"        # Path to search for files
  local jobs="${4:-$PARALLEL_JOBS}"  # Number of jobs (default: PARALLEL_JOBS)
  local max_depth="${5:-}"    # Optional: max depth for find
  
  # Check if parallel processing is enabled
  if [ "$jobs" -le 0 ]; then
    log_formatted "INFO" "Parallel processing disabled. Running in sequential mode."
    # Run sequentially
    local find_cmd="find \"$find_path\" -name \"$find_pattern\""
    [ -n "$max_depth" ] && find_cmd="$find_cmd -maxdepth $max_depth"
    
    while IFS= read -r file; do
      "$func_name" "$file"
    done < <(eval "$find_cmd")
    return $?
  fi
  
  # Check if GNU parallel is installed
  if ! check_parallel; then
    log_formatted "WARNING" "GNU parallel not available. Falling back to sequential processing."
    # Run sequentially (same as above)
    local find_cmd="find \"$find_path\" -name \"$find_pattern\""
    [ -n "$max_depth" ] && find_cmd="$find_cmd -maxdepth $max_depth"
    
    while IFS= read -r file; do
      "$func_name" "$file"
    done < <(eval "$find_cmd")
    return $?
  fi
  
  # Build parallel command with proper error handling
  log_formatted "INFO" "Running $func_name in parallel with $jobs jobs"
  local parallel_cmd="find \"$find_path\" -name \"$find_pattern\""
  [ -n "$max_depth" ] && parallel_cmd="$parallel_cmd -maxdepth $max_depth"
  parallel_cmd="$parallel_cmd -print0 | parallel -0 -j $jobs --halt $PARALLEL_HALT_MODE,fail=1 $func_name {}"
  
  # Execute and capture exit code
  eval "$parallel_cmd"
  return $?
}

# Initialize environment
initialize_environment() {
  # Set error handling
  set -e
  set -u
  set -o pipefail
  
  # Initialize error count
  error_count=0
  
  log_message "Initializing environment"
  
  # Export functions
  export -f check_command
  export -f check_dependencies
  export -f check_all_dependencies
  export -f standardize_datatype
  export -f get_output_path
  export -f get_module_dir
  export -f set_sequence_params
  export -f create_module_dir
  export -f check_parallel
  export -f load_parallel_config
  export -f run_parallel
  export -f validate_file validate_nifti validate_directory
  export -f validate_module_execution
  export -f log_diagnostic execute_with_logging
  
  log_message "Environment initialized"
}

# Parse command line arguments
parse_arguments() {
  # Default values
  CONFIG_FILE="config/default_config.sh"
  SRC_DIR="../DiCOM"
  RESULTS_DIR="../mri_results"
  SUBJECT_ID=""
  QUALITY_PRESET="MEDIUM"
  PIPELINE_TYPE="FULL"
  
  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      -c|--config)
        CONFIG_FILE="$2"
        shift 2
        ;;
      -i|--input)
        SRC_DIR="$2"
        shift 2
        ;;
      -o|--output)
        RESULTS_DIR="$2"
        shift 2
        ;;
      -s|--subject)
        SUBJECT_ID="$2"
        shift 2
        ;;
      -q|--quality)
        QUALITY_PRESET="$2"
        shift 2
        ;;
      -p|--pipeline)
        PIPELINE_TYPE="$2"
        shift 2
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        log_formatted "ERROR" "Unknown option: $1"
        show_help
        exit 1
        ;;
    esac
  done
  
  # If subject ID is not provided, derive it from the input directory
  if [ -z "$SUBJECT_ID" ]; then
    SUBJECT_ID=$(basename "$SRC_DIR")
  fi
  
  # Export variables
  export SRC_DIR
  export RESULTS_DIR
  export SUBJECT_ID
  export QUALITY_PRESET
  export PIPELINE_TYPE
  
  log_message "Arguments parsed: SRC_DIR=$SRC_DIR, RESULTS_DIR=$RESULTS_DIR, SUBJECT_ID=$SUBJECT_ID, QUALITY_PRESET=$QUALITY_PRESET, PIPELINE_TYPE=$PIPELINE_TYPE"
}

# Show help message
show_help() {
  echo "Usage: ./pipeline.sh [options]"
  echo ""
  echo "Options:"
  echo "  -c, --config FILE    Configuration file (default: config/default_config.sh)"
  echo "  -i, --input DIR      Input directory (default: ../DiCOM)"
  echo "  -o, --output DIR     Output directory (default: ../mri_results)"
  echo "  -s, --subject ID     Subject ID (default: derived from input directory)"
  echo "  -q, --quality LEVEL  Quality preset (LOW, MEDIUM, HIGH) (default: MEDIUM)"
  echo "  -p, --pipeline TYPE  Pipeline type (BASIC, FULL, CUSTOM) (default: FULL)"
  echo "  -h, --help           Show this help message and exit"
}

compute_initial_affine() {
  local moving="$1"
  local fixed="$2"  # typically MNI
  local output_prefix="$3"

  if [[ ! -f "${output_prefix}0GenericAffine.mat" ]]; then
    echo "Generating initial affine for ${moving}"
    antsRegistrationSyNQuick.sh \
      -d 3 \
      -f "$fixed" \
      -m "$moving" \
      -t a \
      -o "$output_prefix"
  else
    echo "Affine already exists for ${moving}"
  fi
}

export compute_initial_affine

log_message "Environment module loaded"

