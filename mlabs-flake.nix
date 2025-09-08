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
    in {
      packages.x86_64-linux.default = pkgs.buildEnv {
        name = "artiq-env";
        paths = [
          (pkgs.python3.withPackages(ps : [
            artiq.artiq
            ps.pandas
            ps.numba
            ps.matplotlib
            # Note that NixOS also provides packages ps.numpy and ps.scipy, but it is
            # not necessary to explicitly add these, since they are dependencies of
            # ARTIQ and incorporated with an ARTIQ install anyway.
          ]))
          pkgs.gtkwave
        ];
      };
    };
}
