Nix flakes for Durham Neutral Atom and Molecule Improved Control
==========================================================

This repository contains derivations for deploying ARTIQ via the
[Nix package manager](https://nixos.org/download/).

This is a de-oxforded version of the [`nix-oitg`](https://github.com/OxfordIonTrapGroup/nix-oitg.git) repository as described in their readme.

For now, this only installs artiq, and some extra python dependencies, additional dependencies will be installed into the python venv via pip.

Everything exists in a `~/scratch` directory.

```
# Make the scratch directory
cd ~/
mkdir scratch
cd ~/scratch

# Clone this repo (that contains a flake that sets up a dev shell)
git clone https://github.com/CornishLabs/dnamic-setup

# Clone the relevant repositorys to be installed into the python venv
git clone https://github.com/OxfordIonTrapGroup/oitg
git clone https://github.com/tomhepz/ndscan


# Create the dev environment
# This command will:
#  - Use nix flakes to install relevant packages (artiq, python, certain python packages e.g. pandas) within a nix context
#  - Then use a shell hook to manage a python virtual environment that will be stored in `~/scratch/nix-artiq-venvs`

nix develop ~/scratch/dnamic-setup

# Then install the python packages into this environment, as the shell hook script describes

pip install --config-settings editable_mode=compat --no-dependencies -e ~/scratch/oitg
pip install --config-settings editable_mode=compat --no-dependencies -e ~/scratch/ndscan

# Then run artiq with the ndscan package, for some reason I have required
# running the frontend command with the `python` activated with the dev shell directly...

cd ~/artiq-master

> $ (artiq-master-dev) tom@tom-artiq-test-rig:~/artiq-master$ ls
> device_db.py  repository

# Then run either:
artiq-lab-tmux
# Which will run all commands in a TMUX session (Recommended)

# OR run the commands individually
# THIS IS DEPRICATED FOR THE SETUP, BECAUSE NEED TO SET HOME ENV VARIABLES TO GET THE ARTIQ FOLDER STRUCTURE TO WORK AS MODULES
# BUT THESE ARE THE COMMANDS THAT WOULD START COMPONENTS OF 'NORMAL'/'BARE' ARTIQ
python -m artiq.frontend.artiq_master
ndscan_dataset_janitor 
python -m artiq_comtools.artiq_ctlmgr
python -m artiq.frontend.artiq_dashboard -p ndscan.dashboard_plugin
```


