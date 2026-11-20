{
  description = "rapidsnark without the x86-64 ADX/BMI2 assembly, as a drop-in for logos-blockchain's rust-rapidsnark input";

  # Same interface as github:logos-blockchain/logos-blockchain-rust-rapidsnark:
  # packages.<system>.rapidsnark is a directory holding librapidsnark.a, libfr.a,
  # libfq.a and libgmp.a. logos-blockchain points RAPIDSNARK_LIB_DIR at it.
  #
  # Only x86_64-linux differs from upstream. Upstream's archives there use
  # rapidsnark's x86-64 field-arithmetic assembly (mulx/adcx/adox, so BMI2 + ADX),
  # plus a GMP tuned to the CI runner's CPU, so they crash with SIGILL on CPUs
  # without ADX (pre-Broadwell Intel, Atom/Celeron/Pentium Silvermont...):
  # logos-blockchain/logos-blockchain#3743. Here, rapidsnark is built with
  # USE_ASM=OFF (its generic C++ Fr/Fq), and GMP is nixpkgs' fat build (it picks
  # its CPU-specific code at runtime).
  #
  # Every other system re-exports upstream unchanged: the arm64 assembly needs
  # nothing beyond baseline AArch64.

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    # Keep in sync with logos-blockchain's rust-rapidsnark input (flake.nix + Cargo.toml) for the pinned release.
    upstream.url = "github:logos-blockchain/logos-blockchain-rust-rapidsnark/e91187f8ccb5bbfc7bb00dac88169112428da78f";
    upstream.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, upstream, ... }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];

      # Must match upstream's RAPIDSNARK_VERSION.
      version = "0.0.8";

      mkPortable = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # nixpkgs builds GMP with --enable-fat on x86, so the static archive is safe on any x86-64 CPU.
          gmp = pkgs.gmp.override { withStatic = true; };
        in
        pkgs.stdenv.mkDerivation {
          pname = "rapidsnark-portable";
          inherit version;

          src = pkgs.fetchFromGitHub {
            owner = "iden3";
            repo = "rapidsnark";
            rev = "v${version}";
            fetchSubmodules = true;
            hash = "sha256-e/DNJQ96GB1OQklmQcpw2lU7SCRQ67uZUAz4gXn9nkM=";
          };

          nativeBuildInputs = [ pkgs.cmake ];

          # rapidsnark's source tree has a build/ directory of generated sources, so build elsewhere.
          cmakeBuildDir = "bp";
          cmakeFlags = [
            "-DCMAKE_BUILD_TYPE=Release"
            "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
            "-DUSE_ASM=OFF"
            "-DUSE_OPENMP=OFF"
            "-DUSE_LOGGER=ON"
          ];

          # rapidsnark looks for GMP in depends/gmp/package (cmake/platform.cmake).
          preConfigure = ''
            mkdir -p depends/gmp/package/include depends/gmp/package/lib
            cp ${lib.getDev gmp}/include/gmp.h depends/gmp/package/include/
            cp ${lib.getLib gmp}/lib/libgmp.a depends/gmp/package/lib/
          '';

          buildFlags = [ "rapidsnarkStatic" "fr" "fq" ];

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp src/librapidsnark.a src/libfr.a src/libfq.a $out/
            cp ${lib.getLib gmp}/lib/libgmp.a $out/
            runHook postInstall
          '';

          # Fail the build if ADX/BMI2 shows up outside GMP's runtime-dispatched code.
          doInstallCheck = true;
          installCheckPhase = ''
            for a in librapidsnark.a libfr.a libfq.a; do
              n=$(${pkgs.binutils-unwrapped}/bin/objdump -d --no-show-raw-insn $out/$a | grep -cE $'\t(adcx|adox|mulx) ' || true)
              echo "$a: $n ADX/BMI2 instructions"
              [ "$n" = 0 ]
            done
          '';

          passthru = { inherit version; };
          meta.platforms = [ "x86_64-linux" ];
        };
    in
    {
      packages = lib.genAttrs systems (system:
        let
          rapidsnark =
            if system == "x86_64-linux"
            then mkPortable system
            else upstream.packages.${system}.rapidsnark;
        in
        {
          inherit rapidsnark;
          default = rapidsnark;
        });
    };
}
