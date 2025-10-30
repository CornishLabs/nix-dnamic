{
  nixConfig = {
    extra-trusted-public-keys = "nixbld.m-labs.hk-1:5aSRVA5b320xbNvu30tqxVPXpld73bhtOeH6uAjRyHc=";
    extra-substituters = "https://nixbld.m-labs.hk";
  };
  inputs.extrapkg.url = "git+https://git.m-labs.hk/M-Labs/artiq-extrapkg.git?ref=release-8";
  outputs = { self, extrapkg }:
    let
      pkgs = extrapkg.pkgs;
      artiq = extrapkg.packages.x86_64-linux;
      python-env = pkgs.python3.withPackages(ps : [
            artiq.artiq
            ps.pandas
            ps.matplotlib
      ]);

      artiq-lab-tmux = pkgs.writeShellApplication {
        name = "artiq-lab-tmux";
        runtimeInputs = [ pkgs.tmux pkgs.bash ];
        text = builtins.readFile ./src/artiq-lab-tmux.sh;
      };

      artiq-master-dev = pkgs.mkShell {
        name = "artiq-master-dev";
        buildInputs = [ 
          python-env
          artiq-lab-tmux 
        ];
        shellHook = ''
          if [ -z "$SCRATCH_DIR" ]; then
            echo "SCRATCH_DIR environment variable not set, defaulting to ~/scratch."
            export SCRATCH_DIR=$HOME/scratch
            export QT_PLUGIN_PATH=${pkgs.qt5.qtbase}/${pkgs.qt5.qtbase.dev.qtPluginPrefix}
            export QML2_IMPORT_PATH=${pkgs.qt5.qtbase}/${pkgs.qt5.qtbase.dev.qtQmlPrefix}
          fi
          ${
            ./src/setup-artiq-master-dev.sh
          } ${python-env} ${python-env.sitePackages} || exit 1
          source $SCRATCH_DIR/nix-artiq-venvs/artiq-master-dev/bin/activate || exit 1
          export PYTHONPATH="''${SCRATCH_DIR:-}''${PYTHONPATH:+:$PYTHONPATH}"
        '';
      };
  in {
    inherit artiq-master-dev;
    devShells.x86_64-linux.default = artiq-master-dev;
  };
}
