# GIZ: One GIZMO Command To Rule Them All


This is a convience script for the [GIZMO](http://www.tapir.caltech.edu/~phopkins/Site/GIZMO.html) code. It is meant to automate the installation, configuration, compilation, parameter setting, and running (or job scheduling) phases of the GIZMO workflow in a single bash command.



## How to use

Run `giz.sh` at the location you want to run GIZMO and it will handle everything. 


You only need to create your configuration and parameter files when prompted. Refer to the [GIZMO documentation](http://www.tapir.caltech.edu/~phopkins/Site/GIZMO_files/gizmo_documentation.html) for what settings you need for your specific use case.



## Setting optional parameters

Run `giz --help` for an up to date list of command parameters and predefined variables. Options include queuing a GIZMO job with slurm, skipping compilation, running from restart files, and defining an alternate run directory or config, executable and parameter filenames.


## "Installation"

You can clone this repo with:

`git clone https://github.com/JaedenBardati/giz.git`

To use the `giz` command from anywhere, you can add the following line to your `.bashrc` or `.bash_profile`:

`alias giz="/path/to/giz/giz.sh"`

If you want to use `giz` to install GIZMO for you, then you will also need to define your system type (see Makefile.systype in the [GIZMO documentation](http://www.tapir.caltech.edu/~phopkins/Site/GIZMO_files/gizmo_documentation.html) for details):

`export GIZMO_SYSTYPE="YourSystemType"`

Do this with any other predefined variables you would like (e.g. `GIZMO_MODULE_LIST`).

### Examples

From Frontera, you might "install" with:

```
cd ~
git clone https://github.com/JaedenBardati/giz.git
echo "alias giz=\"~/giz/giz.sh\"" >> ~/.bashrc
echo "export GIZMO_SYSTYPE=\"Frontera\"" >> ~/.bashrc
echo "export GIZMO_MODULE_LIST=\"intel impi gsl hdf5 fftw3\"" >> ~/.bashrc
source ~/.bashrc
```

From a MacBook machine, you might "install" with:

```
cd ~
git clone https://github.com/JaedenBardati/giz.git
echo "alias giz=\"~/giz/giz.sh\"" >> ~/.bash_profile
echo "export GIZMO_SYSTYPE=\"MacBookPro\"" >> ~/.bash_profile
echo "export GIZMO_EDITOR=\"open\"" >> ~/.bash_profile
source ~/.bash_profile
```

From a custom GIZMO version to copy, you might also set:

```
echo "export GIZMO_SOURCE=\"path/to/custom/GIZMO\"" >> ~/.bashrc
```

You can then just call `giz` from anywhere you want to run GIZMO (preferably in its own directory). To call on the local node:

```
mkdir some_gizmo_run
cd some_gizmo_run
giz -n 6 -T 2
```

which will install, compile, and run GIZMO with 6 MPI processes and 2 threads per process on the local machine. To queue up a slurm job:

```
mkdir some_gizmo_run
giz -d "./some_gizmo_run" -N 5 -n 70 -T 4 -t "24:00:00" -j "job_name"
```

which will queue a job named "job_name" with 5 node, 14 total processes, 4 threads per node, for 24 hours, and will use the `./some_gizmo_run` directory to run GIZMO from, but the slurm output files will be in the working directory.

### Requirements

No specific requirements for `giz.sh`, but your system needs the GIZMO requirements. If your system has the `modules` infrastructure, you likely don't have to worry about this.

If you don't have the `modules` command to use packages (e.g. you are on a local machine), then you will have to install the required packages (MPI, GSL, FFTW, HDF5) manually. On mac, if you have gcc/mpicc and brew installed (if you don't, just look up how to generically install them), just use

```
brew install open-mpi gsl hdf5 sundials # ...
echo "export PORTLIB=\"/opt/homebrew/lib\"" >> ~/.bash_profile
echo "export PORTINCLUDE=\"/opt/homebrew/include\"" >> ~/.bash_profile
source ~/.bash_profile
```

Note that you may also need install FFTW2/3 (see note in GIZMO Makefile). And you may also have to uncomment `-I$(PORTINCLUDE)` and `-L$(PORTLIB)` in the GIZMO Makefile. There may also likewise be other specfic GIZMO installation requirements for other individual systems. For this reason, local systems it may be better to manually install GIZMO to a certain location first and then define `GIZMO_SOURCE`. Alternatively, you can just use `giz` to git clone one of the GIZMO repos and then you can adjust the source code for that specific run as needed in the code directory.
