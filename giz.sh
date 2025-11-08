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
#            -- using the -r flag is for running from restart files (sets the GIZMO restart flag to 1)
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

# ------------------------
# Default parameters
# ------------------------
# override with flags
RUN_DIR=${PWD}              # set with -d flag
CONFIG_FILE="Config.sh"     # set with --config-name flag
PARAM_FILE="params.txt"     # set with --param-name flag
EXEC_FILE="GIZMO"           # set with --exec-name flag

SKIP_MAKE=false             # set to true with -s flag
RESTART=0                   # set to 1 with -r flag

THREADS_PER_PROCESS=1       # set with -T flag (aka number of cpu threads per MPI task/process, depends on CPU architecture)
NNODES=0                    # set with -N flag (0 = no slurm queue, 1+ = 1+ slurm node(s))
NPROCESSES_PER_NODE=1       # set with -n flag (aka number of MPI tasks/processes, irrelevant if NNODES!=0)
JOB_TIME="2-00:00:00"       # set with -t flag (D-HH:MM:SS, irrelevant if NNODES!=0)
JOB_NAME="gizmo"            # set with -j flag (irrelevant if NNODES!=0)
JOB_NAME_SET=false          # flags if -j was set
PARTITION_NAME="normal"     # set with -p flag
ALLOCATION_NAME=${GIZMO_DEFAULT_ACCOUNT_NAME:-""}   # override with -A flag, or set default with GIZMO_DEFAULT_ACCOUNT_NAME if exists (if not, it tries to submit without specifying allocation)

# override with predefined variables if needed (e.g. export variabled in your .bashrc or .bash_profile)
GIZMO_SYSTYPE=${GIZMO_SYSTYPE:-""}                            # set according to your system type e.g. Frontera or MacBookPro (see Makefile.systype in GIZMO docs)
GIZMO_SOURCE=${GIZMO_SOURCE:-""}                              # set if you have a preinstalled GIZMO version you would like to use over public or private repos
MODULE_LIST=${GIZMO_MODULE_LIST:-"intel impi gsl hdf5 fftw3"} # adjust these modules according to your system (this is irrelevant for systems with no modules)
EDITOR=${GIZMO_EDITOR:-"vim"}                                 # use your favorite editor (e.g. "emacs", "nano", "open", etc.)
CODE_DIR=${GIZMO_CODE_DIR:-"code"}
TEMPLATE_CONFIG_FILE=${GIZMO_TEMPLATE_CONFIG_FILE:-"Template_Config.sh"}
TEMPLATE_PARAMS_FILE=${GIZMO_TEMPLATE_PARAMS_FILE:-"Template_params.txt"}

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

Predefined variables (set the following variables before running or export in .bashrc or .bash_profile):
  GIZMO_SYSTYPE                If cloning GIZMO, must set this to your GIZMO system type (e.g. "Frontera" or "MacBookPro", see Makefile.systype, NO DEFAULT!)
  GIZMO_MODULE_LIST            If your system supports module loading, set this to the list of modules to load (default: "intel impi gsl hdf5 fftw3")
  GIZMO_SOURCE                 Optionally set this to a preexisting GIZMO source code directory to copy from (e.g. if you are using a custom GIZMO install)
  GIZMO_EDITOR                 Optionally set this to your preferred file editor for config and parameter files (default: "vim", e.g. "emacs", "nano", "open")
  GIZMO_CODE_DIR               Optionally set the name of the local copy of source code subdirectory (default: code)
  GIZMO_TEMPLATE_CONFIG_FILE   Optionally set the name of the template config file to copy from if available (default: Template_Config.sh)
  GIZMO_TEMPLATE_PARAMS_FILE   Optionally set the name of the template parameter file to copy from if available (default: Template_params.txt)
  GIZMO_DEFAULT_ACCOUNT_NAME   Optionally set the default account (allocation) to be charged for slurm queue

GIZMO documentation (for Config.sh, params.txt, and SYSTYPE): 
  http://www.tapir.caltech.edu/~phopkins/Site/GIZMO_files/gizmo_documentation.html
EOF
    exit 0
}

info()  { echo -e "[\033[1;34mINFO\033[0m] $*"; }
warn()  { echo -e "[\033[1;33mWARN\033[0m] $*"; }
error() { echo -e "[\033[1;31mERROR\033[0m] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--skip-make) SKIP_MAKE=true; shift ;;
        -r|--restart) RESTART=1; shift ;;
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
        -A|--allocation-name) ALLOCATION_NAME="$2"; shift 2 ;;
        -h|--help) print_help ;;
        *) error "Unknown option: $1" ;;
    esac
done

if (( NPROCESSES % NNODES != 0 )); then
    error "The number of processes (${NPROCESSES}) is not a multiple of the number of nodes (${NNODES})"
fi
NPROCESSES_PER_NODE=$((NPROCESSES / NNODES))


# ----------------------------
# Step 0: Prepare everything (likely repeat before running gizmo in slurm)
# ----------------------------

# move to run directory
ORIGINAL_DIR=${PWD}
mkdir -p $RUN_DIR
cd "$RUN_DIR" || error "failed to enter run directory: $RUN_DIR"
info "using ${RUN_DIR} as run directory"

# set job name if not set using directory name
if [[ "$JOB_NAME_SET" == "false" && "$NNODES" -gt 0 ]]; then
    JOB_NAME="gizmo_${PWD##*/}"
    info "no job name set, using '${JOB_NAME}'" 
fi

# source bashrc or bash_profile if they exist
if [[ -f "${HOME}/.bashrc" ]]; then
    source "${HOME}/.bashrc"
fi
if [[ -f "${HOME}/.bash_profile" ]]; then
    source "${HOME}/.bash_profile"
fi

# try to load modules
if command -v module >/dev/null 2>&1; then
    info "modules system available, loading in modules \"${MODULE_LIST}\" ..."
    module purge
    module load $MODULE_LIST
else
    info "no modules system found, assuming you have already installed relevant packages."
fi

# set open mp threads 
export OMP_NUM_THREADS=${THREADS_PER_PROCESS}

# ----------------------------
# Step 1: Prepare source code
# ----------------------------

if [[ -d "$CODE_DIR" ]]; then
    info "using existing ${CODE_DIR} directory."
elif [[ -f "${CODE_DIR}.tar" || -f  "${CODE_DIR}.tgz" || -f  "${CODE_DIR}.tar.gz" ]]; then
    if [[ -f "${CODE_DIR}.tar" && ! -f  "${CODE_DIR}.tgz" && ! -f  "${CODE_DIR}.tar.gz" ]]; then
        info "extracting ${CODE_DIR}.tar ..."
        tar -xf ${CODE_DIR}.tar
    elif [[ ! -f "${CODE_DIR}.tar" && -f  "${CODE_DIR}.tgz" && ! -f  "${CODE_DIR}.tar.gz" ]]; then
        info "extracting ${CODE_DIR}.tgz ..."
        tar -xzf ${CODE_DIR}.tgz
    elif [[ ! -f "${CODE_DIR}.tar" && ! -f  "${CODE_DIR}.tgz" && -f  "${CODE_DIR}.tar.gz" ]]; then
        info "extracting ${CODE_DIR}.tar.gz ..."
        tar -xzf ${CODE_DIR}.tar.gz
    else
        error "there are multiple tarred code directories with name \"${CODE_DIR}\" and it is not clear which extension to use, please rename or move the ones you don't want"
    fi
elif [[ -n "$GIZMO_SOURCE" && -d "$GIZMO_SOURCE" ]]; then
    info "copying from \$GIZMO_SOURCE=$GIZMO_SOURCE"
    cp -r "$GIZMO_SOURCE" "$CODE_DIR"
else
    if [[ "$SKIP_MAKE" == true ]]; then
        error "there is no source code directory and compilation is turned off so there is no executable to run!"
    fi 
    info "no local GIZMO source found, opting to clone repo instead..."
    # clone repo
    read -p "do you want to clone the private GIZMO repository instead of the public one? [y/n]: " REPLY
    REPLY=${REPLY,,}  #lowercase
    if [[ "$REPLY" == "y" || "$REPLY" == "yes" ]]; then
        info "cloning private GIZMO repository (bitbucket)..."
        git clone https://bitbucket.org/phopkins/gizmo.git "$CODE_DIR"
    else
        info "cloning public GIZMO repository (bitbucket)..."
        if git clone https://bitbucket.org/phopkins/gizmo-public.git "$CODE_DIR"; then
            info "successfully cloned GIZMO from bitbucket."
        else
            warn "bitbucket clone failed, falling back to github ..."
            if git clone https://github.com/pfhopkins/gizmo-public.git "$CODE_DIR"; then
                info "successfully cloned GIZMO from github."
            else
                error "failed to clone from both bitbucket and github."
            fi
        fi
    fi
    # set system type
    if [[ "$GIZMO_SYSTYPE" == "" ]]; then
        error "GIZMO_SYSTYPE is not set. Please run \"export GIZMO_SYSTYPE=YourSystemType\" with your system type prior to running or in your .bashrc or .bash_profile file."
    fi
    echo -e "\nSYSTYPE=\"${GIZMO_SYSTYPE}\"" >> "${CODE_DIR}/Makefile.systype"
    info "set system type to ${GIZMO_SYSTYPE} in ${CODE_DIR}/Makefile.systype"
fi


# ----------------------------
# Step 2: Prepare config file (if not skipped)
# ----------------------------
if [[ "$SKIP_MAKE" == false ]]; then
    if [[ ! -f "${CODE_DIR}/$CONFIG_FILE" ]]; then
        if [[ -f "${CODE_DIR}/${TEMPLATE_CONFIG_FILE}" ]]; then
            info "making new config file ${CONFIG_FILE} based on ${CODE_DIR}/${TEMPLATE_CONFIG_FILE} ..."
            cp "${CODE_DIR}/${TEMPLATE_CONFIG_FILE}" "${RUN_DIR}/Config.sh"
        else
            warn "no ${TEMPLATE_CONFIG_FILE} template found in code directory \"${CODE_DIR}\", making blank $CONFIG_FILE ..."
            touch "${CODE_DIR}/$CONFIG_FILE"
        fi
    else
        info "opening existing config file ${CODE_DIR}/${CONFIG_FILE} ..."
    fi

    $EDITOR "${CODE_DIR}/$CONFIG_FILE"
fi

# move TREECOOL over and get spcool tables (should really depend on config)
if [[ ! -f "${RUN_DIR}/TREECOOL" ]]; then
    info "getting TREECOOL..."
    grep -v '^##' "${CODE_DIR}/cooling/TREECOOL" > "${RUN_DIR}/TREECOOL"
fi
if [[ ! -d "${RUN_DIR}/spcool_tables" ]]; then
    info "getting spcool tables..."
    cd "$RUN_DIR"
    wget -qO- http://www.tapir.caltech.edu/~phopkins/public/spcool_tables.tgz | gunzip | tar xf -
fi

# ----------------------------
# Step 3: Compile (if not skipped)
# ----------------------------
if [[ "$SKIP_MAKE" == false ]]; then
    cd "$CODE_DIR"
    
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
    make -j$(nproc) CONFIG="$CONFIG_FILE" EXEC="$EXEC_FILE" || error "compilation failed."
    info "compilation successful."

    cd "$RUN_DIR"
else
    info "skipping compilation ..."
fi


# ----------------------------
# Step 4: Prepare parameter file
# ----------------------------
if [[ ! -f "$PARAM_FILE" ]]; then
    if [[ -f "$CODE_DIR/params_example.txt" ]]; then
        info "making new parameter file $PARAM_FILE from ${TEMPLATE_PARAMS_FILE}"
        cp "$CODE_DIR/${TEMPLATE_PARAMS_FILE}" "$PARAM_FILE"
    else
        warn "No ${TEMPLATE_PARAMS_FILE} template found; making blank $PARAM_FILE"
        touch "$PARAM_FILE"
    fi
else
    info "found existing $PARAM_FILE"
fi

$EDITOR "$PARAM_FILE"


# ----------------------------
# Step 5: Run GIZMO
# ----------------------------
EXEC_PATH="$RUN_DIR/$CODE_DIR/$EXEC_FILE"
if [[ ! -x "$EXEC_PATH" ]]; then
    error "GIZMO executable not found: $EXEC_PATH"
fi

# find the right mpi launcher
if command -v ibrun >/dev/null 2>&1; then
    info "using ibrun for mpi launch"
    LAUNCHER="ibrun"
    LAUNCH_ARGS="-n ${NPROCESSES_PER_NODE}"
elif command -v aprun >/dev/null 2>&1; then
    info "using aprun for mpi launch"
    LAUNCHER="aprun"
    LAUNCH_ARGS="-n ${NPROCESSES_PER_NODE}"
elif command -v srun >/dev/null 2>&1; then
    info "using srun for mpi launch"
    LAUNCHER="srun"
    LAUNCH_ARGS="-n ${NPROCESSES_PER_NODE}"
elif command -v mpirun >/dev/null 2>&1; then
    info "using mpirun for mpi launch"
    LAUNCHER="mpirun"
    LAUNCH_ARGS="-np ${NPROCESSES_PER_NODE}"
else
    error "no mpi launcher found (ibrun/aprun/srun/mpirun)"
fi

# either submit a slurm batch or run directly
if [[ "$NNODES" -gt 0 ]]; then
    BATCH_FILE="submit_${JOB_NAME}.sh"
    info "making slurm batch script ${BATCH_FILE} ..."

    echo "#!/bin/bash" > "$BATCH_FILE" 
    if [ -n "$ALLOCATION_NAME" ]; then
        echo "#SBATCH --account=$ALLOCATION_NAME" >> "$BATCH_FILE"
    fi
    cat >> "$BATCH_FILE" <<EOF
#SBATCH --partition=${PARTITION_NAME}
#SBATCH --job-name=${JOB_NAME}
#SBATCH --nodes=${NNODES}
#SBATCH --ntasks-per-node=${NPROCESSES_PER_NODE}
#SBATCH --time=${JOB_TIME}

module purge
module load ${MODULE_LIST}

cd "${RUN_DIR}"
source "${HOME}/.bashrc"

export OMP_NUM_THREADS=${THREADS_PER_PROCESS}
export IBRUN_QUIET=1

echo "$LAUNCHER $LAUNCH_ARGS $EXEC_PATH $PARAM_FILE $RESTART"
$LAUNCHER $LAUNCH_ARGS "$EXEC_PATH" "$PARAM_FILE" "$RESTART" 1>${JOB_NAME}.out 2>${JOB_NAME}.err

echo "Job ended."
sacct -j \$SLURM_JOBID --format=JobID,JobName,Partition,MaxRSS,Elapsed,ExitCode
exit
EOF
    cd ${ORIGINAL_DIR}
    read -p "do you want to submit the slurm script now? [y/n]: " REPLY
    REPLY=${REPLY,,}  #lowercase
    if [[ "$REPLY" == "y" || "$REPLY" == "yes" ]]; then
        info "submitting slurm batch script..."
        sbatch "${RUN_DIR}/${BATCH_FILE}"
    else
        info "skipping the batch submit..."
        info "you can submit later with: \"sbatch ${RUN_DIR}/${BATCH_FILE}\""
        info "you likely can submit a test with: \"sbatch -p "development" -n 1 -t "1:00:00" ${RUN_DIR}/${BATCH_FILE}\"" # todo see if frontera to get msg
    fi
else
    # actually run locally
    info "running GIZMO..."
    echo "$LAUNCHER $LAUNCH_ARGS $EXEC_PATH $PARAM_FILE $RESTART"
    $LAUNCHER $LAUNCH_ARGS "$EXEC_PATH" "$PARAM_FILE" "$RESTART" 1>${JOB_NAME}.out 2>${JOB_NAME}.err
fi

info "done"
