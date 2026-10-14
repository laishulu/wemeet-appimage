{
  description = "Tencent Meeting (WeMeet) Standalone AppImage Build Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/7fd4004d0511991fff3a0524856a9be09e28c5f0";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      # Compile libwemeetwrap from the latest AUR wemeet-bin commit (ce20a7f)
      libwemeetwrap = pkgs.stdenv.mkDerivation {
        pname = "libwemeetwrap";
        version = "3.26.10.401";

        src = pkgs.fetchgit {
          url = "https://aur.archlinux.org/wemeet-bin.git";
          rev = "ce20a7f39532d2c832c942102145680599143deb";
          hash = "sha256-Yx8qkKGAGEzRHwIV9e4yyb8xF8KX+eznSqOhWGhN/M4=";
        };

        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = with pkgs; [ openssl libpulseaudio libx11 ];

        buildPhase = ''
          runHook preBuild
          read -ra openssl_args < <(pkg-config --libs openssl)
          read -ra libpulse_args < <(pkg-config --cflags --libs libpulse)
          $CC $CFLAGS -O2 -Wall -Wextra -fPIC -shared \
            "''${openssl_args[@]}" "''${libpulse_args[@]}" \
            -o libwemeetwrap.so wrap.c -D WRAP_FORCE_SINK_HARDWARE
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          install -Dm755 ./libwemeetwrap.so $out/lib/libwemeetwrap.so
          runHook postInstall
        '';
      };

      # Minimum set of shared libraries required for runtime and dynamic loading (dlopen)
      wemeetLibs = with pkgs; [
        nss
        nspr
        libxtst
        alsa-lib
        libpulseaudio
        wayland
        libGL
        libdrm
        libsm
        libice
        fontconfig
        harfbuzz
      ];

      # Main package derivation and patching
      wemeet = pkgs.stdenv.mkDerivation {
        pname = "wemeet";
        version = "3.26.10.401";

        src = pkgs.fetchurl {
          url = "https://updatecdn.meeting.qq.com/cos/72e0e0023e1d1e6d4123fba28821aea1/TencentMeeting_0300000000_3.26.10.401_x86_64_default.publish.deb";
          hash = "sha512-rKoeuo7M06W9TLV9wPrc5cM5UIV2d3g5RKwr++++2SfKO0t9nQyehk3Nw7n5+KNZxFbptjs4rA+pQ2/DNqqepw==";
        };

        nativeBuildInputs = with pkgs; [
          dpkg
          autoPatchelfHook
          makeWrapper
        ];

        buildInputs = wemeetLibs;

        dontWrapQtApps = true;

        installPhase = ''
          runHook preInstall

          mkdir -p $out/app $out/share
          cp -r opt/wemeet $out/app/wemeet
          cp -r usr/share/* $out/share/

          # Remove official bundled libcurl to prevent missing OpenSSL 1.1 errors
          rm -f $out/app/wemeet/lib/libcurl.so

          # Adjust desktop shortcut entry and icon reference
          substituteInPlace $out/share/applications/wemeetapp.desktop \
            --replace-fail "/opt/wemeet/wemeetapp.sh" "wemeet" \
            --replace-fail "/opt/wemeet/wemeet.svg" "wemeet"

          # Redirect Qt configuration prefix to the Nix store path
          substituteInPlace $out/app/wemeet/bin/qt.conf \
            --replace-fail "Prefix = ../" "Prefix = $out/app/wemeet/lib"

          # Install icons
          if [ -d "$out/app/wemeet/icons" ]; then
            cp -r $out/app/wemeet/icons $out/share/icons || true
          fi
          install -Dm0644 $out/app/wemeet/wemeet.svg $out/share/icons/hicolor/scalable/apps/wemeet.svg

          # Establish internal relative symlinks required by xcast engine
          ln -sf raw/xcast.conf $out/app/wemeet/bin/xcast.conf
          ln -s $out/app/wemeet/plugins $out/app/wemeet/lib/plugins
          ln -s $out/app/wemeet/resources $out/app/wemeet/lib/resources
          ln -s $out/app/wemeet/translations $out/app/wemeet/lib/translations

          # Search paths for autoPatchelfHook
          addAutoPatchelfSearchPath "$out/app/wemeet/lib"
          addAutoPatchelfSearchPath "$out/app/wemeet/bin/modules"

          runHook postInstall
        '';

        postInstall = ''
          # Critical fix: Coroutine register context restoration assembly bug on modern glibc (cmp rdi, 0 -> cmp r12, 0)
          echo -ne '\x49\x83\xfc\x00' | dd of=$out/app/wemeet/lib/libwemeet_base.so bs=1 seek=$((0x94c833)) conv=notrunc

          # Strip Tencent internal binaries and shared objects
          find $out/app/wemeet -type f \( -name "*.so*" -o -executable \) -exec strip --strip-unneeded {} + 2>/dev/null || true
        '';

        preFixup =
          let
            fullLibPath = pkgs.lib.makeLibraryPath wemeetLibs;

            fontsConf = pkgs.writeText "fonts.conf" ''
              <?xml version="1.0"?>
              <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
              <fontconfig>
                <dir>/usr/share/fonts</dir>
                <dir>/usr/local/share/fonts</dir>
                <dir>/run/current-system/sw/share/fonts</dir>
                <dir prefix="xdg">fonts</dir>
                <dir>~/.fonts</dir>
                <dir>${pkgs.wqy_microhei}/share/fonts</dir>
                <cachedir prefix="xdg">fontconfig</cachedir>
                <cachedir>/tmp/fontconfig-cache</cachedir>
              </fontconfig>
            '';
          in
          ''
            mkdir -p $out/bin

            # Wrapper script to switch working directory and export audio runtime socket
            cat << 'EOF' > $out/bin/wemeet
            #!${pkgs.bash}/bin/bash
            export LP_NUM_THREADS=2
            export XDG_SESSION_TYPE=x11
            export QT_QPA_PLATFORM=xcb
            unset WAYLAND_DISPLAY
            export QT_STYLE_OVERRIDE=fusion
            export IBUS_USE_PORTAL=1
            export FONTCONFIG_FILE="@fontsConf@"
            export XKB_CONFIG_ROOT="@xkbRoot@"

            # Search host DRI locations dynamically (avoids bundling Mesa/LLVM into closure)
            export LIBGL_DRIVERS_PATH="/run/opengl-driver/lib/dri:/usr/lib/x86_64-linux-gnu/dri:/usr/lib64/dri:/usr/lib/dri''${LIBGL_DRIVERS_PATH:+:$LIBGL_DRIVERS_PATH}"

            # Automatically probe PulseAudio / PipeWire runtime socket
            if [ -z "$PULSE_SERVER" ]; then
              if [ -S "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native" ]; then
                export PULSE_SERVER="unix:''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native"
              elif [ -S "/run/user/$(id -u)/pulse/native" ]; then
                export PULSE_SERVER="unix:/run/user/$(id -u)/pulse/native"
              fi
            fi

            export PATH="@out@/app/wemeet/bin:$PATH"
            export QT_PLUGIN_PATH="@out@/app/wemeet/plugins"
            export LD_LIBRARY_PATH="@out@/app/wemeet/lib:@out@/app/wemeet/bin/modules:@out@/app/wemeet/translations:${libwemeetwrap}/lib:@fullLibPath@"
            export LD_PRELOAD="${libwemeetwrap}/lib/libwemeetwrap.so''${LD_PRELOAD:+:$LD_PRELOAD}"

            # Essential: Change directory so xcast engine locates relative modules correctly
            cd "@out@/app/wemeet/bin"
            exec "@out@/app/wemeet/bin/wemeetapp" "$@"
            EOF

            substituteInPlace $out/bin/wemeet \
              --replace-fail "@fontsConf@" "${fontsConf}" \
              --replace-fail "@xkbRoot@" "${pkgs.xkeyboard_config}/share/X11/xkb" \
              --replace-fail "@out@" "$out" \
              --replace-fail "@fullLibPath@" "${fullLibPath}"

            chmod +x $out/bin/wemeet
          '';

        meta = {
          description = "Tencent Meeting Linux Client";
          mainProgram = "wemeet";
          platforms = [ "x86_64-linux" ];
        };
      };

      # Official standard AppImage runtime (Type-2 runtime)
      appimageRuntime = pkgs.fetchurl {
        url = "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64";
        hash = "sha256-FW9L296cUtAYFGAAE+Cic/ARjcLemJdfPIxjQn7HkHQ=";
      };

      # Upstream static PRoot binary used when unprivileged bubblewrap is unavailable
      prootStatic = pkgs.fetchurl {
        url = "https://github.com/proot-me/proot/releases/download/v5.5.0/proot";
        hash = "sha256-2xhTAKnaq7zoasp2MtjH/cQkn28VMXGVQBO3DF9JHsA=";
      };

      # Assemble self-contained portable AppImage
      appimage = pkgs.stdenv.mkDerivation {
        name = "TencentMeeting-${wemeet.version}-x86_64.AppImage";
        nativeBuildInputs = [
          pkgs.squashfsTools
          pkgs.binutils
          pkgs.coreutils
          pkgs.zsync
        ];
        closureInfo = pkgs.closureInfo { rootPaths = [ wemeet ]; };

        buildCommand = ''
          mkdir -p AppDir/nix/store
          while IFS= read -r path; do
            cp -a "$path" AppDir/nix/store/
          done < "$closureInfo/store-paths"

          # Clean up dev/doc/static files from the copied store closure
          chmod -R u+w AppDir/nix/store
          rm -rf AppDir/nix/store/*/{share/doc,share/man,share/info,include,lib/pkgconfig}
          find AppDir/nix/store -type f \( -name "*.a" -o -name "*.la" \) -delete
          find AppDir/nix/store -type f \( -name "*.so*" -o -perm -0100 \) -exec strip --strip-unneeded {} + 2>/dev/null || true

          # Bundle static bubblewrap and static proot
          cp ${pkgs.pkgsStatic.bubblewrap}/bin/bwrap AppDir/bwrap
          chmod +x AppDir/bwrap
          strip --strip-unneeded AppDir/bwrap 2>/dev/null || true

          cp ${prootStatic} AppDir/proot
          chmod +x AppDir/proot

          # 1. Desktop integration setup
          mkdir -p AppDir/usr/share
          cp -r "${wemeet}/share/"* AppDir/usr/share/
          ln -sf usr/share/applications/wemeetapp.desktop AppDir/
          ln -sf usr/share/icons/hicolor/scalable/apps/wemeet.svg AppDir/
          ln -sf wemeet.svg AppDir/.DirIcon

          # 2. Binary symlinks
          mkdir -p AppDir/bin
          ln -s ${wemeet}/bin/wemeet AppDir/bin/wemeet
          ln -s ${wemeet}/bin/wemeet AppDir/entrypoint

          # 3. AppRun multiplexer script with shared binds
          cat << 'EOF' > AppDir/AppRun
          #!/usr/bin/env bash
          set -e

          # 1. Accurately locate mounted AppDir root
          HERE="''${APPDIR:-$(dirname "$(readlink -f "''${BASH_SOURCE[0]}")")}"
          INVOKED_NAME="$(basename "''${ARGV0:-$0}")"

          # 2. Determine target binary
          TARGET="$(readlink "$HERE/entrypoint")"
          TARGET="''${TARGET:-${wemeet}/bin/wemeet}"

          # Shared environment setup
          export XDG_SESSION_TYPE=x11
          export QT_QPA_PLATFORM=xcb
          unset WAYLAND_DISPLAY

          if [ -z "$PULSE_SERVER" ]; then
            if [ -S "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native" ]; then
              export PULSE_SERVER="unix:''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native"
            elif [ -S "/run/user/$(id -u)/pulse/native" ]; then
              export PULSE_SERVER="unix:/run/user/$(id -u)/pulse/native"
            fi
          fi

          # Fast path: Native NixOS host execution
          if [ -x "$TARGET" ]; then
            exec "$TARGET" "$@"
          fi

          # Collect shared filesystem mount paths (storage, system fonts, DRI drivers)
          COMMON_BINDS=()
          for d in /media /mnt /run/media; do
            [ -d "$d" ] && COMMON_BINDS+=("$d")
          done

          for d in /usr/share/fonts /usr/local/share/fonts /etc/fonts; do
            [ -d "$d" ] && COMMON_BINDS+=("$d")
          done

          for d in /run/opengl-driver/lib/dri /usr/lib/x86_64-linux-gnu/dri /usr/lib64/dri /usr/lib/dri; do
            [ -d "$d" ] && COMMON_BINDS+=("$d")
          done

          # Probe whether unprivileged bubblewrap can construct a user namespace
          CAN_BWRAP=0
          if [ -x "$HERE/bwrap" ] && "$HERE/bwrap" --ro-bind / / true >/dev/null 2>&1; then
            CAN_BWRAP=1
          fi

          # Execution branches: bubblewrap first, fallback to proot
          if [ "$CAN_BWRAP" -eq 1 ]; then
            BWRAP_ARGS=()
            for d in /*; do
              case "$d" in
                /proc|/dev|/sys|/tmp|/run|/var|/nix|/home|/root|/media|/mnt) ;;
                *) [ -d "$d" ] && BWRAP_ARGS+=(--ro-bind "$d" "$d") ;;
              esac
            done

            for d in "''${COMMON_BINDS[@]}"; do
              BWRAP_ARGS+=(--bind "$d" "$d")
            done

            exec "$HERE/bwrap" \
              "''${BWRAP_ARGS[@]}" \
              --proc /proc \
              --dev-bind /dev /dev \
              --ro-bind /sys /sys \
              --bind /tmp /tmp \
              --bind /run /run \
              --bind /var /var \
              --bind "$HOME" "$HOME" \
              --dir /nix \
              --ro-bind "$HERE/nix/store" /nix/store \
              -- "$TARGET" "$@"
          elif [ -x "$HERE/proot" ]; then
            PROOT_ARGS=(-r / -b "$HERE/nix/store:/nix/store")

            for d in /dev /proc /sys /tmp /run /var "$HOME"; do
              [ -d "$d" ] && PROOT_ARGS+=(-b "$d:$d")
            done

            for d in "''${COMMON_BINDS[@]}"; do
              PROOT_ARGS+=(-b "$d:$d")
            done

            exec "$HERE/proot" \
              "''${PROOT_ARGS[@]}" \
              "$TARGET" "$@"
          else
            echo "Error: Neither bwrap nor proot is functional on this system." >&2
            exit 1
          fi
          EOF
          chmod +x AppDir/AppRun

          # 4. Pack SquashFS filesystem
          mksquashfs AppDir squashfs.img \
            -root-owned -noappend \
            -comp zstd -b 1M -Xcompression-level 22

          # 5. Assemble AppImage binary directly with runtime
          mkdir -p "$out"
          FINAL_APPIMAGE="$out/TencentMeeting-${wemeet.version}-x86_64.AppImage"
          cat ${appimageRuntime} squashfs.img > "$FINAL_APPIMAGE"
          chmod +x "$FINAL_APPIMAGE"

          # 6. Generate zsync delta file directly from final AppImage
          cd "$out"
          zsyncmake -u "$(basename "$FINAL_APPIMAGE")" "$FINAL_APPIMAGE"
        '';
      };
    in
      {
        packages.${system} = {
          default = appimage;
          inherit appimage wemeet;
        };
      };
}
