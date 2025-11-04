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
#            -- reads a preexisting local "code" directory, untars "code.tar", copies source code from ${GIZMO_SOURCE}, or clones the public/private repo
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
#             run directory (-d)
#          /         |           \
#        code   params.txt (-p)   output
#       /    \                   
# GIZMO (-g)  Config.sh (-c)
#
# Example Usage:
#    giz                               # standard call (called in GIZMO run directory)
#    giz -s                            # skips compilation phase (only adjusts parameter file and runs GIZMO)
#    giz -r                            # when running from restart files (sets GIZMO flag for restart files)
#    giz -d path/to/run/directory      # uses the inputted path to the run directory
#    giz -c "Config_alt.sh"            # uses an alternative filename for Config.sh (otherwise the same)
#    giz -g "GIZMO_alt"                # uses an alternative filename for GIZMO executable (otherwise the same)
#    giz -p "params_alt.txt"           # uses an alternative filename for params.txt parameter file (otherwise the same)
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


set -e  # exit immediately on error

# ------------------------
# Default parameters
# ------------------------
# override with flags
RUN_DIR=${PWD}              # set with -d flag
CONFIG_FILE="Config.sh"     # set with -c flag
PARAM_FILE="params.txt"     # set with -p flag
EXEC_FILE="GIZMO"           # set with -g flag

SKIP_MAKE=false             # set to true with -s flag
RESTART=0                   # set to 1 with -r flag

THREADS_PER_PROCESS=1       # set with -T flag (aka number of cpu threads per MPI task/process, depends on CPU architecture)
NNODES=0                    # set with -N flag (0 = no slurm queue, 1+ = 1+ slurm node(s))
NPROCESSES=1                # set with -n flag (aka number of MPI tasks/processes, irrelevant if NNODES!=0)
JOB_TIME="2-00:00:00"       # set with -t flag (D-HH:MM:SS, irrelevant if NNODES!=0)
JOB_NAME="gizmo"        # set with -j flag (irrelevant if NNODES!=0)
JOB_NAME_SET=false          # flags if -j was set

# override with predefined variables if needed (e.g. export variabled in your .bashrc or .bash_profile)
GIZMO_SYSTYPE=${GIZMO_SYSTYPE:-""}                            # set according to your system type e.g. Frontera or MacBookPro (see Makefile.systype in GIZMO docs)
GIZMO_SOURCE=${GIZMO_SOURCE:-""}                              # set if you have a preinstalled GIZMO version you would like to use over public or private repos
MODULE_LIST=${GIZMO_MODULE_LIST:-"intel impi gsl hdf5 fftw3"} # adjust these modules according to your system (this is irrelevant for systems with no modules)
EDITOR=${GIZMO_EDITOR:-"vim"}                                 # use your favorite editor (e.g. "emacs", "nano", "open", etc.)
CODE_DIR=${GIZMO_CODE_DIR:-"code"}
CODE_TAR=${GIZMO_CODE_TAR:-"${CODE_DIR}.tar"}
TEMPLATE_CONFIG_FILE=${GIZMO_TEMPLATE_CONFIG_FILE:-"Template_Config.sh"}
TEMPLATE_PARAMS_FILE=${GIZMO_TEMPLATE_PARAMS_FILE:-"Template_params.txt"}

# ----------------------------
# Parse arguments
# ----------------------------
print_help() {
    less <<EOF
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
         /         |           \\
       code   params.txt (-p)   output
      /    \                   
GIZMO (-g)  Config.sh (-c)

Options:
  -s, --skip-make                     Skip compilation
  -r, --restart                       Run from restart files
  -d DIR                              Specify run directory (default: current directory)
  -c FILE                             Specify configuration filename (default: Config.sh)
  -g FILE                             Specify executable filename (default: GIZMO)
  -p FILE                             Specify parameter filename (default: params.txt)
  -T, --threads-per-process NUMBER    Specify number of threads per process (default: 1)
  -N, --num-nodes NUMBER              Specify number of nodes to run on (default: 0 = no slurm queue)
  -n, --num-processes NUMBER          Specify number of processes run (default: 1, only relevant if N != 0)
  -t, --time TIME                     Specify time for the slurm job to run (default: 2-00:00:00, only relevant if N != 0)
  -j, --job-name STRING               Specify name for the slurm job (default: gizmo_job, only relevant if N != 0)
  -h, --help                          Show this help message

Examples:
  giz -c "Config_alt.sh" -g "GIZMO_alt" -p "params_alt.txt"  # run GIZMO locally with alternative config, executable and parameter filenames 
  giz -N 1 -n 8 -T 7 -t "12:00:00"                           # queue GIZMO run on 1 node, 8 mpi processes, 7 threads per process, for 12 hours
  giz -sr -N 5 -n 20                                         # queue restart run with 20 mpi processes across 5 nodes, skipping compilation

Predefined variables (set the following variables before running or export in .bashrc or .bash_profile):
  GIZMO_SYSTYPE                If cloning GIZMO, must set this to your GIZMO system type (e.g. "Frontera" or "MacBookPro", see Makefile.systype, NO DEFAULT!)
  GIZMO_MODULE_LIST            If your system supports module loading, set this to the list of modules to load (default: "intel impi gsl hdf5 fftw3")
  GIZMO_SOURCE                 Optionally set this to a preexisting GIZMO source code directory to copy from (e.g. if you are using a custom GIZMO install)
  GIZMO_EDITOR                 Optionally set this to your preferred file editor for config and parameter files (default: "vim", e.g. "emacs", "nano", "open")
  GIZMO_CODE_DIR               Optionally set the name of the local copy of source code subdirectory (default: code)
  GIZMO_CODE_TAR               Optionally set the name of the local tar of source code subdirectory (default: code.tar)
  GIZMO_TEMPLATE_CONFIG_FILE   Optionally set the name of the template config file to copy from if available (default: Template_Config.sh)
  GIZMO_TEMPLATE_PARAMS_FILE   Optionally set the name of the template parameter file to copy from if available (default: Template_params.txt)

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
        -c) CONFIG_FILE="$2"; shift 2 ;;
        -g) EXEC_FILE="$2"; shift 2 ;;
        -p) PARAM_FILE="$2"; shift 2 ;;
        -T|--threads-per-process|--cpus-per-task) THREADS_PER_PROCESS="$2"; shift 2 ;;
        -N|--num-nodes|--nodes) NNODES="$2"; shift 2 ;;
        -n|-np|--num-processes|--ntasks) NPROCESSES="$2"; shift 2 ;;
        -t|--time) JOB_TIME="$2"; shift 2 ;;
        -j|--job-name) JOB_NAME="$2"; JOB_NAME_SET=true; shift 2 ;;
        -h|--help) print_help ;;
        *) error "Unknown option: $1" ;;
    esac
done

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
<<<<<<< HEAD
if [[ -f "${HOME}/.bashrc" ]]; then
    source "${HOME}/.bashrc"
fi
if [[ -f "${HOME}/.bash_profile" ]]; then
=======
if [[ -f "${HOME}/.bashrc"]]; then
    source "${HOME}/.bashrc"
fi
if [[ -f "${HOME}/.bash_profile"]]; then
>>>>>>> 4446924b11a2f706e5e5d0c572a13c464fdc0b85
    source "${HOME}/.bash_profile"
fi

# try to load modules
if command -v module >/dev/null 2>&1; then
    info "modules system available, loading in relevant modules..."
    module purge
    module load ${MODULE_LIST}
else
    info "no modules system found, assuming you have already installed relevant packages."
fi

# set open mp threads 
export OMP_NUM_THREADS=${THREADS_PER_PROCESS}

# ----------------------------
# Step 1: Prepare source code
# ----------------------------

if [[ ! -d "$CODE_DIR" ]]; then
    if [[ -d "$CODE_DIR" ]]; then
        info "using existing ${CODE_DIR} directory."
    elif [[ -f "${CODE_TAR}" ]]; then
        info "extracting ${CODE_TAR}..."
        tar xf ${CODE_TAR}
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
            error "GIZMO_SYSTYPE is not set. Please run \"export GIZMO_SYSTYPE= \" prior to or in your .bashrc or .bash_profile file."
        fi
        echo -e "\nSYSTYPE=\"${GIZMO_SYSTYPE}\"" >> "${CODE_DIR}/Makefile.systype"
        info "set system type to ${GIZMO_SYSTYPE} in ${CODE_DIR}/Makefile.systype"
    fi
else
    info "found existing code directory."
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


# ----------------------------
# Step 3: Compile (if not skipped)
# ----------------------------
if [[ "$SKIP_MAKE" == false ]]; then
    cd "$CODE_DIR"
    
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
    LAUNCH_ARGS="-n ${NPROCESSES}"
elif command -v aprun >/dev/null 2>&1; then
    info "using aprun for mpi launch"
    LAUNCHER="aprun"
    LAUNCH_ARGS="-n ${NPROCESSES}"
elif command -v srun >/dev/null 2>&1; then
    info "using srun for mpi launch"
    LAUNCHER="srun"
    LAUNCH_ARGS="-n ${NPROCESSES}"
elif command -v mpirun >/dev/null 2>&1; then
    info "using mpirun for mpi launch"
    LAUNCHER="mpirun"
    LAUNCH_ARGS="-np ${NPROCESSES}"
else
    error "no mpi launcher found (ibrun/aprun/srun/mpirun)"
fi

# either submit a slurm batch or run directly
if [[ "$NNODES" -gt 0 ]]; then
    info "making slurm batch script..."
    
    BATCH_FILE="submit_${JOB_NAME}.sh"
    cat > "$BATCH_FILE" <<EOF
#!/bin/bash
#SBATCH --job-name=${JOB_NAME}
#SBATCH --nodes=${NNODES}
#SBATCH --ntasks=${NPROCESSES}
#SBATCH --time=${JOB_TIME}

cd "${RUN_DIR}"
export OMP_NUM_THREADS=${THREADS_PER_PROCESS}
source "${HOME}/.bashrc"
module purge
module load ${MODULE_LIST}

echo "$LAUNCHER $LAUNCH_ARGS $EXEC_PATH $PARAM_FILE $RESTART"
$LAUNCHER $LAUNCH_ARGS "$EXEC_PATH" "$PARAM_FILE" "$RESTART" 1>${JOB_NAME}.out 2>${JOB_NAME}.err
echo done
EOF
    info "submitting slurm batch script..."
    cd ${ORIGINAL_DIR}
    sbatch "${RUN_DIR}/${BATCH_FILE}"
else
    # actually run locally
    info "running GIZMO..."
    echo "$LAUNCHER $LAUNCH_ARGS $EXEC_PATH $PARAM_FILE $RESTART"
    $LAUNCHER $LAUNCH_ARGS "$EXEC_PATH" "$PARAM_FILE" "$RESTART" 1>${JOB_NAME}.out 2>${JOB_NAME}.err
fi

info "done"
