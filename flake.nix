{
  description = "Environment for running ARTIQ master in durham";
  inputs = {
    artiq.url = "git+https://git.m-labs.hk/M-Labs/artiq-extrapkg.git?ref=release-8";

    src-ndscan = {
      url = "github:OxfordIonTrapGroup/ndscan";
      flake = false;
    };
    src-oitg = {
      url = "github:OxfordIonTrapGroup/oitg";
      flake = false;
    };
  };
  outputs = { self, artiq, src-ndscan, src-oitg}:
    let
      nixpkgs = artiq.pkgs;
      sipyco = artiq.inputs.sipyco;
      oitg = nixpkgs.python3Packages.buildPythonPackage {
        name = "oitg";
        src = src-oitg;
        format = "pyproject";
        propagatedBuildInputs = with nixpkgs.python3Packages; [
          h5py
          scipy
          statsmodels
          nixpkgs.python3Packages.poetry-core
          nixpkgs.python3Packages.poetry-dynamic-versioning
        ];
        # Whatever magic `setup.py test` does by default fails for oitg.
        installCheckPhase = ''
          ${nixpkgs.python3.interpreter} -m unittest discover test
        '';
      };
      ndscan = nixpkgs.python3Packages.buildPythonPackage {
        name = "ndscan";
        src = src-ndscan;
        format = "pyproject";
        propagatedBuildInputs = [
          artiq.packages.x86_64-linux.artiq
          oitg
          nixpkgs.python3Packages.hatchling
          nixpkgs.python3Packages.pyqt6
        ];
        # ndscan depends on pyqtgraph>=0.12.4 to display 2d plot colorbars, but this
        # is not yet in nixpkgs 23.05. Since this flake will mostly be used for
        # server-(master-)side installations, just patch it out for now. In theory,
        # pythonRelaxDepsHook should do this more elegantly, but it does not seem to
        # be run before pipInstallPhase.
        # FIXME: qasync/sipyco/oitg dependencies which explicitly specify a Git source
        # repo do not seem to be matched by the packages pulled in via Nix; what is the
        # correct approach here?
        postPatch = ''
          sed -i -e "s/^pyqtgraph = .*//" pyproject.toml
          sed -i -e "s/^qasync = .*//" pyproject.toml
          sed -i -e "s/^sipyco = .*//" pyproject.toml
          sed -i -e "s/^oitg = .*//" pyproject.toml
        '';
        dontWrapQtApps = true; # Pulled in via the artiq package; we don't care.
      };
      python-env = (nixpkgs.python3.withPackages (ps:
        (with ps; [ aiohttp h5py influxdb llvmlite numba pyzmq ]) ++ [
          # ARTIQ will pull in a large number of transitive dependencies, most of which
          # we also rely on. Currently, it is a bit overly generous, though, in that it
          # pulls in all the requirements for a full GUI and firmware development
          # install (Qt, Rust, etc.). Could slim down if disk usage ever becomes an
          # issue.
          artiq.packages.x86_64-linux.artiq
          ndscan
          oitg
        ]));
      artiq-master-dev = nixpkgs.mkShell {
        name = "artiq-master-dev";
        buildInputs = [
          python-env
          artiq.packages.x86_64-linux.openocd-bscanspi
          nixpkgs.julia_19-bin
          nixpkgs.lld_14
          nixpkgs.llvm_14
          nixpkgs.libusb-compat-0_1
        ];
        shellHook = ''
          if [ -z "$OITG_SCRATCH_DIR" ]; then
            echo "OITG_SCRATCH_DIR environment variable not set, defaulting to ~/scratch."
            export OITG_SCRATCH_DIR=$HOME/scratch
            export QT_PLUGIN_PATH=${nixpkgs.qt5.qtbase}/${nixpkgs.qt5.qtbase.dev.qtPluginPrefix}
            export QML2_IMPORT_PATH=${nixpkgs.qt5.qtbase}/${nixpkgs.qt5.qtbase.dev.qtQmlPrefix}
          fi
          ${
            ./src/setup-artiq-master-dev.sh
          } ${python-env} ${python-env.sitePackages} || exit 1
          source $OITG_SCRATCH_DIR/nix-oitg-venvs/artiq-master-dev/bin/activate || exit 1
        '';
      };
    in {
      # Allow explicit use from outside the flake, in case we want to add other targets
      # or build on this in the future.
      inherit artiq-master-dev;
      inherit oitg ndscan;

      defaultPackage.x86_64-linux = artiq-master-dev;
    };

  nixConfig = {
    extra-trusted-public-keys = "nixbld.m-labs.hk-1:5aSRVA5b320xbNvu30tqxVPXpld73bhtOeH6uAjRyHc=";
    extra-substituters = "https://nixbld.m-labs.hk";
  };
}
