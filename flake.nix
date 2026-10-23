{
  description = "Tencent Meeting (WeMeet) Native FHS AppImage Build Configuration";

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

      wemeetConfig = {
        version = "3.26.10.401";
        url = "https://updatecdn.meeting.qq.com/cos/72e0e0023e1d1e6d4123fba28821aea1/TencentMeeting_0300000000_3.26.10.401_x86_64_default.publish.deb";
        hash = "sha512-rKoeuo7M06W9TLV9wPrc5cM5UIV2d3g5RKwr++++2SfKO0t9nQyehk3Nw7n5+KNZxFbptjs4rA+pQ2/DNqqepw==";
      };

      # Compile libwemeetwrap from the latest AUR wemeet-bin commit
      libwemeetwrap = pkgs.stdenv.mkDerivation {
        pname = "libwemeetwrap";
        version = wemeetConfig.version;

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

      debFile = pkgs.fetchurl {
        url = wemeetConfig.url;
        hash = wemeetConfig.hash;
      };

      appimageRuntime = pkgs.fetchurl {
        url = "https://github.com/AppImage/type2-runtime/releases/latest/download/runtime-x86_64";
        hash = "sha256-YXqncxTVfIuOT66cPws1r3sw1VKctp6Y9k+SUQ7ZikY=";
      };

      appimagetool = pkgs.fetchurl {
        url = "https://github.com/AppImage/appimagetool/releases/latest/download/appimagetool-x86_64.AppImage";
        hash = "sha256-lcvnzOlxf86QxITjQFLufH8ddjWzPBJSW0d2gmp9KbY=";
      };

      appimage = pkgs.stdenvNoCC.mkDerivation {
        pname = "wemeet-appimage";
        version = wemeetConfig.version;
        src = debFile;

        nativeBuildInputs = with pkgs; [
          binutils
          gnutar
          xz
          file
          zsync
        ];

        dontPatchELF = true;
        dontStrip = true;

        unpackPhase = ''
          runHook preUnpack
          ar x $src
          tar -xf data.tar.xz
          runHook postUnpack
        '';

        installPhase = ''
          runHook preInstall

          mkdir -p AppDir/opt/wemeet AppDir/usr/bin AppDir/usr/share AppDir/usr/lib AppDir/etc/fonts

          # 1. Copy wemeet core binaries & assets
          cp -r opt/wemeet/* AppDir/opt/wemeet/
          cp -r usr/share/* AppDir/usr/share/

          # Remove bundled libcurl to avoid OpenSSL 1.1 dependency conflict
          rm -f AppDir/opt/wemeet/lib/libcurl.so* || true

          # Inject compiled AUR wrapper library
          cp ${libwemeetwrap}/lib/libwemeetwrap.so AppDir/opt/wemeet/lib/

          # Critical fix: Coroutine register context restoration assembly bug on modern glibc
          echo -ne '\x49\x83\xfc\x00' | dd of=AppDir/opt/wemeet/lib/libwemeet_base.so bs=1 seek=$((0x94c833)) conv=notrunc

          # Fix internal relative symlinks required by xcast engine
          ln -sf raw/xcast.conf AppDir/opt/wemeet/bin/xcast.conf
          ln -sf ../plugins AppDir/opt/wemeet/lib/plugins
          ln -sf ../resources AppDir/opt/wemeet/lib/resources
          ln -sf ../translations AppDir/opt/wemeet/lib/translations

          # 2. Bundle fallback Chinese font (wqy-microhei)
          mkdir -p AppDir/usr/share/fonts/truetype/wqy
          cp -r ${pkgs.wqy_microhei}/share/fonts/truetype/* AppDir/usr/share/fonts/truetype/wqy/

          # 3. Setup desktop integration and icons
          if [ -d "AppDir/opt/wemeet/icons" ]; then
            cp -r AppDir/opt/wemeet/icons AppDir/usr/share/icons || true
          fi
          install -Dm0644 AppDir/opt/wemeet/wemeet.svg AppDir/usr/share/icons/hicolor/scalable/apps/wemeet.svg

          substituteInPlace AppDir/usr/share/applications/wemeetapp.desktop \
            --replace-fail "/opt/wemeet/wemeetapp.sh" "wemeet" \
            --replace-fail "/opt/wemeet/wemeet.svg" "wemeet"

          ln -sf usr/share/applications/wemeetapp.desktop AppDir/wemeetapp.desktop
          ln -sf usr/share/icons/hicolor/scalable/apps/wemeet.svg AppDir/wemeet.svg
          ln -sf wemeet.svg AppDir/.DirIcon

          # 4. Create isolated fonts.conf covering bundled fonts & host fonts
          cat << 'EOF' > AppDir/etc/fonts/fonts.conf
          <?xml version="1.0"?>
          <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
          <fontconfig>
            <!-- Bundled fallback fonts inside AppImage -->
            <dir prefix="relative">../../usr/share/fonts</dir>

            <!-- Host system fonts -->
            <dir>/usr/share/fonts</dir>
            <dir>/usr/local/share/fonts</dir>
            <dir>/run/current-system/sw/share/fonts</dir>
            <dir prefix="xdg">fonts</dir>
            <dir>~/.local/share/fonts</dir>
            <dir>~/.fonts</dir>

            <!-- Cache settings -->
            <cachedir prefix="xdg">fontconfig</cachedir>
            <cachedir>/tmp/fontconfig-cache</cachedir>

            <!-- Match CJK sans-serif fallback -->
            <match target="pattern">
              <test qual="any" name="family">
                <string>sans-serif</string>
              </test>
              <edit name="family" mode="append" binding="weak">
                <string>WenQuanYi Micro Hei</string>
              </edit>
            </match>
          </fontconfig>
          EOF

          # 5. Create native AppRun entrypoint
          cat << 'EOF' > AppDir/AppRun
          #!/usr/bin/env bash
          set -e

          export APPDIR="''${APPDIR:-$(dirname "$(readlink -f "''${BASH_SOURCE[0]}")")}"
          WEMEET_OPT="$APPDIR/opt/wemeet"

          # Font configuration
          export FONTCONFIG_FILE="$APPDIR/etc/fonts/fonts.conf"
          export FONTCONFIG_PATH="$APPDIR/etc/fonts"

          # Display backend compatibility
          export XDG_SESSION_TYPE=x11
          export QT_QPA_PLATFORM=xcb
          unset WAYLAND_DISPLAY
          export QT_STYLE_OVERRIDE=fusion
          export IBUS_USE_PORTAL=1

          # DRI drivers for hardware acceleration
          export LIBGL_DRIVERS_PATH="/run/opengl-driver/lib/dri:/usr/lib/x86_64-linux-gnu/dri:/usr/lib64/dri:/usr/lib/dri''${LIBGL_DRIVERS_PATH:+:$LIBGL_DRIVERS_PATH}"

          # PulseAudio / PipeWire runtime socket probing
          if [ -z "$PULSE_SERVER" ]; then
            if [ -S "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native" ]; then
              export PULSE_SERVER="unix:''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native"
            elif [ -S "/run/user/$(id -u)/pulse/native" ]; then
              export PULSE_SERVER="unix:/run/user/$(id -u)/pulse/native"
            fi
          fi

          export PATH="$WEMEET_OPT/bin:$PATH"
          export QT_PLUGIN_PATH="$WEMEET_OPT/plugins"
          export XDG_DATA_DIRS="$APPDIR/usr/share:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

          INTERNAL_LIBS="$WEMEET_OPT/lib:$WEMEET_OPT/bin/modules:$WEMEET_OPT/translations"
          if [ -n "$NIX_LD_LIBRARY_PATH" ]; then
            export LD_LIBRARY_PATH="$INTERNAL_LIBS:$NIX_LD_LIBRARY_PATH''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          else
            export LD_LIBRARY_PATH="$INTERNAL_LIBS''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          fi

          # Inject AUR wrapper library
          export LD_PRELOAD="$WEMEET_OPT/lib/libwemeetwrap.so''${LD_PRELOAD:+:$LD_PRELOAD}"

          # Must cd into bin/ directory so the xcast engine can locate relative resources
          cd "$WEMEET_OPT/bin"
          exec "$WEMEET_OPT/bin/wemeetapp" "$@"
          EOF
          chmod +x AppDir/AppRun

          # 6. Package AppImage using appimagetool
          install -m755 ${appimagetool} ./appimagetool

          mkdir -p "$out"
          FINAL_APPIMAGE="$out/TencentMeeting-${wemeetConfig.version}-x86_64.AppImage"

          ARCH=x86_64 ./appimagetool --appimage-extract-and-run \
            --runtime-file "${appimageRuntime}" \
            AppDir "$FINAL_APPIMAGE"

          cd "$out"
          zsyncmake -u "$(basename "$FINAL_APPIMAGE")" "$FINAL_APPIMAGE"
          runHook postInstall
        '';

        meta = with pkgs.lib; {
          description = "Standalone native FHS AppImage of Tencent Meeting (WeMeet)";
          homepage = "https://meeting.tencent.com";
          platforms = [ "x86_64-linux" ];
          license = licenses.unfree;
        };
      };
    in
    {
      packages.${system} = {
        default = appimage;
        inherit appimage;
      };
    };
}
