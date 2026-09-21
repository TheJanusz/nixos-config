{ config, lib, pkgs, ... }:

let
  # nixpkgs still ships unmaintained upstream 2.9.3; pin the poddmo fork.
  abcdeOverlay = (final: prev: {
    abcde = prev.abcde.overrideAttrs (old: {
      version = "2.12.2";
      src = final.fetchFromGitHub {
        owner = "poddmo";
        repo = "abcde";
        rev = "2.12.2";
        hash = "sha256-25aGdb9Fmc5G9rzgaIQsnh3vgFe2oFs4NGGYpqrhME0=";
      };
    });
  });
  # VLC-only: libbluray-full keeps AACS/BD+/Java, but dlopens MakeMKV's libmmbd
  # instead of nixpkgs libaacs. Do not overlay libbluray-full globally.
  vlcOverlay = (final: prev: {
    customvlc =
      let
        mmbdCompat = prev.runCommand "libmmbd-compat" { } ''
          mkdir -p $out/lib
          ln -s ${prev.makemkv}/lib/libmmbd.so.0 $out/lib/libaacs.so
          ln -s ${prev.makemkv}/lib/libmmbd.so.0 $out/lib/libaacs.so.0
          ln -s ${prev.makemkv}/lib/libmmbd.so.0 $out/lib/libbdplus.so
          ln -s ${prev.makemkv}/lib/libmmbd.so.0 $out/lib/libbdplus.so.0
          # Meson compiler check links -laacs; ELF SONAME is libmmbd.so.0, so
          # the rpath dir must contain that name (not only libaacs.so*).
          ln -s ${prev.makemkv}/lib/libmmbd.so.0 $out/lib/libmmbd.so
          ln -s ${prev.makemkv}/lib/libmmbd.so.0 $out/lib/libmmbd.so.0
        '';
        libblurayFullMmbd = (prev.libbluray-full.override {
          libbluray = prev.libbluray.override {
            libaacs = mmbdCompat;
            libbdplus = mmbdCompat;
          };
        }).overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ prev.patchelf ];
          # dlopen() is issued by libbluray.so. DT_RUNPATH there makes glibc
          # ignore LD_LIBRARY_PATH, so the shim must be on *this* RUNPATH.
          postFixup = (old.postFixup or "") + ''
            shopt -s nullglob
            for so in "$out"/lib/libbluray.so*; do
              patchelf --add-rpath ${mmbdCompat}/lib "$so"
            done
          '';
        });
        vlcBase = prev.vlc.override {
          libbluray-full = libblurayFullMmbd;
          libaacs = mmbdCompat;
        };
      in
      prev.symlinkJoin {
        name = "vlc";
        paths = [ vlcBase ];
        nativeBuildInputs = [ prev.makeWrapper ];
        postBuild = ''
          for b in vlc cvlc nvlc qvlc rvlc svlc; do
            if [ -e "$out/bin/$b" ]; then
              rm -f "$out/bin/$b"
              makeWrapper ${vlcBase}/bin/$b "$out/bin/$b" \
                --prefix PATH : ${prev.lib.makeBinPath [ prev.makemkv ]} \
                --prefix LD_LIBRARY_PATH : ${mmbdCompat}/lib:${prev.makemkv}/lib \
                --set MAKEMKVCON ${prev.makemkv}/bin/makemkvcon
            fi
          done
          # File managers / app launchers use this Exec, not PATH. symlinkJoin
          # leaves it pointing at inner Qt VLC, which skips MAKEMKVCON.
          desktop="$out/share/applications/vlc.desktop"
          if [ -e "$desktop" ]; then
            rm -f "$desktop"
            cp ${vlcBase}/share/applications/vlc.desktop "$desktop"
            chmod u+w "$desktop"
            sed -i "s|${vlcBase}/bin/vlc|$out/bin/vlc|g" "$desktop"
          fi
        '';
      };
  });
in
{  
  nixpkgs.overlays = [ abcdeOverlay vlcOverlay ];
  home.packages = with pkgs; [
    abcde # CD ripping
    ddrescue # backing up damaged discs
    (callPackage ../../packages/discflat { }) # photo → square transparent disc PNG
    ffmpeg-full
    customvlc
    makemkv
    mkvtoolnix # Mostly for editing chapter info. Also ripping problematic titles from badly authored dvds
    picard # Adding stuff to MusicBrainz
    yt-dlp # Downloading stuff from video sites
  ];
}
