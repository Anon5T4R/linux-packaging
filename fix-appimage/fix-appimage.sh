#!/usr/bin/env bash
#
# Reempacota AppImage(s) para rodarem fora da distro em que foram construidos.
#
# Uso:
#   fix-appimage.sh <pasta-ou-arquivo.AppImage> [globs extras a remover...]
#
# Roda igual no CI e na sua maquina — de proposito. Um conserto de empacotamento
# que so pode ser verificado empurrando uma tag nao vai ser verificado.
#
# ---------------------------------------------------------------------------
# OS DOIS PROBLEMAS QUE ISTO RESOLVE
#
# 1) TELA BRANCA fora do Ubuntu do runner.
#    O empacotador copia pro AppDir toda lib que o binario linka, e nessa
#    varredura entram libwayland-* e as libs de GL. Só que essas falam direto
#    com o driver de GPU e o compositor DO USUARIO. Numa distro com Mesa mais
#    novo que o do runner, o Mesa do host é carregado junto com a libwayland
#    velha do AppDir e a inicializacao do EGL morre com `EGL_BAD_PARAMETER`:
#    a janela abre e fica branca, sem nenhuma mensagem na tela.
#    Correcao: deletar essas libs do AppDir. O loader passa a usar as do host,
#    que sao as certas por definicao.
#
# 2) "AppImages require FUSE to run" em Arch/Fedora.
#    O runtime antigo faz dlopen de libfuse.so.2. Distro moderna so traz fuse3,
#    entao o app nem abre. O type2-runtime é static-pie, leva squashfuse dentro
#    e fala fuse3 — o usuario final nao instala nada.
#
# Os dois sao de EMPACOTAMENTO: nenhum exige mudanca no codigo do app, e nenhum
# pode ser contornado pelo usuario final sem abrir um terminal.
# ---------------------------------------------------------------------------
set -euo pipefail

IN_PATH="${1:?uso: fix-appimage.sh <pasta-ou-arquivo.AppImage> [globs extras...]}"
shift || true

TOOLS="${APPIMAGE_TOOLS_DIR:-${RUNNER_TEMP:-/tmp}/appimage-tools}"
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
RUNTIME_URL="https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64"

mkdir -p "$TOOLS"
if [ ! -x "$TOOLS/appimagetool" ] || [ ! -s "$TOOLS/runtime-x86_64" ]; then
  echo "baixando appimagetool + type2-runtime em $TOOLS"
  curl -sSfL --retry 3 -o "$TOOLS/appimagetool"    "$APPIMAGETOOL_URL"
  curl -sSfL --retry 3 -o "$TOOLS/runtime-x86_64"  "$RUNTIME_URL"
  chmod +x "$TOOLS/appimagetool" "$TOOLS/runtime-x86_64"
fi

# Libs que conversam com driver de GPU / compositor: sempre do host, nunca do AppDir.
#
# TODO padrao exige `.so.<versao>`, e isso NAO é estetica. O Electron embarca o
# ANGLE do Chromium como `libEGL.so` e `libGLESv2.so` — SEM versao, no mesmo
# diretorio do binario. Sao implementacoes proprias, nao copias do Mesa, e
# apagar as duas derruba o processo de GPU:
#   Failed to load GLES library: libGLESv2.so: cannot open shared object file
#   Exiting GPU process due to errors during initialization
# O linuxdeploy, por outro lado, sempre copia soname versionado (libEGL.so.1).
# Exigir a versao separa as duas familias sem precisar saber qual empacotador
# gerou o AppDir.
HOST_LIBS=(
  'libwayland-client.so.*' 'libwayland-server.so.*'
  'libwayland-egl.so.*'    'libwayland-cursor.so.*'
  'libEGL.so.*'  'libEGL_*.so.*'
  'libGL.so.*'   'libGLX.so.*'  'libGLX_*.so.*'
  'libGLdispatch.so.*' 'libOpenGL.so.*' 'libGLESv2.so.*'
  'libgbm.so.*'  'libdrm.so.*'  'libdrm_*.so.*'
  'libva.so.*'   'libva-drm.so.*' 'libva-x11.so.*'
  'libvulkan.so.*'
)
[ "$#" -gt 0 ] && HOST_LIBS+=("$@")

if [ -d "$IN_PATH" ]; then
  mapfile -t ALVOS < <(find "$IN_PATH" -maxdepth 1 -type f -name '*.AppImage' | sort)
else
  ALVOS=("$IN_PATH")
fi

if [ "${#ALVOS[@]}" -eq 0 ]; then
  echo "erro: nenhum .AppImage encontrado em '$IN_PATH'" >&2
  exit 1
fi

for img in "${ALVOS[@]}"; do
  nome="$(basename "$img")"
  echo "=== $nome ==="
  antes=$(stat -c%s "$img")

  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  cp "$img" "$work/in.AppImage"
  chmod +x "$work/in.AppImage"

  # --appimage-extract é implementado pelo proprio runtime embutido e NAO monta
  # nada, entao funciona em maquina/runner sem fuse2 — que é justamente o caso
  # que estamos consertando.
  ( cd "$work" && ./in.AppImage --appimage-extract >/dev/null )
  appdir="$work/squashfs-root"
  [ -d "$appdir" ] || { echo "erro: falhou ao extrair $nome" >&2; exit 1; }

  removidas=0
  for pat in "${HOST_LIBS[@]}"; do
    while IFS= read -r -d '' f; do
      echo "  - $(basename "$f")"
      rm -f "$f"
      removidas=$((removidas + 1))
    done < <(find "$appdir" -type f -name "$pat" -print0)
  done
  echo "  $removidas lib(s) de host removidas"

  ARCH=x86_64 "$TOOLS/appimagetool" --appimage-extract-and-run \
    --runtime-file "$TOOLS/runtime-x86_64" \
    "$appdir" "$work/out.AppImage" >/dev/null

  # Se o runtime novo ainda pedir libfuse.so.2, o empacotamento voltou a quebrar
  # em Arch/Fedora em silencio. Melhor morrer aqui do que o usuario descobrir.
  if head -c 200000 "$work/out.AppImage" | grep -qa 'libfuse\.so\.2'; then
    echo "erro: $nome ainda referencia libfuse.so.2 — runtime errado" >&2
    exit 1
  fi

  mv "$work/out.AppImage" "$img"
  chmod +x "$img"
  rm -rf "$work"
  trap - EXIT

  depois=$(stat -c%s "$img")
  echo "  ok: $((antes / 1048576))MB -> $((depois / 1048576))MB"
done

echo "AppImage(s) reempacotados: ${#ALVOS[@]}"
