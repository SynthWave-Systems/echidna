{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    nix-bundle-exe = {
      url = "github:3noch/nix-bundle-exe";
      flake = false;
    };
    solc-pkgs = {
      url = "github:hellwolf/solc.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, nix-bundle-exe, solc-pkgs, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [solc-pkgs.overlay];
        };

        # prefer musl on Linux, static glibc + threading does not work properly
        # TODO: maybe only override it for echidna-redistributable?
        pkgsStatic = if pkgs.stdenv.hostPlatform.isLinux then pkgs.pkgsStatic else pkgs;
        # this is not perfect for development as it hardcodes solc to 0.5.7, test suite runs fine though
        # 0.5.7 is not available on aarch64 darwin so alternatively pick 0.8.5
        solc = solc-pkgs.mkDefault pkgs (pkgs.solc_0_5_7 or pkgs.solc_0_8_5);

        secp256k1-static = pkgsStatic.secp256k1.overrideAttrs (attrs: {
          configureFlags = attrs.configureFlags ++ [ "--enable-static" ];
        });

        ncurses-static = pkgsStatic.ncurses.override { enableStatic = true; };

        hsPkgs = ps :
          ps.haskellPackages.override {
            overrides = hfinal: hprev: {
              with-utf8 =
                if (with ps.stdenv; hostPlatform.isDarwin && hostPlatform.isx86)
                then ps.haskell.lib.compose.overrideCabal (_ : { extraLibraries = [ps.libiconv]; }) hprev.with-utf8
                else hprev.with-utf8;
              # TODO: temporary fix for static build which is still on 9.4
              witch = ps.haskell.lib.doJailbreak hprev.witch;
            };
          };

        hevm = pkgs: pkgs.lib.pipe ((hsPkgs pkgs).callCabal2nix "hevm" (pkgs.fetchFromGitHub {
          owner = "ethereum";
          repo = "hevm";
          rev = "release/0.54.2";
          sha256 = "sha256-h0e6QeMBIUkyANYdrGjrqZ2M4fnODOB0gNPQtsrAiL8=";
        }) { secp256k1 = pkgs.secp256k1; })
        ([
          pkgs.haskell.lib.compose.dontCheck
        ]);

        echidna = pkgs: with pkgs; lib.pipe
          ((hsPkgs pkgs).callCabal2nix "echidna" ./. { hevm = hevm pkgs; })
          ([
            # FIXME: figure out solc situation, it conflicts with the one from
            # solc-select that is installed with slither, disable tests in the meantime
            haskell.lib.compose.dontCheck
            (haskell.lib.compose.addTestToolDepends [ haskellPackages.hpack slither-analyzer solc ])
            (haskell.lib.compose.disableCabalFlag "static")
          ]);

        echidna-static = with pkgsStatic; lib.pipe
          (echidna pkgsStatic)
          [
            (haskell.lib.compose.appendConfigureFlags
              [
                "--extra-lib-dirs=${stripDylib (gmp.override { withStatic = true; })}/lib"
                "--extra-lib-dirs=${stripDylib secp256k1-static}/lib"
                "--extra-lib-dirs=${stripDylib (libff.override { enableStatic = true; })}/lib"
                "--extra-lib-dirs=${zlib.override { static = true; shared = false; }}/lib"
                "--extra-lib-dirs=${stripDylib (libffi.overrideAttrs (_: { dontDisableStatic = true; }))}/lib"
                "--extra-lib-dirs=${stripDylib (ncurses-static)}/lib"
              ])
            (haskell.lib.compose.enableCabalFlag "static")
          ];

        # "static" binary for distribution
        # on linux this is actually a real fully static binary
        # on macos this has everything except libcxx and libsystem
        # statically linked. we can be confident that these two will always
        # be provided in a well known location by macos itself.
        echidnaRedistributable = let
          grep = "${pkgs.gnugrep}/bin/grep";
          perl = "${pkgs.perl}/bin/perl";
          otool = "${pkgs.darwin.binutils.bintools}/bin/otool";
          install_name_tool = "${pkgs.darwin.binutils.bintools}/bin/install_name_tool";
          codesign_allocate = "${pkgs.darwin.binutils.bintools}/bin/codesign_allocate";
          codesign = "${pkgs.darwin.sigtool}/bin/codesign";
        in if pkgs.stdenv.isLinux
        then pkgs.runCommand "echidna-stripNixRefs" {} ''
          mkdir -p $out/bin
          cp ${pkgsStatic.haskell.lib.dontCheck echidna-static}/bin/echidna $out/bin/
          # fix TERMINFO path in ncurses
          ${perl} -i -pe 's#(${ncurses-static}/share/terminfo)#"/etc/terminfo:/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo" . "\x0" x (length($1) - 65)#e' $out/bin/echidna
          chmod 555 $out/bin/echidna
        '' else pkgs.runCommand "echidna-stripNixRefs" {} ''
          mkdir -p $out/bin
          cp ${pkgsStatic.haskell.lib.dontCheck echidna-static}/bin/echidna $out/bin/
          # get the list of dynamic libs from otool and tidy the output
          libs=$(${otool} -L $out/bin/echidna | tail -n +2 | sed 's/^[[:space:]]*//' | cut -d' ' -f1)
          # get the path for libcxx
          cxx=$(echo "$libs" | ${grep} '^/nix/store/.*/libc++\.')
          cxxabi=$(echo "$libs" | ${grep} '^/nix/store/.*/libc++abi\.')
          iconv=$(echo "$libs" | ${grep} '^/nix/store/.*/libiconv\.')
          # rewrite /nix/... library paths to point to /usr/lib
          chmod 777 $out/bin/echidna
          ${install_name_tool} -change "$cxx" /usr/lib/libc++.1.dylib $out/bin/echidna
          ${install_name_tool} -change "$cxxabi" /usr/lib/libc++abi.dylib $out/bin/echidna
          ${install_name_tool} -change "$iconv" /usr/lib/libiconv.dylib $out/bin/echidna
          # fix TERMINFO path in ncurses
          ${perl} -i -pe 's#(${ncurses-static}/share/terminfo)#"/usr/share/terminfo" . "\x0" x (length($1) - 19)#e' $out/bin/echidna
          # check that no nix deps remain
          nixdeps=$(${otool} -L $out/bin/echidna | tail -n +2 | { ${grep} /nix/store -c || test $? = 1; })
          if [ ! "$nixdeps" = "0" ]; then
            echo "Nix deps remain in redistributable binary!"
            exit 255
          fi
          # re-sign binary
          CODESIGN_ALLOCATE=${codesign_allocate} ${codesign} -f -s - $out/bin/echidna
          chmod 555 $out/bin/echidna
        '';

        # if we pass a library folder to ghc via --extra-lib-dirs that contains
        # only .a files, then ghc will link that library statically instead of
        # dynamically (even if --enable-executable-static is not passed to cabal).
        # we use this trick to force static linking of some libraries on macos.
        stripDylib = drv : pkgs.runCommand "${drv.name}-strip-dylibs" {} ''
          mkdir -p $out
          mkdir -p $out/lib
          cp -r ${drv}/* $out/
          rm -rf $out/**/*.dylib
        '';

      in rec {
        packages.echidna = echidna pkgs;
        packages.default = echidna pkgs;

        packages.echidna-redistributable = echidnaRedistributable;

        devShell = with pkgs;
          haskellPackages.shellFor {
            packages = _: [ (echidna pkgs) ];
            shellHook = ''
              hpack
            '';
            buildInputs = [
              solc
              slither-analyzer
              haskellPackages.hlint
              haskellPackages.cabal-install
              haskellPackages.haskell-language-server
            ];
            withHoogle = true;
          };
      }
    );
}
