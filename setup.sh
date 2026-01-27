# This sets up the giz command for your system. Call this ONLY ONCE EVER and before using giz.sh
# Adjust the below paramters to match your machine.

##########################
#####   PARAMETERS   #####
##########################

# GIZMO system type
GIZMO_SYSTYPE="Frontera"
#GIZMO_SYSTYPE="MacBookPro"

# override default choice of bashrc or bash profile according to your system
#BASHRC_FILE_OVERRIDE='~/.bashrc'
#BASHRC_FILE_OVERRIDE='~/.bash_profile'

# choose FFTW version (2 or 3, I default to 3 when possible)
#FFTW_VERSION_OVERRIDE=2

##########################
##########################

info()  { echo -e "[\033[1;34mINFO\033[0m] $*"; }
warn()  { echo -e "[\033[1;33mWARN\033[0m] $*"; }
error() { echo -e "[\033[1;31mERROR\033[0m] $*" >&2; exit 1; }

# output parameters
info "Using GIZMO system type: ${GIZMO_SYSTYPE}"
if [[ -n "${BASHRC_FILE_OVERRIDE:-}" ]]; then
    info "Overriding bashrc file with ${BASHRC_FILE_OVERRIDE}"
fi
if [[ -n "${FFTW_VERSION_OVERRIDE:-}" ]]; then
    info "Overriding FFTW version to $FFTW_VERSION_OVERRIDE"
fi

# find giz.sh 
LOCAL_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
if [[ ! -f "${LOCAL_DIR}/giz.sh" ]]; then
    error "cannot find giz.sh file, it should be next to giz_setup.sh"
fi

# setup giz and make bashrc
extra_bashrc_lines=()

#### FRONTERA ####
if [[ "$GIZMO_SYSTYPE" == "Frontera" ]]; then
    BASHRC_FILE="${BASHRC_FILE_OVERRIDE:-$HOME/.bashrc}"
    FFTW_VERSION="${FFTW_VERSION_OVERRIDE:-3}"
    if [[ $FFTW_VERSION == 3 ]]; then
        fftw_module="fftw3"
    elif [[ $FFTW_VERSION == 2 ]]; then
        fftw_module="fftw2"
    else
        error "FFTW version '${FFTW_VERSION}' not supported."
    extra_bashrc_lines+=("export GIZMO_MODULE_LIST=\"intel impi gsl hdf5 ${fftw_module}\"")
    extra_bashrc_lines+=('umask 022')
    extra_bashrc_lines+=('ulimit -s unlimited')
    info ('tips for GIZMO on Frontera: most nodes are 56 cores, so use n/N (processes per node) = 56/T (56 divided by number of threads per process) = whole number. for small runs use n/N=28, T=2, medium runs use n/N=14, T=4, and very large runs use n/N=7, T=8')

#### MACBOOK PRO ####
elif [[ "$GIZMO_SYSTYPE" == "MacBookPro" ]]; then
    BASHRC_FILE="${BASHRC_FILE_OVERRIDE:-$HOME/.bash_profile}"
    error "macbook implementation is not yet complete"

### IMPLEMENT ANY NEW SYSTEM SETUP ABOVE HERE ###
else
    error "GIZMO system type '${GIZMO_SYSTYPE}' not yet supported. please write your own in giz_setup.sh"
fi


# check if already setup
source ${BASHRC_FILE}
if [[ ${GIZ_HAS_BEEN_SETUP_FLAG} == 1 ]]; then
    error "GIZ has already been setup up! Aborting setup... Remove the relevant lines from ${BASHRC_FILE} and rerun giz_setup.sh if you want to override this abort."
fi

# append everything to bashrc
{
    echo "## GIZ settings ##"
    echo "alias giz=\"${LOCAL_DIR}/giz.sh\""
    echo "export GIZMO_SYSTYPE=\"${GIZMO_SYSTYPE}\""
    for line in "${extra_bashrc_lines[@]}"; do
        echo "$line"
    done
    echo "export GIZ_HAS_BEEN_SETUP_FLAG=1"
    echo "##################"
} >> "${BASHRC_FILE}"

