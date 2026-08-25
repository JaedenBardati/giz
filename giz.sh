#!/bin/bash
# ==============================================================================================================================================================================
# GIZ: One GIZMO Command To Rule Them All.
# Author: Jaeden Bardati 2025
#
# A convenience script for the GIZMO workflow.
# No prior GIZMO installation is required, but you need the required modules for compilation (MPI, GSL, FFTW, HDF5, see gizmo documentation if you get a compilation error)
# Includes support for both running locally and slurm queuing.
# If this is your first time running, call "giz --help".
#
# Functionality:
#    1) Creates a source code directory called "code" in the run directory (local by default).
#            -- reads a preexisting local "code" directory, untars "code.tar" or "code.tgz"/"code.tar.gz", copies source code from ${GIZMO_SOURCE}, or clones the public/private repo
#    2) Generates/edits a "Config.sh" file for simulation settings before compilation.
#            -- reads a preexisting "Config.sh" in source code directory if it exists, copies template file from source code or creates a blank file
#    3) Compiles GIZMO source code.
#            -- does not run if --skip-make or -s flag is used, outputs executable GIZMO in source code directory
#    4) Generates/edits a "params.txt" file for simulation settings after compilation.
#            -- reads a preexisting "Config.sh" in source code directory if it exists, copies template file from source code or creates a blank file
#    5) Runs GIZMO executable in run directory.
#            -- using the -r flag is for running from restart files (sets the GIZMO restart flag to 1), or use -r2 for restart from snapshot (sets flag to 2)
#
# File structure:
#           run directory (-d)
#          /         |       \
#        code   params.txt   output
#       /    \                   
# GIZMO     Config.sh 
#
# Example Usage:
#    giz                                  # standard call (called in GIZMO run directory)
#    giz -s                               # skips compilation phase (only adjusts parameter file and runs GIZMO)
#    giz -r                               # when running from restart files (sets GIZMO flag for restart files)
#    giz -d path/to/run/directory         # uses the inputted path to the run directory
#    giz --config-name "Config_alt.sh"    # uses an alternative filename for Config.sh (otherwise the same)
#    giz --exec-name "GIZMO_alt"          # uses an alternative filename for GIZMO executable (otherwise the same)
#    giz --param-name "params_alt.txt"    # uses an alternative filename for params.txt parameter file (otherwise the same)
#
# If you have your own version of GIZMO source code you want to copy from (e.g. that is not the public or private repo version) set GIZMO_SOURCE to that directory before running.
#
# Tips for running in parallel: 
#    Typically set NPROCESSES * THREADS_PER_PROCESS = num of cpus per node * NNODES unless hyperthreading,
#.   or even better NPROCESSES/NNODES = num cpus per node /THREADS_PER_PROCESS = whole number
#
# For how to write a Config.sh or parameter file, see GIZMO code documentation at http://www.tapir.caltech.edu/~phopkins/Site/GIZMO_files/gizmo_documentation.html
# ==============================================================================================================================================================================
#
# TODO:
#    1) Auto add some parameters like fftw2/fftw3
#    2) Add installation of mpi, gsl, fftw, hdf5, etc. (if needed)
#    3) check for parameter consistency + fix like openmp in config file and threads from -T AND check if cooling on for TREECOOL moving?


set -e  # exit immediately on error

info()   { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn()   { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }
prompt() { printf -v p "\033[1;36m[PROMPT]\033[0m ${1}: "; read -p "$p" "$2"; }
prompt_yn() { prompt "$1 [y/n]" YN; YN=$(echo "$YN" | tr -d ' ' | tr '[:upper:]' '[:lower:]'); }

remove_block_between_markers() {
    local target_file="$1"
    local start_marker="$2"
    local end_marker="$3"

    if [[ ! -f "${target_file}" ]]; then
        info "No file found at ${target_file}; nothing to reset."
        return 1
    fi

    local tmp_file
    tmp_file="$(mktemp)"

    awk -v start="$start_marker" -v end="$end_marker" '
        BEGIN { inblock=0; found_start=0; found_end=0 }
        $0==start { inblock=1; found_start=1; next }
        $0==end { if (inblock) { inblock=0; found_end=1; next } }
        !inblock { print }
        END {
            if (found_start && !found_end) exit 2
            if (!found_start) exit 3
        }
    ' "$target_file" > "$tmp_file"
    local awk_status=$?

    if [[ $awk_status -eq 2 ]]; then
        info "Found start marker '${start_marker}' but not end marker '${end_marker}' in ${target_file}; refusing to modify."
        rm -f "$tmp_file"
        return 1
    elif [[ $awk_status -eq 3 ]]; then
        #info "Did not find start marker \"${start_marker}\" in \"${target_file}\"; nothing to remove."
        rm -f "$tmp_file"
        return 0
    elif [[ $awk_status -ne 0 ]]; then
        info "Failed to process ${target_file} for reset (awk status ${awk_status})."
        rm -f "$tmp_file"
        return 1
    fi

    if ! mv "$tmp_file" "$target_file"; then
        info "Failed to copy over temporary file ${tmp_file} to target file ${target_file}."
        rm -f "$tmp_file"
        return 1
    fi

    rm -f "$tmp_file"
    return 0
}

prepare_temp_file_block () {
    local target_file="$1"
    local start_marker="$2"
    local end_marker="$3"

    local file_name="${target_file##*/}"
    local temp_file="${target_file}.tmp"

    if [[ -f "${temp_file}" ]]; then
        info "There is already a temporary ${file_name} file ${temp_file} from a previous setup."
        prompt_yn "Do you want to delete it and continue with the setup?"
        if [[ "$YN" == "y" || "$YN" == "yes" ]]; then
            info "Okay, removing temporary file."
            rm -f "${temp_file}"
        else
            prompt_yn "Would you like to restore it?"
            if [[ "$YN" == "y" || "$YN" == "yes" ]]; then
                mv "${temp_file}" "${target_file}"
                info "Restored ${target_file} from ${temp_file}."
            else
                error "Please check and remove ${temp_file} manually before proceeding with giz installation/reinstallation."
            fi
        fi
    fi
    if [[ ! -e "$temp_file" ]]; then
        info "Creating ${temp_file} (it did not exist)."
        touch "$temp_file" || { error "Failed to create ${temp_file}"; }
    fi
    cp "$target_file" "$temp_file" > /dev/null || { error "Failed to create temporary copy of ${file_name} file."; }
    remove_block_between_markers "$temp_file" "$start_marker" "$end_marker" || exit 1
}

merge_block_back_in_temp_file () {
    local target_file="$1"
    local start_marker="$2"
    local end_marker="$3"

    local file_name="${target_file##*/}"
    local temp_file="${target_file}.tmp"

    if ! cmp -s "$target_file" "$temp_file"; then
        info "Proposed changes to ${target_file}:"
        diff --color -u "$target_file" "$temp_file"
        prompt_yn "Should I make the above changes to your ${file_name}?"
        if [[ "$YN" == "y" || "$YN" == "yes" ]]; then
            mv -v "$temp_file" "$target_file" > /dev/null 
        else
            prompt_yn "Okay, I will abort your ${file_name} changes and end the program. Should I keep a backup of the proposed changes for you to look at?"
            if [[ "$YN" == "y" || "$YN" == "yes" ]]; then
                info "Keeping proposed changes at ${temp_file}."
            else
                rm -f "${temp_file}" # remove temp file
            fi
            exit 0
        fi
    else
        info "No changes were made to your ${file_name}."
        rm -f "${temp_file}"
    fi
}


# ------------------------
# Default parameters
# ------------------------
# global constants 
GIZ_VARIABLES_STRING="# >>> Added by GIZ >>>"
GIZ_VARIABLES_ENDSTRING="# <<< Added by GIZ <<<"
BASHRC_FILE="${HOME}/.bashrc"

# override with flags or .giz_params file
RUN_DIR=${PWD}              # set with -d flag
CONFIG_FILE="Config.sh"     # set with --config-name flag
PARAM_FILE="params.txt"     # set with --param-name flag
EXEC_FILE="GIZMO"           # set with --exec-name flag
CODE_DIRNAME="code"

SKIP_MAKE=false             # set to true with -s flag
RESTART=0                   # set to 1 with -r flag

THREADS_PER_PROCESS=1       # set with -T flag (aka number of cpu threads per MPI task/process, depends on CPU architecture)
NNODES=0                    # set with -N flag (0 = no slurm queue, 1+ = 1+ slurm node(s))
NPROCESSES=0                # set with -n flag (aka number of MPI tasks/processes, irrelevant if NNODES!=0)
NPROCESSES_PER_NODE=1
JOB_TIME="2-00:00:00"       # set with -t flag (D-HH:MM:SS, irrelevant if NNODES!=0)
JOB_NAME="gizmo"            # set with -j flag (irrelevant if NNODES!=0)
JOB_NAME_SET=false          # flags if -j was set (if false, overrides with directory name)
PARTITION_NAME="normal"     # set with -p flag

TEMPLATE_CONFIG_FILE="" #"Template_Config.sh"
TEMPLATE_PARAMS_FILE=""

# ----------------------------
# Override predefined variables with system defaults if available
# ----------------------------
touch "${BASHRC_FILE}" # make sure bashrc exists
source "${BASHRC_FILE}" # load in e.g. jaba or giz variables if available

GIZMO_SYSTYPE=${GIZMO_SYSTYPE:-""}                                   # set according to your system type e.g. Frontera or MacBookPro (see Makefile.systype in GIZMO docs)
GIZMO_MODULE_LOAD_COMMAND_LIST=${GIZMO_MODULE_LOAD_COMMAND_LIST:-""} # adjust these modules according to your system (this is irrelevant for systems with no modules)
GIZMO_SOURCE=${GIZMO_SOURCE:-""}                                     # set if you have a preinstalled GIZMO version you would like to use over public or private repos
GIZMO_DEFAULT_ACCOUNT_NAME=${GIZMO_DEFAULT_ACCOUNT_NAME:-""}         # override with -A flag, or set default with GIZMO_DEFAULT_ACCOUNT_NAME if exists (if not, it tries to submit without specifying allocation)

# strictly local variables
SETUP_INSTEAD=0
TAR_INSTEAD=0 
CLEAN_INSTEAD=0

# ----------------------------
# Parse arguments
# ----------------------------

print_help() {
    more <<EOF
GIZ: One GIZMO Command To Rule Them All.

Usage: giz [options]

Basic functionality:
  1. (if relevant) Copies over, untars or clones GIZMO source code
  2. Specify a configuration file (-s to skip this)
  3. Compile GIZMO (-s to skip this)
  4. Specify a runtime parameter file
  5. Runs the GIZMO executable locally (-r for restarts)

File structure:
          run directory (-d)
         /         |       \\
       code   params.txt   output
      /    \                   
GIZMO     Config.sh

Options:
  -s, --skip-make                     Skip compilation
  -r, --restart                       Run from restart files
  -d DIR                              Specify run directory (default: current directory)
  --config-name FILE                  Specify configuration filename (default: Config.sh)
  --exec-name FILE                    Specify executable filename (default: GIZMO)
  --param-name FILE                   Specify parameter filename (default: params.txt)
  -T, --threads-per-process NUMBER    Specify number of threads per process (default: 1)
  -N, --num-nodes NUMBER              Specify number of nodes to run on (default: 0 = no slurm queue)
  -n, --num-processes NUMBER          Specify number of processes run (default: 1, only relevant if N != 0)
  -t, --time TIME                     Specify time for the slurm job to run (default: 2-00:00:00, only relevant if N != 0)
  -j, --job-name STRING               Specify name for the slurm job (default: gizmo_job, only relevant if N != 0)
  -p, --partition-name STRING         Specify partition name for slurm queue
  -A, --allocation-name STRING        Specify allocation name for slurm queue
  -h, --help                          Show this help message

Examples:
  giz --config-name "Config_alt.sh" --exec-name "GIZMO_alt" --param-name "params_alt.txt"  # run GIZMO locally with alternative config, executable and parameter filenames 
  giz -N 1 -n 8 -T 7 -t "12:00:00"                           # queue GIZMO run on 1 node, 8 mpi processes, 7 threads per process, for 12 hours
  giz -sr -N 5 -n 20 -T 2                                    # queue restart run with 20 mpi processes across 5 nodes, 2 threads per process, skipping compilation

GIZMO documentation (for Config.sh, params.txt, and SYSTYPE): 
  http://www.tapir.caltech.edu/~phopkins/Site/GIZMO_files/gizmo_documentation.html
EOF
    exit 0
}

# override with inputted flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--skip-make) SKIP_MAKE=true; shift ;;
        -r|--restart) RESTART=1; shift ;;
        -r2|--restart2) RESTART=2; shift ;;
        -sr|-rs) RESTART=1; SKIP_MAKE=true; shift ;;
        -d) RUN_DIR="$2"; shift 2 ;;
        --config-name) CONFIG_FILE="$2"; shift 2 ;;
        --exec-name) EXEC_FILE="$2"; shift 2 ;;
        --param-name) PARAM_FILE="$2"; shift 2 ;;
        -T|--threads-per-process|--cpus-per-task) THREADS_PER_PROCESS="$2"; shift 2 ;;
        -N|--num-nodes|--nodes) NNODES="$2"; shift 2 ;;
        -n|-np|--num-processes|--ntasks) NPROCESSES="$2"; shift 2 ;;
        -t|--time) JOB_TIME="$2"; shift 2 ;;
        -j|--job-name) JOB_NAME="$2"; JOB_NAME_SET=true; shift 2 ;;
        -p|--partition-name) PARTITION_NAME="$2"; shift 2 ;;
        -A|--allocation-name) GIZMO_DEFAULT_ACCOUNT_NAME="$2"; shift 2 ;;
        -h|--help) print_help ;;
        setup|install|reinstall) SETUP_INSTEAD=1; shift 1; break ;;  # setup giz
        pack|tar|zip) TAR_INSTEAD=1; shift 1; break ;;  # pack up for quick file transfer
        unpack|untar|unzip) TAR_INSTEAD=2; shift 1; break ;; # unpack from quick file transfer
        clean) [ "$2" == "all" ] && CLEAN_INSTEAD=2 || CLEAN_INSTEAD=1 ; break ;;  # giz clean: cleans run (all slurms, used params, etc. before next run); giz clean all (removes all compile and output/analysis data to return it to the ICs (will prompt first)   
        *) error "Unknown option: $1" ;;
    esac
done

# ----------------------------
# Ensure parameter validity
# ----------------------------

# move to run directory
ORIGINAL_DIR=${PWD}
mkdir -p $RUN_DIR
cd "$RUN_DIR" || error "failed to enter run directory: $RUN_DIR"
info "using ${RUN_DIR} as run directory"

# ask to setup if needed
if [[ -z "${GIZ_LOCATION:-}" ]]; then
    error "It looks like you haven't setup giz yet. Please run 'giz.sh setup' first."
fi

# need integer number of processes per node
if [[ "$NNODES" != "0" ]]; then
    if (( NPROCESSES % NNODES != 0 )); then
        error "The number of processes (${NPROCESSES}) is not a multiple of the number of nodes (${NNODES})"
    fi
    NPROCESSES_PER_NODE=$((NPROCESSES / NNODES))
fi

# ----------------------------
# Step -1: Do other things instead if asked
# ----------------------------

if [[ "$SETUP_INSTEAD" == "1" ]]; then
    # override with a setup operation.
    # TODO add macbook support

    GIZ_LOCATION="$(cd "$(dirname "$0")" && pwd)" # start in the giz directory 
    info ".... GIZ INSTALLATION ...."

    # Set GIZMO system type if jaba available otherwise prompt for it
    if [[ -z "${JABA_INFERRED_SYSTEM:-}" ]]; then
        if [[ $JABA_INFERRED_SYSTEM == "Frontera" ]]; then
            GIZMO_SYSTYPE="Frontera"
        elif [[ $JABA_INFERRED_SYSTEM == "Frontier" ]]; then
            GIZMO_SYSTYPE="Frontier-CPU" # prompt here later when kokkos branch works
        elif [[ $JABA_INFERRED_SYSTEM == "Frontier" ]]; then
            GIZMO_SYSTYPE="Frontier-CPU"
        else
            warn "JABA inferred system type \"${JABA_INFERRED_SYSTEM}\" is not yet supported by GIZ. Setting gizmo type to this same string for now..."
            GIZMO_SYSTYPE="${JABA_INFERRED_SYSTEM}"
        fi
    fi
    if [[ -z "${GIZMO_SYSTYPE:-}" ]]; then
        prompt "Please enter your GIZMO system type (e.g. Frontera, MacBookPro, Frontier-CPU, etc.)" GIZMO_SYSTYPE
    fi

    FFTW_VERSION=3 # set FFTW version (2 or 3, defaults to 3)

    info "Using GIZMO system type: ${GIZMO_SYSTYPE}"
    info "Using FFTW version ${FFTW_VERSION}"
    info "Using bashrc file at ${BASHRC_FILE}"
    info "Using giz repo location at ${GIZ_LOCATION}"
    extra_bashrc_lines=()

    #### FRONTERA ####
    if [[ "$GIZMO_SYSTYPE" == "Frontera" ]]; then
        if [[ $FFTW_VERSION == 3 ]]; then
            fftw_module="fftw3/3.3.10"
        elif [[ $FFTW_VERSION == 2 ]]; then
            fftw_module="fftw2"
        else
            error "FFTW version '${FFTW_VERSION}' not supported."
        fi
        GIZMO_MODULE_LOAD_COMMAND_LIST="module purge; module load intel/19.1.1 impi/19.0.9 gsl/2.8 hdf5/1.14.6 ${fftw_module};"
        info 'tips for GIZMO on Frontera: most nodes are 56 cores, so use n/N (processes per node) = 56/T (56 divided by number of threads per process) = whole number. for small runs use n/N=28, T=2, medium runs use n/N=14, T=4, and very large runs use n/N=7, T=8'

    #### FRONTIER - CPU ####
    elif [[ "$GIZMO_SYSTYPE" == "Frontier-CPU" ]]; then
        if [[ $FFTW_VERSION != 3 ]]; then
            error "FFTW version '${FFTW_VERSION}' not supported."
        fi
        GIZMO_MODULE_LOAD_COMMAND_LIST="module reset; module swap PrgEnv-cray PrgEnv-gnu; module load cray-hdf5 cray-fftw gsl;"
        info 'tips for GIZMO on Frontier-CPU: most nodes are 64 cores, so use n/N (processes per node) = 64/T (64 divided by number of threads per process) = whole number.'

    #### MACBOOK PRO ####
    elif [[ "$GIZMO_SYSTYPE" == "MacBookPro" ]]; then
        error "macbook implementation is not yet complete"
        
    #### IMPLEMENT ANY NEW SYSTEM SETUP ABOVE HERE ....

    else
        error "GIZMO system type '${GIZMO_SYSTYPE}' not yet supported. please write your own in giz_setup.sh"
    fi

    # make sure modules actually load
    eval "$GIZMO_MODULE_LOAD_COMMAND_LIST" || error "Could not load modules desired";
    extra_bashrc_lines+=("export GIZMO_MODULE_LOAD_COMMAND_LIST=\"${GIZMO_MODULE_LOAD_COMMAND_LIST}\"")

    if [[ -z "${GIZMO_SOURCE:-}" ]]; then
        prompt_yn "Do you want to use a preinstalled GIZMO source code directory instead of cloning the public or private repo?"
        if [[ "$YN" == "y" || "$YN" == "yes" ]]; then
            prompt "Please enter the path to your preinstalled GIZMO source code directory" GIZMO_SOURCE
            extra_bashrc_lines+=("export GIZMO_SOURCE=\"${GIZMO_SOURCE}\"")
        fi
    fi
    if [[ -z "${GIZMO_DEFAULT_ACCOUNT_NAME:-}" ]]; then
        prompt_yn "Do you want to set a default account name for slurm runs?"
        if [[ "$YN" == "y" || "$YN" == "yes" ]]; then
            prompt "Please enter the default account name for slurm runs" GIZMO_DEFAULT_ACCOUNT_NAME
            extra_bashrc_lines+=("export GIZMO_DEFAULT_ACCOUNT_NAME=\"${GIZMO_DEFAULT_ACCOUNT_NAME}\"")
        fi
    fi

    # add some more common lines
    extra_bashrc_lines+=('umask 022')
    extra_bashrc_lines+=('ulimit -s unlimited')

    # append everything to bashrc
    prepare_temp_file_block "$BASHRC_FILE" "$GIZ_VARIABLES_STRING" "$GIZ_VARIABLES_ENDSTRING" || exit 1
    {
        echo "${GIZ_VARIABLES_STRING}"
        echo "export GIZ_LOCATION=\"${GIZ_LOCATION}\""
        echo "export GIZMO_SYSTYPE=\"${GIZMO_SYSTYPE}\""
        for line in "${extra_bashrc_lines[@]}"; do
            echo "$line"
        done
        echo "alias giz=\"${GIZ_LOCATION}/giz.sh\""
        prompt_yn "Add giz developer aliases?"
        if [[ "$YN" == "y" || "$YN" == "yes" ]]; then
            echo "\n# giz developer aliases"
            echo "alias cd-giz=\"cd ${GIZ_LOCATION}\""
            echo "alias cd-gizmo=\"cd ${GIZMO_SOURCE}\""
            echo "alias pwd-giz=\"echo ${REPO_LOCATION}\""
            echo "alias pwd-gizmo=\"echo ${GIZMO_SOURCE}\""
            echo "alias edit-giz=\"vim ~/GIZMO/giz/giz.sh\""
            echo "alias giz-pull=\"(cd ${REPO_LOCATION}; git pull origin;)\"\n"
            echo "alias giz-status=\"(cd ${REPO_LOCATION}; git status;)\"\n"
	        echo "alias giz-diff=\"(cd ${REPO_LOCATION}; git diff;)\"\n"
	        echo "alias giz-commit=\"(cd ${REPO_LOCATION}; git add .; git commit;)\"\n"
            echo "alias giz-push=\"(cd ${REPO_LOCATION}; git push origin;)\"\n"
            echo "alias giz-fetch=\"(cd ${REPO_LOCATION}; git fetch origin;)\"\n"
        fi
        echo "${GIZ_VARIABLES_ENDSTRING}"
    } >> "${BASHRC_TEMP_FILE}"
    merge_block_back_in_temp_file "$BASHRC_FILE" "$GIZ_VARIABLES_STRING" "$GIZ_VARIABLES_ENDSTRING" || exit 1

    exit 0;
fi


if [[ "$TAR_INSTEAD" == "1" ]]; then
    # override with a pack operation.
    info "Instead of running GIZMO, I will pack up the directory for quick file transfer."
    [ -d "$CODE_DIRNAME" ] && ( tar -czf "${CODE_DIRNAME}.tgz" --exclude='*.o' --exclude="${EXEC_FILE}" "$CODE_DIRNAME" && rm -rf "$CODE_DIRNAME" && info "Packed ${CODE_DIRNAME} directory." || error "something went wrong :(" )
    [ -d "spcool_tables" ] && ( tar -czf "spcool_tables.tgz" "spcool_tables" && rm -rf "spcool_tables" && info "Packed cooling tables." || error "something went wrong :(" )
    info "All done the pack process, exiting now."
    exit 0; 
elif [[ "$TAR_INSTEAD" == "2" ]]; then
    # override with an unpack operation.
    info "Instead of running GIZMO, I will unpack the directory."
    [ -f "${CODE_DIRNAME}.tar.gz" ] && ( tar -xzf "${CODE_DIRNAME}.tar.gz" && rm -rf "${CODE_DIRNAME}.tar.gz" && info "Unpacked ${CODE_DIRNAME}.tar.gz" || error "something went wrong :(" );
    [ -f "${CODE_DIRNAME}.tgz" ] && ( tar -xzf "${CODE_DIRNAME}.tgz" && rm -rf "${CODE_DIRNAME}.tgz" && info "Unpacked ${CODE_DIRNAME}.tgz" || error "something went wrong :(" );
    [ -f "spcool_tables.tar.gz" ] && ( tar -xzf "spcool_tables.tar.gz" && rm -rf "spcool_tables.tar.gz" && info "Unpacked spcool_tables.tar.gz" || error "something went wrong :(" );
    [ -f "spcool_tables.tgz" ] && ( tar -xzf "spcool_tables.tgz" && rm -rf "spcool_tables.tgz" && info "Unpacked spcool_tables.tgz" || error "something went wrong :(" );
    info "All done unpack process, exiting now."
    exit 0;
fi

if [[ "$CLEAN_INSTEAD" == "1" ]]; then
    # override with basic clean operation
    info "Instead of running GIZMO, I will clean up the temporary files from last run." # TODO: eventually put this in a directory by itself and track the run state over time (via restarts and such) 
    rm -rv slurm-*.out gizmo.out gizmo.err params.txt-usedvalues;
    info "All done clean process, exiting now."
    exit 0;
# TODO clean all (== 2)
fi

# ----------------------------
# Step 0: Prepare everything for GIZMO (repeat before running gizmo in slurm)
# ----------------------------

# set job name if not set using directory name
if [[ "$JOB_NAME_SET" == "false" && "$NNODES" -gt 0 ]]; then
    JOB_NAME="gizmo_${PWD##*/}"
    info "no job name set, using '${JOB_NAME}'" 
fi

# try to load modules
if command -v module >/dev/null 2>&1; then
    info "modules system available, loading in modules ..."
    eval "$GIZMO_MODULE_LOAD_COMMAND_LIST" || error "Could not load modules desired";
else
    info "no modules system found, assuming you have already installed relevant packages."
fi

# set open mp threads 
export OMP_NUM_THREADS=${THREADS_PER_PROCESS}

# ----------------------------
# Step 1: Prepare source code
# ----------------------------

if [[ -d "$CODE_DIRNAME" ]]; then
    info "using existing ${CODE_DIRNAME} directory."
elif [[ -f "${CODE_DIRNAME}.tar" || -f  "${CODE_DIRNAME}.tgz" || -f  "${CODE_DIRNAME}.tar.gz" ]]; then
    if [[ -f "${CODE_DIRNAME}.tar" && ! -f  "${CODE_DIRNAME}.tgz" && ! -f  "${CODE_DIRNAME}.tar.gz" ]]; then
        info "extracting ${CODE_DIRNAME}.tar ..."
        tar -xf ${CODE_DIRNAME}.tar
    elif [[ ! -f "${CODE_DIRNAME}.tar" && -f  "${CODE_DIRNAME}.tgz" && ! -f  "${CODE_DIRNAME}.tar.gz" ]]; then
        info "extracting ${CODE_DIRNAME}.tgz ..."
        tar -xzf ${CODE_DIRNAME}.tgz
    elif [[ ! -f "${CODE_DIRNAME}.tar" && ! -f  "${CODE_DIRNAME}.tgz" && -f  "${CODE_DIRNAME}.tar.gz" ]]; then
        info "extracting ${CODE_DIRNAME}.tar.gz ..."
        tar -xzf ${CODE_DIRNAME}.tar.gz
    else
        error "there are multiple tarred code directories with name \"${CODE_DIRNAME}\" and it is not clear which extension to use, please rename or move the ones you don't want"
    fi
elif [[ -n "$GIZMO_SOURCE" && -d "$GIZMO_SOURCE" ]]; then
    info "copying from \$GIZMO_SOURCE=$GIZMO_SOURCE"
    cp -r "$GIZMO_SOURCE" "$CODE_DIRNAME"
else
    if [[ "$SKIP_MAKE" == true ]]; then
        error "there is no source code directory and compilation is turned off so there is no executable to run!"
    fi 
    info "no local GIZMO source found, opting to clone repo instead..."
    # clone repo
    OLD_PUBLIC_REPO="0" # note: private version is now public
    if [[ "$OLD_PUBLIC_REPO" == "1" ]]; then
        info "cloning private GIZMO repository (github)..."
        if git clone https://github.com/pfhopkins/gizmo-public.git "$CODE_DIRNAME"; then
            info "sucessfully cloned GIZMO-public from github."
        else
            warn "github clone failed, falling back to old bitbucket version ..."
            if git clone https://bitbucket.org/phopkins/gizmo-public.git "$CODE_DIRNAME"; then
                info "successfully cloned GIZMO-public from bitbucket."
            else
                error "failed to clone GIZMO-public from both github and bitbucket."
            fi
        fi
    else
        prompt "do you want to clone Jaeden's GIZMO fork (instead of the standard repo) [y/n]" REPLY;
        REPLY=${REPLY,,}  #lowercase
        if [[ "$REPLY" == "y" || "$REPLY" == "yes" ]]; then
            info "cloning Jaeden's GIZMO repository fork (github)..."
            if git clone https://github.com/JaedenBardati/gizmo.git "$CODE_DIRNAME"; then
                info "successfully cloned GIZMO from github."
            else
                error "failed to clone Jaeden's GIZMO fork from github."
            fi
        else
            info "cloning public GIZMO repository (github)..."
            if git clone https://github.com/pfhopkins/gizmo.git "$CODE_DIRNAME"; then
                info "successfully cloned GIZMO from github."
            else
                warn "github clone failed, falling back to old bitbucket version ..."
                if git clone https://bitbucket.org/phopkins/gizmo.git "$CODE_DIRNAME"; then
                    info "successfully cloned GIZMO from bitbucket."
                else
                    error "failed to clone GIZMO from both github and bitbucket."
                fi
            fi
        fi
        (cd "$CODE_DIRNAME" && git update-index --skip-worktree "Makefile.systype")
        (cd "$CODE_DIRNAME" && git branch -a)
        while true; do
            prompt "what branch would you like to use? [blank for default]" BRANCH;
            if [ -z "$(printf '%s' "$BRANCH" | tr -d '[:space:]')" ]; then
                break
            else
                (cd "$CODE_DIRNAME" && git checkout "$BRANCH") && break || warn "failed to checkout that branch, please select a valid branch among the available ones above.."
            fi
        done
    fi
    # set system type
    if [[ "$GIZMO_SYSTYPE" == "" ]]; then
        error "GIZMO_SYSTYPE is not set. Please run \"export GIZMO_SYSTYPE=YourSystemType\" with your system type prior to running or in your .bashrc file."
    fi
    echo -e "\nSYSTYPE=\"${GIZMO_SYSTYPE}\"" >> "${CODE_DIRNAME}/Makefile.systype"
    info "set system type to ${GIZMO_SYSTYPE} in ${CODE_DIRNAME}/Makefile.systype"
fi


# ----------------------------
# Step 2: Prepare config file (if not skipped)
# ----------------------------
if [[ "$SKIP_MAKE" == false ]]; then
    if [[ ! -f "${CODE_DIRNAME}/$CONFIG_FILE" ]]; then
        if [[ -f "${CODE_DIRNAME}/${TEMPLATE_CONFIG_FILE}" ]]; then
            info "making new config file ${CONFIG_FILE} based on ${CODE_DIRNAME}/${TEMPLATE_CONFIG_FILE} ..."
            cp "${CODE_DIRNAME}/${TEMPLATE_CONFIG_FILE}" "${CODE_DIRNAME}/Config.sh"
        else
            warn "no ${TEMPLATE_CONFIG_FILE} template found in code directory \"${CODE_DIRNAME}\", making blank $CONFIG_FILE ..."
            touch "${CODE_DIRNAME}/$CONFIG_FILE"
        fi
    else
        info "opening existing config file ${CODE_DIRNAME}/${CONFIG_FILE} ..."
    fi

    vim "${CODE_DIRNAME}/$CONFIG_FILE"
fi

# move TREECOOL over and get spcool tables (should really depend on config)
if [[ ! -f "${RUN_DIR}/TREECOOL" ]]; then
    info "getting TREECOOL..."
    grep -v '^##' "${CODE_DIRNAME}/cooling/TREECOOL" > "${RUN_DIR}/TREECOOL"
fi
if [[ ! -d "${RUN_DIR}/spcool_tables" ]]; then
    info "getting spcool tables..."
    cd "$RUN_DIR"
    wget -qO- http://www.tapir.caltech.edu/~phopkins/public/spcool_tables.tgz | gunzip | tar xf -
fi

# ensure that there is an output directory (todo: ensure this is the same as what is later entered in params.txt)
OUTPUT_DIR_NAME="output/"
mkdir -p "${RUN_DIR}/${OUTPUT_DIR_NAME}"

# ----------------------------
# Step 3: Compile (if not skipped)
# ----------------------------
if [[ "$SKIP_MAKE" == false ]]; then
    cd "$CODE_DIRNAME"
    
    # try to auto-detect gsl location
    if [[ -z "${GSL_HOME}" ]]; then
        if [[ -n "${GSL_DIR}" ]]; then
            export GSL_HOME="${GSL_DIR}"
        elif [[ -n "${TACC_GSL_DIR}" ]]; then
            export GSL_HOME="${TACC_GSL_DIR}"
        elif [[ -d "/opt/apps/gsl" ]]; then
            # fallback heuristic
            export GSL_HOME=$(ls -d /opt/apps/gsl/* | head -n 1)
        else
            echo "[warn] could not auto-detect gsl installation; set GSL_HOME manually"
        fi
    fi

    # compile
    info "compiling ${EXEC_FILE} ..."
    make -j$(nproc) CONFIG="$CONFIG_FILE" EXEC="$EXEC_FILE" || error "compilation failed; current directory: $(pwd) ; command: make -j$(nproc) CONFIG=\"${CONFIG_FILE}\" EXEC=\"${EXEC_FILE}\""
    info "compilation successful."

    cd "$RUN_DIR"
else
    info "skipping compilation ..."
fi


# ----------------------------
# Step 4: Prepare parameter file
# ----------------------------
if [[ ! -f "$PARAM_FILE" ]]; then
    if [[ -f "$CODE_DIRNAME/params_example.txt" ]]; then
        info "making new parameter file $PARAM_FILE from ${TEMPLATE_PARAMS_FILE}"
        cp "$CODE_DIRNAME/${TEMPLATE_PARAMS_FILE}" "$PARAM_FILE"
    else
        warn "No ${TEMPLATE_PARAMS_FILE} template found; making blank $PARAM_FILE"
        touch "$PARAM_FILE"
    fi
else
    info "found existing $PARAM_FILE"
fi

vim "$PARAM_FILE"


# ----------------------------
# Step 5: Run GIZMO
# ----------------------------
EXEC_PATH="$RUN_DIR/$CODE_DIRNAME/$EXEC_FILE"
if [[ ! -x "$EXEC_PATH" ]]; then
    error "GIZMO executable not found: $EXEC_PATH"
fi

# find the right mpi launcher
SLURM_PRERUN_EXEC=""
if command -v ibrun >/dev/null 2>&1; then
    info "using ibrun for mpi launch"
    LAUNCHER="ibrun"
    SLURM_PRERUN_EXEC='export IBRUN_QUIET=1'$'\n'
    NON_SLURM_LAUNCH_ARGS=" -n ${NPROCESSES}"
elif command -v aprun >/dev/null 2>&1; then
    info "using aprun for mpi launch"
    LAUNCHER="aprun"
    NON_SLURM_LAUNCH_ARGS=" -n ${NPROCESSES}"
elif command -v srun >/dev/null 2>&1; then
    info "using srun for mpi launch"
    LAUNCHER="srun"
    NON_SLURM_LAUNCH_ARGS=" -n ${NPROCESSES}"
elif command -v mpirun >/dev/null 2>&1; then
    info "using mpirun for mpi launch"
    LAUNCHER="mpirun"
    NON_SLURM_LAUNCH_ARGS=" -np ${NPROCESSES}"
else
    error "no mpi launcher found (ibrun/aprun/srun/mpirun)"
fi

# either submit a slurm batch or run directly
if [[ "$NNODES" -gt 0 ]]; then
    BATCH_FILE="submit.sh" #"submit_${JOB_NAME}.sh"
    info "making slurm batch script ${BATCH_FILE} ..."

    echo "#!/bin/bash" > "$BATCH_FILE" 
    if [ -n "$GIZMO_DEFAULT_ACCOUNT_NAME" ]; then
        echo "#SBATCH --account=$GIZMO_DEFAULT_ACCOUNT_NAME" >> "$BATCH_FILE"
    fi
    cat >> "$BATCH_FILE" <<EOF
#SBATCH --partition=${PARTITION_NAME}
#SBATCH --job-name=${JOB_NAME}
#SBATCH --nodes=${NNODES}
#SBATCH --ntasks-per-node=${NPROCESSES_PER_NODE}
#SBATCH --time=${JOB_TIME}

source "${BASHRC_FILE}"
cd "${RUN_DIR}"

${GIZMO_MODULE_LOAD_COMMAND_LIST}

export OMP_NUM_THREADS=${THREADS_PER_PROCESS}
${SLURM_PRERUN_EXEC}
echo "${LAUNCHER} $EXEC_PATH $PARAM_FILE $RESTART"
${LAUNCHER} "$EXEC_PATH" "$PARAM_FILE" "$RESTART" 1>gizmo.out 2>gizmo.err

echo "Job ended."
sacct -j \$SLURM_JOBID --format=JobID,JobName,Partition,MaxRSS,Elapsed,ExitCode
exit
EOF
    cd ${ORIGINAL_DIR}
    prompt "do you want to submit the slurm script now? [y/n]" REPLY;
    REPLY=${REPLY,,}  #lowercase
    if [[ "$REPLY" == "y" || "$REPLY" == "yes" ]]; then
        info "submitting slurm batch script..."
        sbatch "${RUN_DIR}/${BATCH_FILE}"
    else
        info "skipping the batch submit..."
        info "you can submit later with: \"sbatch ${RUN_DIR}/${BATCH_FILE}\""
        info "In Frontera, you can submit a test with: \"sbatch -p "development" -N 1 -t "1:00:00" ${RUN_DIR}/${BATCH_FILE}\"" # todo see if frontera to get msg
    fi
else
    # actually run locally
    info "running GIZMO..."
    echo "${LAUNCHER}${NON_SLURM_LAUNCH_ARGS} $EXEC_PATH $PARAM_FILE $RESTART"
    ${LAUNCHER}${NON_SLURM_LAUNCH_ARGS} "$EXEC_PATH" "$PARAM_FILE" "$RESTART" 1>gizmo.out 2>gizmo.err #1>${JOB_NAME}.out 2>${JOB_NAME}.err
fi

info "done"
