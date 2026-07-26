#!/usr/bin/env bash
#
# Repack de `.deb` → `.pkg.tar.zst` (pacote nativo do Arch/pacman).
#
# ─── Por que repack e não build no Arch ──────────────────────────────────────
#
# O Tauri **não tem alvo pacman** (os alvos são deb, rpm, appimage, nsis, msi,
# app, dmg — conferido na referência da v2). As duas saídas seriam: compilar
# tudo de novo dentro de um container Arch (2ª toolchain completa, ~2× o tempo
# de build, ×31 apps), ou reempacotar o `.deb` que o build normal já produz.
#
# O repack é o que a esmagadora maioria dos pacotes `-bin` do AUR faz, e ele
# entrega o que se queria do formato nativo: **o binário passa a usar o
# webkit2gtk DO SISTEMA** (é o AppImage que carrega o dele, do Ubuntu 22.04),
# o pacman é quem instala/remove/atualiza, e o `.desktop` e os ícones entram
# nos caminhos do sistema em vez de `~/.local`.
#
# Compatibilidade de glibc anda no sentido certo aqui: o binário é linkado
# contra a glibc do Ubuntu 22.04 (2.35) e roda numa glibc mais nova (Arch). O
# contrário é que quebraria.
#
# ─── Metadados: derivados do próprio .deb ────────────────────────────────────
#
# `pkgname` e `pkgver` saem do `control` do .deb, não de constantes repetidas em
# 31 workflows — assim não há um segundo lugar pra desincronizar do bump de
# versão. Descrição e licença vêm por argumento porque o .deb da suíte não as
# tem (o Tauri escreve "A Tauri App" e nenhum campo de licença).
#
# **O `pkgname` é o MESMO do .deb** (ex.: `taylor-hub`), sem o sufixo `-bin` que
# o AUR usaria. É de propósito: o Hub detecta pacote instalado normalizando o
# nome (tira não-alfanumérico, minúsculas), então `taylor-hub` casa com
# "TaylorHub" no pacman e no dpkg **com o mesmo código**. Um `-bin` no meio
# obrigaria a uma segunda regra de casamento só pra uma distro.
#
# Uso (dentro de um container archlinux, como root):
#   deb-to-arch.sh <arquivo.deb> <url> <licenca> <descricao> <dir-de-saida> [bins-do-sistema]
#
# `bins-do-sistema`: lista separada por espaco de binarios que o .deb embute em
# /usr/bin mas que o Arch ja tem como pacote (ex.: `pandoc`). Eles sao REMOVIDOS
# do pacote e viram `depends`. Ver a secao 3b.

set -euo pipefail

DEB="${1:?falta o caminho do .deb}"
URL="${2:?falta a url do projeto}"
LICENSE="${3:?falta a licença}"
PKGDESC="${4:?falta a descrição}"
OUTDIR="${5:?falta o diretório de saída}"
SYSTEM_BINS="${6:-}"

DEB="$(readlink -f "$DEB")"
mkdir -p "$OUTDIR"
OUTDIR="$(readlink -f "$OUTDIR")"

# Fora do /tmp e com permissão de travessia: o `makepkg` roda como um usuário
# SEM privilégio (ele se recusa a rodar como root, e com razão), e um diretório
# 0700 criado pelo root — o que o `mktemp -d` faz — seria intransponível pra ele.
work=/build
rm -rf "$work"
mkdir -p "$work"
cd "$work"

# ── 1. Abrir o .deb ──────────────────────────────────────────────────────────
# `.deb` é um container `ar` com 3 membros (debian-binary, control.tar.*,
# data.tar.*). O `bsdtar` (libarchive) lê `ar` direto, sem o `ar` do binutils —
# e é o mesmo comando que extrai o payload depois. Extrair os membros não
# descomprime nada: é só separar os 3 arquivos.
bsdtar -xf "$DEB"
ctrl_tar="$(ls control.tar.* 2>/dev/null | head -1 || true)"
data_tar="$(ls data.tar.* 2>/dev/null | head -1 || true)"
[ -n "$ctrl_tar" ] || { echo "::error::não achei control.tar.* dentro de $DEB"; exit 1; }
[ -n "$data_tar" ] || { echo "::error::não achei data.tar.* dentro de $DEB"; exit 1; }

bsdtar -xf "$ctrl_tar" ./control
pkgname="$(awk -F': *' '/^Package:/{print $2; exit}' control)"
pkgver="$(awk -F': *' '/^Version:/{print $2; exit}' control)"
deb_depends="$(awk -F': *' '/^Depends:/{print $2; exit}' control || true)"

[ -n "$pkgname" ] && [ -n "$pkgver" ] || {
  echo "::error::control sem Package/Version:"; cat control; exit 1; }

# `pkgver` do Arch não aceita hífen (ele separa pkgver de pkgrel). A suíte usa
# versão limpa (0.23.2), mas um `-1` de revisão debian apareceria aqui — troca
# por `_`, que é a convenção do próprio Arch pra isso. Epoch (`1:`) idem.
pkgver="${pkgver#*:}"
pkgver="${pkgver//-/_}"
echo "pacote: $pkgname $pkgver"

# ── 2. Dependências: nome Debian → nome Arch ─────────────────────────────────
# Tem que ser tabela: os nomes não se derivam um do outro. Dependência que não
# souber traduzir é DESCARTADA COM AVISO — declarar um pacote que não existe no
# Arch deixaria o pacote impossível de instalar, o que é pior que declarar de
# menos (aí o app quebra ao rodar, não ao instalar, e o aviso aqui é o que faz
# alguém perceber antes de o usuário topar com isso).
declare -A MAP=(
  [libwebkit2gtk-4.1-0]=webkit2gtk-4.1
  [libwebkit2gtk-4.0-37]=webkit2gtk
  [libgtk-3-0]=gtk3
  [libayatana-appindicator3-1]=libayatana-appindicator
  [libappindicator3-1]=libappindicator-gtk3
  [librsvg2-2]=librsvg
  [libssl3]=openssl
  [libxdo3]=xdotool
  [libasound2]=alsa-lib
  [libudev1]=systemd-libs
  [libc6]=glibc
  [zlib1g]=zlib
)
depends=()
descartadas=()
IFS=',' read -ra raw <<< "${deb_depends:-}"
for d in "${raw[@]}"; do
  # "libgtk-3-0 (>= 3.24)" → "libgtk-3-0"
  d="$(printf '%s' "$d" | sed 's/(.*)//' | xargs || true)"
  [ -n "$d" ] || continue
  if [ -n "${MAP[$d]:-}" ]; then
    depends+=("${MAP[$d]}")
  else
    descartadas+=("$d")
  fi
done
if [ "${#descartadas[@]}" -gt 0 ]; then
  echo "::warning::dependências do .deb sem equivalente mapeado no Arch (descartadas): ${descartadas[*]}"
fi
# ── 3b. Binarios que o Arch ja tem como pacote ───────────────────────────────
#
# Caso real: o LocalOffice embute o `pandoc` como sidecar do Tauri, e ele cai em
# `/usr/bin/pandoc` — que e exatamente o arquivo do pacote `pandoc` do Arch. Numa
# maquina que o tenha, o `pacman -U` recusa por conflito de arquivo.
#
# Em vez de renomear (o Tauri procura o sidecar pelo nome exato, ao lado do
# executavel), REMOVEMOS o binario embutido e declaramos o pacote como
# dependencia. O sidecar continua sendo encontrado porque o caminho nao muda:
# `/usr/bin/pandoc` passa a ser o do sistema, no mesmo diretorio do executavel.
sistema=()
if [ -n "$SYSTEM_BINS" ]; then
  read -ra sistema <<< "$SYSTEM_BINS"
  for s in "${sistema[@]}"; do
    depends+=("$s")
    echo "binario do sistema: /usr/bin/$s sai do pacote e vira depends=($s)"
  done
fi

echo "depends: ${depends[*]:-(nenhuma)}"

# ── 3. Conflito de arquivo: o motivo nº 1 de um `pacman -U` recusar ──────────
# Pacote de sistema instala em caminho COMPARTILHADO. Se o .deb trouxer um
# binário de nome genérico em /usr/bin (é onde o Tauri põe sidecar declarado em
# `externalBin`), o pacman recusa com "exists in filesystem" na máquina que já
# tiver esse programa — e a mensagem não diz de quem é a culpa. Este aviso é pra
# isso aparecer na build, não no usuário. (Caso real da suíte: o LocalOffice
# leva `/usr/bin/pandoc`.)
mapfile -t em_usr_bin < <(bsdtar -tf "$data_tar" | sed 's|^\./||' | grep -E '^usr/bin/[^/]+$' || true)
echo "binários em /usr/bin: ${em_usr_bin[*]:-(nenhum)}"
if [ "${#em_usr_bin[@]}" -gt 1 ]; then
  echo "::warning::este .deb instala mais de um binário em /usr/bin (${em_usr_bin[*]}) — se algum tiver nome de programa comum, o pacman vai recusar por conflito de arquivo na máquina que já o tenha"
fi

# ── 4. PKGBUILD e makepkg ────────────────────────────────────────────────────
mkdir -p pkgbuild && cp "$DEB" pkgbuild/payload.deb && cd pkgbuild
{
  echo "# Gerado por scripts/deb-to-arch.sh — não editar à mão."
  echo "pkgname=$pkgname"
  echo "pkgver=$pkgver"
  echo "pkgrel=1"
  printf "pkgdesc='%s'\n" "$(printf '%s' "$PKGDESC" | sed "s/'/'\\\\''/g")"
  echo "arch=('x86_64')"
  echo "url='$URL'"
  echo "license=('$LICENSE')"
  if [ "${#depends[@]}" -gt 0 ]; then
    echo "depends=(${depends[*]})"
  fi
  echo "source=('payload.deb')"
  echo "sha256sums=('SKIP')"
  echo "noextract=('payload.deb')"
  # `!strip`: o binário já sai do release do cargo; deixar o makepkg mexer nele
  # é retrabalho e risco à toa. `!debug`: sem isto o makepkg tenta cuspir um
  # pacote `-debug` separado e falha por não achar símbolos.
  echo "options=(!strip !debug emptydirs)"
  # Repassado pro package() como variavel, e nao interpolado no corpo da funcao:
  # o corpo vai num heredoc COM ASPAS, de proposito, pra que `$pkgdir` e `$srcdir`
  # cheguem literais ao makepkg em vez de expandirem aqui como vazio.
  printf "_system_bins='%s'\n" "${sistema[*]:-}"
  cat <<'PKGFN'
package() {
  cd "$srcdir"
  bsdtar -xf payload.deb
  bsdtar -xf data.tar.* -C "$pkgdir"

  # ── Renomear o binario principal pro nome do pacote ───────────────────────
  #
  # O nome do binario vem do `[package].name` do Cargo, que NAO acompanha o
  # nome do app: o TaylorHub instala `/usr/bin/hub` e o LocalCode instala
  # `/usr/bin/code`. Em /usr/bin isso e nome de programa de verdade —
  # `extra/hub` e `extra/code` (o VS Code) existem no Arch, e numa maquina que
  # os tenha o `pacman -U` recusa com "exists in filesystem". O usuario le isso
  # como "o pacote de voces esta quebrado", e nao tem como saber de quem e a
  # culpa.
  #
  # Renomear AQUI, e nao no Cargo.toml, e de proposito: nao muda o nome do .exe
  # no Windows, nao mexe no catalogo do Hub, e o Hub continua achando o binario
  # porque ele o descobre por `pacman -Ql` (primeiro arquivo em /usr/bin), sem
  # nome hardcoded.
  #
  # Quem manda e o `Exec=` do .desktop: e o unico lugar que diz qual dos
  # binarios e o app. Sidecar (ex.: o pandoc do LocalOffice) fica intocado.
  local desktop linha resto primeiro args exec_bin
  desktop="$(find "$pkgdir/usr/share/applications" -maxdepth 1 -name '*.desktop' 2>/dev/null | head -1)"
  if [ -n "$desktop" ]; then
    # `Exec=` pode vir como "hub", "hub %U" ou "/usr/bin/hub %U". Separar o
    # primeiro token dos argumentos preserva o `%U` (sem ele, abrir arquivo
    # pelo gerenciador de arquivos para de funcionar).
    linha="$(grep -m1 '^Exec=' "$desktop" || true)"
    resto="${linha#Exec=}"
    primeiro="${resto%% *}"
    args="${resto#"$primeiro"}"
    exec_bin="$(basename "$primeiro")"

    if [ -n "$exec_bin" ] && [ "$exec_bin" != "$pkgname" ] \
       && [ -f "$pkgdir/usr/bin/$exec_bin" ]; then
      mv "$pkgdir/usr/bin/$exec_bin" "$pkgdir/usr/bin/$pkgname"
      sed -i "s|^Exec=.*|Exec=$pkgname$args|" "$desktop"
      sed -i "s|^TryExec=.*|TryExec=$pkgname|" "$desktop"

      # `StartupWMClass` TEM que acompanhar o rename, e isto nao e detalhe.
      #
      # E por ele que o GNOME casa a JANELA EM EXECUCAO com a entrada .desktop,
      # e dai tira o icone do dock. O Tauri escreve ali o nome do binario, e o
      # app_id que a janela anuncia sai do basename do argv[0] — ou seja, do
      # mesmo nome. Renomear o binario sem mexer aqui quebra o par: o app abre,
      # funciona, e aparece no dock com icone generico, sem nenhum erro.
      #
      # `Icon=` NAO muda de proposito: o arquivo de icone continua com o nome
      # antigo dentro do pacote, e e ele que o `Icon=` resolve.
      if grep -q '^StartupWMClass=' "$desktop"; then
        sed -i "s|^StartupWMClass=.*|StartupWMClass=$pkgname|" "$desktop"
      else
        echo "StartupWMClass=$pkgname" >> "$desktop"
      fi

      echo "binario renomeado: /usr/bin/$exec_bin -> /usr/bin/$pkgname"
      grep -E '^(Exec|TryExec|StartupWMClass|Icon)=' "$desktop"
    fi

    # ── App fora de /usr/bin (Electron): criar o ponto de entrada ───────────
    #
    # O .deb do electron-builder instala tudo em /opt/<App>/ e o `.desktop`
    # aponta pra la; NADA vai pra /usr/bin. Duas consequencias: nao ha comando
    # pra chamar do terminal, e o Hub — que descobre o executavel pelo primeiro
    # arquivo em /usr/bin (`pacman -Ql`) — nao acha nada e nao consegue abrir o
    # app. Um symlink resolve os dois, sem tocar no `Exec=`, que ja funciona.
    if [ ! -d "$pkgdir/usr/bin" ] || [ -z "$(ls -A "$pkgdir/usr/bin" 2>/dev/null)" ]; then
      if [ -n "$primeiro" ] && [ -f "$pkgdir$primeiro" ]; then
        install -d "$pkgdir/usr/bin"
        ln -s "$primeiro" "$pkgdir/usr/bin/$pkgname"
        echo "ponto de entrada criado: /usr/bin/$pkgname -> $primeiro"
      else
        echo "::warning::nada em /usr/bin e o Exec do .desktop ($primeiro) nao existe no pacote — o Hub nao vai conseguir abrir este app"
      fi
    fi
  fi

  # ── Binarios que o Arch ja tem como pacote ────────────────────────────────
  # Removidos aqui e declarados em `depends` (ver secao 3b). O caminho nao muda
  # — /usr/bin/<bin> passa a ser o do sistema — entao o sidecar do Tauri, que
  # procura ao lado do executavel, continua encontrando.
  local sb
  for sb in $_system_bins; do
    if [ -e "$pkgdir/usr/bin/$sb" ]; then
      rm -f "$pkgdir/usr/bin/$sb"
      echo "removido do pacote (vem do sistema): /usr/bin/$sb"
    else
      echo "::warning::pediram pra tirar /usr/bin/$sb mas ele nao esta no .deb"
    fi
  done
}
PKGFN
} > PKGBUILD

echo "--- PKGBUILD ---"; cat PKGBUILD; echo "----------------"

# `--nodeps` porque aqui não se compila nada: as dependências são METADADO pro
# pacman resolver na máquina do usuário, não requisito desta build.
useradd -m builder 2>/dev/null || true
chown -R builder "$work"
# `PACKAGER` aparece no `pacman -Qi` que o usuário lê; sem ele o pacman escreve
# "Unknown Packager", que num pacote de distribuição lê como coisa inacabada.
su builder -s /bin/bash -c \
  "cd '$work/pkgbuild' && PACKAGER='Anon5T4R <https://github.com/Anon5T4R>' makepkg --nodeps --noconfirm"

pkg="$(ls ./*.pkg.tar.zst 2>/dev/null | head -1 || true)"
[ -n "$pkg" ] || { echo "::error::makepkg terminou sem gerar .pkg.tar.zst"; exit 1; }
cp "$pkg" "$OUTDIR/"
saida="$OUTDIR/$(basename "$pkg")"
echo "gerado: $(basename "$pkg") ($(du -h "$saida" | cut -f1))"

# ── 5. Conferir o que foi empacotado ─────────────────────────────────────────
# Não é enfeite de log: um repack que "funciona" e sai VAZIO é o modo de falha
# mais fácil daqui (um caminho errado no bsdtar não vira erro, vira um tar sem
# nenhum match). Contar arquivo de verdade é o que separa os dois casos.
n="$(bsdtar -tf "$saida" | grep -cvE '^\.(PKGINFO|MTREE|BUILDINFO|INSTALL)$' || true)"
echo "arquivos no pacote (fora os metadados): $n"
[ "$n" -ge 2 ] || { echo "::error::o pacote saiu praticamente vazio ($n arquivos)"; exit 1; }
bsdtar -tf "$saida" | grep -E '^(usr/bin/|usr/share/applications/)' || {
  echo "::error::o pacote não tem binário em /usr/bin nem entrada .desktop"; exit 1; }
