# linux-packaging

Empacotamento Linux compartilhado da suíte Local/Taylor. Um conserto aqui vale
para os 37 repos — que é exatamente o motivo de existir.

## `fix-appimage`

Reempacota o AppImage produzido pelo CI para que ele **funcione fora da distro
em que foi construído**. Conserta dois bugs distintos de empacotamento, os dois
invisíveis no runner do Ubuntu e os dois fatais para o usuário final.

### 1. Tela branca fora do Ubuntu

O empacotador copia para o AppDir toda lib que o binário linka, e nessa varredura
entram `libwayland-*` e as libs de GL. Só que essas falam direto com o **driver
de GPU e o compositor do usuário**. Numa distro com Mesa mais novo que o do
runner — Arch, Fedora, Ubuntu recente — o Mesa do host é carregado junto com a
`libwayland` velha do AppDir e a inicialização do EGL morre:

```
Could not create default EGL display: EGL_BAD_PARAMETER. Aborting...
```

A janela abre e fica **branca**, sem nada na tela dizendo o porquê.

O conserto é deletar essas libs do AppDir: o loader passa a usar as do host, que
são as certas por definição.

### 2. `AppImages require FUSE to run`

O runtime AppImage antigo faz `dlopen` de `libfuse.so.2`. Distro moderna só traz
fuse3, então o app **não abre de jeito nenhum**:

```
dlopen(): error loading libfuse.so.2
```

O conserto é trocar pelo [type2-runtime](https://github.com/AppImage/type2-runtime),
que é `static-pie`, leva o squashfuse dentro e fala fuse3. O usuário não instala
nada.

### Uso

**Tauri:**

```yaml
- name: Consertar o AppImage para outras distros
  uses: Anon5T4R/linux-packaging/fix-appimage@v1
  with:
    path: src-tauri/target/release/bundle/appimage
```

**electron-builder:**

```yaml
- name: Consertar o AppImage para outras distros
  uses: Anon5T4R/linux-packaging/fix-appimage@v1
  with:
    path: dist
```

Coloque logo **depois** do passo que gera o AppImage e **antes** do upload do
artefato. Ele reescreve os `.AppImage` no lugar.

### Rodando local

O mesmo script roda na sua máquina — de propósito. Um conserto de empacotamento
que só pode ser verificado empurrando uma tag não vai ser verificado.

```bash
./fix-appimage/fix-appimage.sh ~/Downloads/MeuApp.AppImage
```

## O que **nunca** entra na lista de remoção

`libEGL.so` e `libGLESv2.so` **sem versão**, na raiz do AppDir. Não são cópias do
Mesa — são o **ANGLE do Chromium**, que o Electron embarca. Apagá-las derruba o
processo de GPU:

```
Failed to load GLES library: libGLESv2.so: cannot open shared object file
Exiting GPU process due to errors during initialization
```

Por isso todo padrão da lista exige `.so.<versão>`: o linuxdeploy sempre copia
soname versionado (`libEGL.so.1`), o ANGLE nunca. Exigir a versão separa as duas
famílias sem precisar saber qual empacotador gerou o AppDir.

Isso foi descoberto quebrando o OpenObsidian de verdade. Se você for ampliar a
lista, **teste em um app Electron e em um Tauri** antes.

## Fora de escopo, de propósito

Isto conserta o AppImage; não substitui pacote nativo. Onde existe `.deb` ou
`.pkg.tar.zst`, o pacote nativo usa o webkit/GTK do sistema e tende a se
comportar melhor — o AppImage é o canal para quem não tem pacote nativo.
