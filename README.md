# CANPass

> **v1.4.13** — Stream de câmeras V4L2/CSI/IP via RTSP/HLS/WebRTC com gravação por detecção de movimento, watchdog, instalação automatizada e instalador de drivers de câmera e-con para NVIDIA Jetson AGX Orin.

## Descrição

CANPass é um conjunto de utilitários em **shell script** para **Linux embarcado / NVIDIA Jetson AGX Orin**, com dois propósitos:

1. **Stream e gravação de câmera** (alias `canpass`): detecta câmeras V4L2, CSI (Jetson) e IP (RTSP), sobe um servidor RTSP/HLS/WebRTC (MediaMTX em Docker) e grava em MP4 por **detecção de movimento**.
2. **Instalação de drivers de câmera e-con** na Jetson AGX Orin (`install_drivers.sh`).

> **Nota:** apesar do nome, **não há código de barramento CAN** neste repositório — o nome é histórico. Os padrões C/C++/CMake/vcpkg no `.gitignore` são herança do template inicial e não refletem o projeto.

## Instalação

### Requisitos

- Ubuntu 22.04 LTS / L4T (ou derivado)
- Acesso à internet
- Permissão `sudo`
- Para a câmera CSI (Jetson AGX Orin): Orin flasheado em **L4T 35.2.1 / JP 5.1.0**

### Instalar

Cole o comando abaixo no terminal e execute. Ele clona o repositório **com Git LFS**
(necessário para obter o pacote do driver) e roda a instalação completa:

```bash
sudo apt-get update && sudo apt-get install -y git git-lfs && git lfs install && git clone https://github.com/SEESTEC/CANPass.git "$HOME/CANPass" && cd "$HOME/CANPass" && git lfs pull && sudo bash install.sh
```

> ⚠️ **Não use o download `.zip` do GitHub:** ele não inclui o conteúdo Git LFS, então o
> pacote do driver (~735 MB) viria como um ponteiro quebrado. Use `git clone` + `git lfs pull`.

A instalação é **totalmente automática** — nenhuma configuração manual é necessária. Ela cuida de:

- Instalar `ffmpeg`, `v4l-utils`, `docker` (via `docker-install.sh` embutido) e, em Jetson, o GStreamer NVIDIA
- Adicionar o usuário ao grupo `docker` e configurar o sudoers do `nvargus-daemon` (Jetson)
- **Instalar automaticamente o driver da câmera e-CAM82 (IMX485)** em Jetson, de forma não-interativa (opção 1, 4 lanes), se a câmera ainda não estiver enumerando
- Copiar `cam_view.sh` e `watchdog.sh` para `/usr/bin/`
- Registrar o alias `canpass` em `~/.bashrc`
- Criar e registrar o serviço systemd `canpass`

**Após a instalação:**

```bash
source ~/.bashrc
canpass
```

> Se o driver da câmera foi instalado agora, **reinicie o Orin** (`sudo reboot`) para ele entrar em vigor.
> Se for a primeira vez usando Docker, pode ser necessário fazer logout/login ou executar `newgrp docker` para que o grupo seja aplicado à sessão atual.

---

## Utilitários

### `cam_view.sh` — Visualizador e transmissor de câmera

Detecta câmeras V4L2, sobe um servidor RTSP/HLS via Docker e transmite o stream da câmera selecionada. Grava automaticamente quando detecta movimento.

**Uso básico** (só stream, sem janela local):

```bash
canpass
```

**Com exibição local** (abre janela ffplay além do stream):

```bash
canpass --display
```

**Preview local no monitor do Orin** (apenas exibe na tela; sem rede/encode/gravação):

```bash
canpass --local
```

Para câmeras CSI (Jetson) vai direto `nvarguscamerasrc → nv3dsink` — menor latência e
melhor qualidade possível, ideal para visualizar no monitor ligado ao Orin. Rode num
terminal do **desktop do Orin** (precisa de sessão gráfica). Ajuste resolução/FPS com
`CANPASS_CSI_RES` (padrão do preview local: `1920x1080@60`; ex.: `CANPASS_CSI_RES=3840x2160@60 canpass --local`).

**Fluxo:**

1. Verifica permissão Docker e sobe o container `mediamtx` (RTSP/HLS) se necessário.
2. Varre `/dev/video*` filtrando apenas dispositivos de captura real.
3. Se houver mais de uma câmera, solicita seleção interativa.
4. Inicia `ffmpeg` em background capturando o dispositivo e enviando H.264 ao MediaMTX.
5. Exibe os endereços de acesso ao stream.
6. Inicia gravação por detecção de movimento em background.
7. Com `--display`: abre `ffplay` lendo do RTSP para visualização local.
8. Pressione **Ctrl+C** (modo headless) ou **Q** (modo `--display`) para encerrar.

**Endpoints disponíveis após iniciar:**

| Protocolo | Endereço                        | Latência   | Acesso                            |
|-----------|---------------------------------|------------|-----------------------------------|
| RTSP      | `rtsp://<ip>:8554/stream`       | ~50 ms     | VLC, ffplay, câmeras IP           |
| WebRTC    | `http://<ip>:8889/stream`       | ~100 ms    | Navegador (recomendado)           |
| HLS       | `http://<ip>:8888/stream`       | ~200 ms    | Navegador (fallback)              |

> **Latência alta?** Use o endpoint **WebRTC** (`:8889`) ou **RTSP** (VLC/ffplay), não o HLS —
> o HLS tem segundos de buffer por natureza. Em Jetson, o stream CSI usa o encoder de
> **hardware** (NVENC) por padrão; ajuste a nitidez com `CANPASS_CSI_BITRATE` e a resolução
> com `CANPASS_CSI_RES` (ex.: `CANPASS_CSI_RES=3840x2160@30 CANPASS_CSI_BITRATE=20000000 canpass`).

---

### `watchdog.sh` — Supervisor de processo

Supervisiona o `cam_view.sh` e reinicia automaticamente em caso de falha inesperada. Encerramento explícito pelo usuário (Ctrl+C ou SIGTERM) **não** dispara reinício.

O alias `canpass` aponta para o `watchdog.sh`, portanto o supervisor é sempre ativado ao chamar o comando.

**Serviço systemd:**

```bash
sudo systemctl start   canpass   # inicia agora
sudo systemctl enable  canpass   # habilita no boot
sudo systemctl status  canpass   # verifica estado
sudo systemctl stop    canpass   # encerra
```

---

### Gravação por detecção de movimento

A gravação ocorre apenas quando movimento é detectado, independente de usar ou não o modo `--display`. Os arquivos são salvos em `~/canpass_rec/` por padrão (sobreponível via `CANPASS_REC_DIR`).

**Formato do nome:**

```
dd-mm-aaaa_hh-mm-ss_hh-mm-ss.mp4
 └─ data   └─ início  └─ fim real
```

Exemplo: `11-05-2026_14-32-00_14-35-47.mp4`

| Variável de ambiente     | Padrão          | Descrição                                                                      |
|--------------------------|-----------------|--------------------------------------------------------------------------------|
| `MOTION_THRESHOLD`       | `0.02`          | Fração de pixels alterados que caracteriza movimento (0.0–1.0)                 |
| `MOTION_COOLDOWN_SECS`   | `30`            | Segundos sem movimento antes de encerrar a gravação                            |
| `CANPASS_REC_DIR`        | `~/canpass_rec` | Diretório de destino das gravações                                             |
| `CANPASS_CSI_RES`        | `1920x1080@30`  | Resolução e FPS da câmera CSI (Jetson). Ex: `1280x720@30`                      |
| `CANPASS_CSI_SENSORS`    | `0`             | IDs dos sensores CSI a listar, separados por espaço. Ex: `0 1`                 |
| `CANPASS_NO_CLOCK_BOOST` | _(desativado)_  | Defina como `1` para **não** maximizar os clocks do Jetson antes do stream CSI |
| `CANPASS_CSI_BITRATE`    | `8000000`       | Bitrate do encoder H.264 da câmera CSI, em bps. Ex: `20000000` para 4K nítido  |
| `CANPASS_CSI_ENCODER`    | `auto`          | Encoder da câmera CSI: `auto`/`hw` (NVENC por hardware) ou `sw` (libx264)      |

```bash
MOTION_THRESHOLD=0.05 MOTION_COOLDOWN_SECS=30 canpass
```

**Como funciona:**

```
RTSP → ffmpeg detector (select filter) → scores de cena → máquina de estados bash
                                                                    ↓
                                                       ffmpeg recorder (-c copy → MP4)
```

O detector lê o stream RTSP e emite apenas frames onde ≥ `MOTION_THRESHOLD` da imagem mudou. A máquina de estados inicia a gravação ao detectar movimento e a encerra após `MOTION_COOLDOWN_SECS` segundos sem atividade.

**Diagnóstico (câmera não detectada):**

```bash
lsusb                       # verifica reconhecimento USB
lsmod | grep uvcvideo       # verifica driver de webcam
dmesg | grep video          # log do kernel
sudo usermod -aG video $USER && newgrp video   # adiciona usuário ao grupo video
```

---

## Drivers de câmera e-con (Jetson AGX Orin)

O projeto tem **duas câmeras alternáveis** (uma por boot, via `canpass-camera switch`):

- **e-CAM82_CUOAGX** (principal): **MIPI CSI-2**, sensor **Sony IMX485** com ISP externo,
  via **Argus/V4L2** (`nvarguscamerasrc` / `/dev/video*`). **NÃO é GMSL.**
- **NileCAM81_CUOAGX** (alternativa): **GMSL2**, sensor **AR0821** — exige o kit GMSL
  (desserializadora `e-CAM_CUOAGX_DESER_6H01R1` no J509 + serializador + coax FAKRA + 12 V).

> A instalação principal (`install.sh`) **já instala o driver da e-CAM82 automaticamente**
> em Jetson, de forma não-interativa. Rode `install_drivers.sh` à mão para reinstalar,
> instalar o da NileCAM81 ou escolher outro pacote.

O `install_drivers.sh` deve ser executado **no próprio Orin** (aarch64), a partir da raiz deste repositório:

```bash
sudo bash install_drivers.sh          # interativo (menu de opções)
sudo bash install_drivers.sh --auto   # não-interativo: e-CAM82 IMX485, 4 lanes
```

| Opção   | Pacote                         | Alvo                                          | Observação                          |
|---------|--------------------------------|-----------------------------------------------|-------------------------------------|
| **1** ✓ | **e-CAM82 (IMX485, MIPI)**     | L4T 35.2.1 / JP 5.1.0 (kernel 5.10.104-tegra) | **Câmera principal do projeto**     |
| **2** ✓ | **NileCAM81 (GMSL/AR0821)**    | L4T 35.2.1 / JP 5.1.0 (kernel 5.10.104-tegra) | **Câmera alternativa** — build R02 solicitado à e-con (2026-06); **mesmo flash** da e-CAM82, alternância sem reflash. Exige o kit GMSL no J509 |
| 3 ⚠     | [GMSL] e-CAM YUV OCTA (AR0821) | L4T 36.4.3 / JP 6.2.0                         | **OUTRO produto**                   |
| 4 ⚠     | [GMSL] NileCAM81 p/ JP6        | L4T 36.3.0 / JP 6.0.0                         | Exige reflash p/ JP6 — use a opção 2 |

> ⚠️ **Atenção:** instalar um driver **GMSL** errado na e-CAM82 (IMX485) causa os erros `ser_status=f0` / `ret=-121`. Câmera, cabo e alimentação não são o problema nesse caso — é o driver errado.

**Requisito de flash:** o instalador da e-con confere `/etc/nv_tegra_release` e **aborta** se o L4T do flash não casar **exatamente** com o alvo do pacote. Para as opções 1 e 2, o Orin precisa estar em **L4T 35.2.1 / JP 5.1.0** (kernel `5.10.104-tegra`). A e-CAM82 usa **4 lanes**; a NileCAM81 é two-lane (DTB único do pacote).

**Comportamento do instalador da e-con (opções 1 e 2):** substitui `/boot/Image` e o DTB
genérico (backup automático em `~/Images_Backup`) e **reboota o Orin sozinho ao final**.
O `install_drivers.sh` copia antes os **DTBs com nome próprio** (`*eimx485*.dtb` /
`*nilecam81*.dtb`) para `/boot` — são eles que o `canpass-camera switch` aponta na linha
`FDT` do extlinux para alternar as câmeras. Após o reboot, fixe a câmera desejada:
`canpass-camera switch ecam82|nilecam81`.

Após instalar, validar a captura com o app `eCAM_argus_camera` (libargus) que acompanha o pacote.

No caminho CSI, o `cam_view.sh` **maximiza automaticamente os clocks** do Jetson (`nvpmodel -m 0`, `jetson_clocks` e, se presente, o `max-isp-vi-clks.sh` da e-con) para obter o frame rate máximo — sem senha, via regras NOPASSWD criadas pelo `install.sh`. Para desativar, exporte `CANPASS_NO_CLOCK_BOOST=1`.

> Os pacotes de driver são grandes (centenas de MB) e versionados via **Git LFS** — é necessário `git lfs install` antes do clone para obtê-los.

---

## Controles da câmera (resolução, Flicker, WDR, auto-exposure)

📄 **[`doc/ecam82/README.md`](doc/ecam82/README.md)** — referência completa: **Table 1**
(resolução × FPS), tabela de **Flicker** (`aeantibanding`) e todos os parâmetros de
**auto-exposure** do `nvarguscamerasrc` com faixas reais, além de **WDR/HDR** via V4L2.

O preview local `canpass-camera preview` imprime essas tabelas num banner e aceita
ajuste por ambiente (ex.: 60 Hz + WDR + ganho limitado):

```bash
CANPASS_FLICKER=3 CANPASS_HDR=1 CANPASS_GAINRANGE="1 8" canpass-camera preview
```

### `canpass-camera` — alternar câmera e preview local

Comando para **alternar** entre e-CAM82 (MIPI) e NileCAM81 (GMSL) no mesmo flash —
trocando o DTB ativo (linha `FDT` do `extlinux.conf`), sem reflash — e para
**preview local** (`nvarguscamerasrc → nv3dsink`).

```bash
canpass-camera <comando> [argumento]
```

Sem argumentos, executa `status`.

| Comando                    | Argumento               | O que faz                                                                                                                                                                                                                                                                                                                                                                                 |
|----------------------------|-------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `status`                   | —                       | Mostra o `FDT` ativo no `extlinux.conf`, qual câmera ele representa e se `/dev/video0` está presente (câmera enumerada).                                                                                                                                                                                                                                                                  |
| `list`                     | —                       | Lista os DTBs candidatos encontrados em `/boot` para cada câmera (padrões de busca: `imx485/e-cam82/ecam82` e `nilecam/ar0821/0821/max96712`).                                                                                                                                                                                                                                            |
| `switch`                   | `ecam82` \| `nilecam81` | Troca o DTB ativo: faz **backup** do `extlinux.conf` (`.canpass.bak.<timestamp>`), edita/insere a linha `FDT`, confirma a edição (restaura o backup se falhar), imprime os **passos físicos** (trocar a base board no conector J509) e oferece reboot. Se o DTB da câmera pedida não existir em `/boot`, **aborta com instrução** — de propósito, para não deixar o Orin sem boot válido. |
| `preview`                  | `[ecam82\|nilecam81]`   | Preview local no monitor do Orin. Sem argumento, **infere a câmera ativa** pelo `FDT`. Imprime o banner de controles (Table 1 + Flicker + auto-exposure), abre um **menu de resolução** e roda `nvarguscamerasrc → nv3dsink`. Reinicia o `nvargus-daemon` antes (sessões mal encerradas o invalidam). Ctrl+C encerra.                                                                     |
| `update`                   | —                       | `git pull --ff-only` no repositório-fonte + recopia os scripts (`canpass-camera`, `canpass-can`, `cam_view.sh`, `watchdog.sh`) para `/usr/bin`. Acha o repo via `CANPASS_SRC`, registro do install ou `~/CANPass`. Não mexe em deps/serviço (para isso, `sudo bash install.sh`).                                                                                                          |
| `help` (ou `-h`, `--help`) | —                       | Mostra o uso.                                                                                                                                                                                                                                                                                                                                                                             |

**Resoluções oferecidas no menu do `preview`** (Table 1 — Maximum Frame Rate, 4 lanes):

| Câmera                                 | Opções                                             |
|----------------------------------------|----------------------------------------------------|
| e-CAM82 (confirmado, Rev 1.4)          | `1920x1080@90` · `3840x2160@60` (50 fps em 12-bit) |
| NileCAM81 (⚠ estimativa, a confirmar) | `3840x2160@30` · `1920x1080@60` · `1280x720@60`    |

**Variáveis de ambiente — comportamento do comando:**

| Variável                  | Padrão                                | Efeito                                                                  |
|---------------------------|---------------------------------------|-------------------------------------------------------------------------|
| `CANPASS_DTB_ECAM82`      | _(auto-detecção em /boot)_            | Força o caminho do `.dtb` da e-CAM82                                    |
| `CANPASS_DTB_NILECAM81`   | _(auto-detecção em /boot)_            | Força o caminho do `.dtb` da NileCAM81                                  |
| `CANPASS_SENSOR_ID`       | `0`                                   | `sensor-id` do `nvarguscamerasrc` no preview (e `/dev/video<N>` p/ WDR) |
| `CANPASS_EXTLINUX`        | `/boot/extlinux/extlinux.conf`        | Caminho do extlinux.conf                                                |
| `CANPASS_SRC`             | _(registro do install / `~/CANPass`)_ | Repositório-fonte usado pelo `update`                                   |

**Variáveis de ambiente — imagem no `preview`** (cada uma vira a propriedade
correspondente do `nvarguscamerasrc`; só são aplicadas as que você definir):

| Variável               | Propriedade Argus                     | Faixa / valores                                               |
|------------------------|---------------------------------------|---------------------------------------------------------------|
| `CANPASS_FLICKER`      | `aeantibanding`                       | `0`=Off · `1`=Auto (padrão) · `2`=50 Hz · `3`=60 Hz           |
| `CANPASS_EXPOSURECOMP` | `exposurecompensation`                | `-2.0 .. 2.0` (padrão 0)                                      |
| `CANPASS_EXPTIME`      | `exposuretimerange`                   | `"min max"` em ns (ex.: `"34000 33333333"`)                   |
| `CANPASS_GAINRANGE`    | `gainrange`                           | `"min max"` (ex.: `"1 16"`)                                   |
| `CANPASS_ISPGAIN`      | `ispdigitalgainrange`                 | `"min max"` (ex.: `"1 8"`)                                    |
| `CANPASS_AELOCK`       | `aelock`                              | `true`\|`false` (congela a exposição)                         |
| `CANPASS_AWBLOCK`      | `awblock`                             | `true`\|`false`                                               |
| `CANPASS_WBMODE`       | `wbmode`                              | `0..9` (1=auto, 5=daylight, 9=manual)                         |
| `CANPASS_SATURATION`   | `saturation`                          | `0.0 .. 2.0` (padrão 1)                                       |
| `CANPASS_TNR_MODE`     | `tnr-mode`                            | `0..2` (Off/Fast/HQ)                                          |
| `CANPASS_TNR_STRENGTH` | `tnr-strength`                        | `-1.0 .. 1.0`                                                 |
| `CANPASS_EE_MODE`      | `ee-mode`                             | `0..2` (Off/Fast/HQ)                                          |
| `CANPASS_EE_STRENGTH`  | `ee-strength`                         | `-1.0 .. 1.0`                                                 |
| `CANPASS_AEREGION`     | `aeregion`                            | `"left top right bottom peso"`                                |
| `CANPASS_SENSOR_MODE`  | `sensor-mode`                         | `-1..4` (-1 = melhor match)                                   |
| `CANPASS_HDR`          | `hdr_enable` (**V4L2**, driver e-con) | `0`\|`1` — aplicado via `v4l2-ctl` **antes** de abrir o Argus |

Exemplos:

```bash
canpass-camera status                                                           # qual câmera está ativa?
canpass-camera list                                                             # quais DTBs existem em /boot?
canpass-camera switch nilecam81                                                 # trocar p/ NileCAM81 (backup + FDT + reboot)
canpass-camera preview                                                          # preview da câmera ativa
CANPASS_FLICKER=3 CANPASS_HDR=1 CANPASS_GAINRANGE="1 8" canpass-camera preview  # 60 Hz + WDR + ganho limitado
CANPASS_AELOCK=true canpass-camera preview ecam82                               # trava a exposição ("explosão de luz")
CANPASS_SENSOR_ID=1 canpass-camera preview                                      # outro sensor CSI
```

> **Dica "explosão de luz":** estreite `CANPASS_EXPTIME` + `CANPASS_GAINRANGE`,
> ou use `CANPASS_AELOCK=true`. Referência completa dos controles: [`doc/e-CAM82/README.md`](doc/e-CAM82/README.md).

> As duas câmeras **não rodam juntas** (conector J509 e device tree únicos):
> é alternar, uma por boot. O driver da NileCAM81 para **L4T 35.2.1** está no repo
> (`doc/NileCAM81/NileCAM81_CUOAGX/JP5.1.0_L4T35.2.1/`) — instale com
> `sudo bash install_drivers.sh` (opção 2); enquanto o DTB dela não estiver em `/boot`,
> o `switch nilecam81` aborta com instrução (de propósito, p/ não deixar o Orin sem boot).
> O `canpass` (menu de câmeras) anuncia qual das duas está ativa no boot atual.
> Análise em [`doc/NileCAM81/COMPATIBILIDADE.md`](doc/NileCAM81/COMPATIBILIDADE.md).

---

## Leitura de CAN (adaptador USB CANable)

Para ler um barramento CAN no Orin via um **CANable** (USB→CAN, driver `gs_usb`) — ex.: a rede **J1939** de uma máquina Caterpillar (250 kbit/s, IDs de 29 bits):

```bash
sudo apt-get install -y can-utils    # candump/canplayer (só na primeira vez)
canpass-can <comando> [bitrate]
```

Sem argumentos, executa `detect`. O `[bitrate]` é opcional em todos os comandos que o
aceitam — padrão **250000** (J1939), sobreponível por `CANPASS_CAN_BITRATE`.

| Comando                    | Parâmetro   | O que faz                                                                                                                                                                                                                                                                             |
|----------------------------|-------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `detect` | — | Lista as interfaces `can*` com seu driver e aponta qual é o CANable (`gs_usb`), ignorando os CAN nativos do Orin (`mttcan`). Confere também a presença no USB (`lsusb`). |
| `up` | `[bitrate]` | Só sobe a interface: listen-only, `restart-ms 100` (auto-recupera de bus-off) e desliga o **autosuspend USB** do adaptador (causa clássica de "parou de receber"). |
| `dump` | `[bitrate]` | `up` + `candump -tA` no terminal — timestamp com **data+hora real**. **Supervisionado** (re-detecta queda da interface + watchdog de fluxo). Ctrl+C encerra. |
| `ascii` (ou `text`) | `[bitrate]` | `up` + `candump -tA -a`: hex + coluna **ASCII** do payload (`.` = byte não-imprimível). Útil p/ frames com texto (VIN, IDs de software); dados binários viram ponto/lixo (normal). **Supervisionado.** |
| `sniff` | `[bitrate]` | Monitora **bytes que mudam**: imprime uma linha só quando algum byte de um ID muda, com o byte alterado em **vermelho**. Funciona com IDs de 29 bits (J1939), ao contrário do `cansniffer` do can-utils. Ideal p/ mapear ID/byte de cada eixo do joystick — mexa **um** eixo por vez. **Supervisionado** — o estado dos bytes sobrevive às reciclagens. |
| `log` (ou `record`) | `[bitrate]` | `up` + grava os frames em **arquivo** `can_YYYYMMDD_HHMMSS.log` (detalhes abaixo). **Supervisionado.** Ctrl+C encerra. |
| `selftest` (ou `test`) | `[bitrate]` | **Loopback interno**: envia 1 frame de teste e espera o eco — prova controlador + driver gs_usb + USB **sem depender do barramento**. PASS = adaptador OK (se o `dump` segue vazio, o problema é fiação/transceiver/bus quieto); FAIL = adaptador travado/morto (replugue o USB — down/up não reseta o firmware). Pede confirmação de que o adaptador está **desconectado do veículo** e deixa a interface DOWN ao final. |
| `status` | — | `ip -details -statistics link show`: estado e contadores. Bitrate certo = `ERROR-ACTIVE`, erros parados, RX subindo; bitrate errado = `ERROR-PASSIVE`/`bus-off`. **Tudo zerado (até `bus-errors`) = barramento mudo no conector** — chave desligada, fiação ou adaptador. |
| `down` | — | Derruba a interface. |
| `help` (ou `-h`, `--help`) | — | Mostra o uso. |

**`log` — gravação em arquivo (sincronizável com o vídeo):**

- Destino: `CANPASS_CAN_LOGDIR` → senão `CANPASS_REC_DIR` → senão `~/canpass_rec` —
  o **mesmo diretório das gravações de vídeo**, para manter vídeo + CAN juntos.
- Formato padrão: `candump -L` — timestamp **epoch**, **replayável** com
  `canplayer -I <arquivo>`. O epoch é o mesmo relógio do vídeo → permite casar
  imagem ↔ frame CAN depois. Com `CANPASS_CAN_LOG_HUMAN=1` grava data+hora legível
  (`-tA`), porém **não replayável**.
- Acompanhe ao vivo em outro terminal: `tail -f <arquivo>`. A cada 15 s o terminal
  mostra um "vivo HH:MM:SS — N frames recebidos".

**Supervisão — vale para `dump`, `ascii`, `sniff` e `log`:**

- **Auto-resume**: se o candump morrer (interface caiu/reenumerou), re-detecta o CANable
  pelo driver e retoma (o `log` continua **no mesmo arquivo**); se o CANable sumir do
  USB, espera reaparecer.
- **Watchdog de fluxo**: sem frame novo por `CANPASS_CAN_STALL_SECS` s (padrão 6),
  recicla a interface (cobre o caso "candump vivo mas RX travado" do gs_usb). Num
  barramento mudo, avisa na 1ª reciclagem e depois só a cada ~10 ("chave da máquina
  ligada? fiação?"); quando os frames voltam, anuncia "RX voltou".

**Variáveis de ambiente:**

| Variável | Padrão | Efeito |
|---|---|---|
| `CANPASS_CAN_IF` | _(auto-detecção)_ | Força a interface (ex.: `can2`), pulando a busca pelo driver `gs_usb` |
| `CANPASS_CAN_BITRATE` | `250000` | Bitrate padrão quando `[bitrate]` não é passado |
| `CANPASS_CAN_ACTIVE` | `0` | `=1` sobe **sem** listen-only — permite transmitir (`cansend`). **Cuidado em veículo** |
| `CANPASS_CAN_LOGDIR` | `CANPASS_REC_DIR` → `~/canpass_rec` | Diretório dos arquivos do `log` |
| `CANPASS_CAN_LOG_HUMAN` | `0` | `=1` grava o `log` com data+hora legível (`-tA`) — **não replayável** |
| `CANPASS_CAN_STALL_SECS` | `6` | Segundos sem frame antes de o watchdog (`dump`/`ascii`/`sniff`/`log`) reciclar a interface |

Exemplos:

```bash
canpass-can detect                            # qual interface é o CANable?
canpass-can dump                              # ler no terminal @ 250 kbit/s (J1939)
canpass-can dump 500000                       # idem @ 500 kbit/s
canpass-can ascii                             # payload também como texto
canpass-can sniff                             # achar o ID/byte de um eixo do joystick
canpass-can log                               # gravar em arquivo p/ sync com o vídeo
CANPASS_CAN_LOGDIR=/data/can canpass-can log  # log em outro diretório
CANPASS_CAN_LOG_HUMAN=1 canpass-can log       # log legível (sem replay)
CANPASS_CAN_IF=can2 canpass-can dump          # força a interface
CANPASS_CAN_ACTIVE=1 canpass-can up           # modo ativo (transmite!)
canpass-can selftest                          # adaptador OK? (loopback — FORA do veículo)
canpass-can status                            # diagnóstico (bitrate certo? RX subindo?)
canpass-can down
```

- Resolve a interface pelo **driver `gs_usb`**, não pelo nome — o Orin tem CAN nativo
  (`mttcan`, em `can0/can1`) que confunde, e o nome do CANable muda ao reenumerar o USB.
- **Listen-only por padrão**: não transmite, não dá ACK, não injeta frames de erro —
  não perturba a rede do veículo nem vai a bus-off.
- **CANable não encontrado?** Replugue e cheque: `lsusb | grep -iE '1d50:606f|1209:2323'`
  · `dmesg | grep -i gs_usb`.

> Os CAN nativos do Tegra (`mttcan`) exigem transceiver externo; o CANable é o caminho
> plug-and-play. Os módulos `gs_usb`/`slcan`/`can-dev` já vêm no kernel L4T 35.2.1.
> Referência completa: [`doc/CAN/README.md`](doc/CAN/README.md).

---

## Estrutura do repositório

```
CANPass/
├── README.md                  # documentação
├── install.sh                 # instalador do stream (deps, scripts, alias, systemd)
├── install_drivers.sh         # instalador de drivers e-con (rodar NO Orin, aarch64)
├── doc/                       # tudo organizado por câmera (PDFs, drivers, CAD)
│   ├── CAN/README.md          # referência do canpass-can (CANable/J1939)
│   ├── e-CAM82/               # e-CAM82_CUOAGX (MIPI/IMX485) — câmera PRINCIPAL
│   │   ├── README.md          #   controles: Table 1, Flicker, auto-exposure
│   │   ├── *.pdf              #   datasheets e guias
│   │   └── e-CAM82_CUOAGX/    #   drivers:
│   │       ├── e-CAM82_CUOAGX_JETSON_..._L4T35.2.1_..._R02_RC1/   # driver da e-CAM82 (IMX485, JP5) — LFS
│   │       └── e-CAM_YUV-OCTA-GMSL-PRODUCTS_..._L4T36.4.3_R02/    # GMSL OCTA (OUTRO produto) — LFS
│   └── NileCAM81/             # NileCAM81_CUOAGX (GMSL/AR0821) — câmera ALTERNATIVA
│       ├── COMPATIBILIDADE.md · TESTE_RAPIDO.md
│       ├── Common/ Hardware/ Software/ Software_R05_JP6/      # PDFs + CAD (STP/DXF, LFS)
│       └── NileCAM81_CUOAGX/  # drivers:
│           ├── JP5.1.0_L4T35.2.1/   # ★ build p/ o flash ATUAL (alternância s/ reflash) — LFS
│           ├── JP6.0_L4T36.3.0/     # build p/ JP6 (exige reflash) — LFS
│           └── JP5.1.2_L4T35.4.1/   # build antigo (fora do git)
└── .rsc/
    ├── cam_view.sh            # script principal: detecção, stream RTSP/HLS/WebRTC, gravação
    ├── watchdog.sh            # supervisor de processo (alias `canpass`)
    ├── canpass-camera.sh      # alterna e-CAM82 ↔ NileCAM81 + preview local (nv3dsink)
    ├── canpass-can.sh         # sniffer CAN do adaptador USB CANable (gs_usb) — J1939
    ├── canpass-backup.sh      # snapshot/restore da eMMC do Orin (roda no PC host)
    └── docker-install.sh      # instalador do Docker
```

---

## Changelog

### v1.4.13 — 2026-06-08

- `install_drivers.sh`: a **e-CAM82 (IMX485, MIPI, L4T 35.2.1 / JP 5.1.0)** passa a ser a **opção 1 (recomendada)** — é o driver correto desta câmera. Pacotes GMSL (OCTA AR0821 / NileCAM81) reclassificados como opções 2/3 de **OUTROS produtos**, com aviso e confirmação extra. Banner e checagem de kernel ajustados; alerta de que o instalador da e-con aborta se o L4T não casar exatamente.
- **Pacote de driver IMX485 versionado via Git LFS** — antes estava fora do versionamento, fazendo a opção 1 falhar num clone limpo.
- `cam_view.sh`: cleanup robusto contra `unbound variable` (`loop_pid`); aborta o probe e não exibe URLs se o loop de stream morrer; aguarda o stream ficar disponível antes de exibir as URLs.

### v1.4.0 — 2026-05-19

- `install_drivers.sh`: adicionado instalador de drivers de câmera e-con para Jetson AGX Orin (e-CAM82, e-CAM YUV OCTA, NileCAM81), executado no próprio Orin via `git pull`. Correções de caminhos de pacote, checagem de versão L4T, criação de `Images_Backup` e caminho dinâmico do módulo do kernel.

### v0.4.x — 2026-05-15

- `cam_view.sh`: suporte a **câmera IP (RTSP)** com auto-detecção de subnet divergente e configuração de IP temporário; caminho RTSP da Intelbras como padrão; URLs exibidas para todas as interfaces de rede; probe da câmera IP antes de expor URLs; loop de reconexão interrompido em erros fatais de RTSP; GOP reduzido (6→2 frames) para cortar latência.

### v0.3.5 — 2026-05-12

- `install.sh`: adicionada regra sudoers NOPASSWD em `/etc/sudoers.d/canpass-nvargus` para Jetson, permitindo que `cam_view.sh` reinicie o `nvargus-daemon` sem senha; serviço systemd passa a executar `ExecStartPre=-/bin/systemctl restart nvargus-daemon`.
- `cam_view.sh`: reinicia `nvargus-daemon` via `sudo -n` antes de cada sessão CSI — sessões encerradas abruptamente (Ctrl+C, testes) deixam o daemon em estado inválido causando "No cameras available"; log truncado a cada tentativa; loop interrompido com mensagem de erro acionável em caso de falha fatal (em vez de reconectar indefinidamente).

### v0.3.4 — 2026-05-12

- `cam_view.sh`: removidas todas as probes com `nvarguscamerasrc` (detecção de câmeras e probe de resolução) — cada probe abria uma sessão no daemon nvargus, esgotando os recursos e causando "No cameras available" ao tentar iniciar o stream. Câmeras CSI agora são listadas via variável `CANPASS_CSI_SENSORS` (padrão: `0`) sem abrir sessões. Resolução configurável via `CANPASS_CSI_RES` (padrão: `1920x1080@30`).

### v0.3.3 — 2026-05-12

- `install.sh`: substituído `chmod 666` por `chown "$CALLING_USER"` em `/tmp/.canpass_src_dir` — o sticky bit de `/tmp` impede que um usuário comum delete arquivos pertencentes ao root mesmo com permissão 666.
- `cam_view.sh`: erros do GStreamer e ffmpeg no loop CSI agora são gravados em `/tmp/canpass_csi_<id>.log` em vez de descartados, facilitando diagnóstico; adicionado `sleep 1` antes da primeira tentativa de stream para deixar o daemon nvargus estabilizar após os probes; mensagem de reconexão agora exibe os códigos de saída individuais de gst-launch e ffmpeg.

### v0.2.6 — 2026-05-12

- `docker-install.sh`: corrigido `apt remove --purge` que falhava quando nenhum pacote conflitante estava instalado; shebang atualizado para `#!/usr/bin/env bash`.
- README: versão e changelog atualizados.

### v0.2.5 — 2026-05-12

- README: corrigida URL de download e nome da pasta extraída (`CANPass-main`).

### v0.2.4 — 2026-05-12

- `install.sh`: separada limpeza entre `install.sh` (remove tudo exceto si mesmo, salva caminho em `/tmp/.canpass_src_dir`) e `watchdog.sh` (remove o diretório na primeira execução).

### v0.2.3 — 2026-05-12

- `install.sh`: passa a remover a pasta inteira do repositório clonado com `rm -rf`.

### v0.2.2 — 2026-05-12

- README: instalação migrada para comando único via `wget` + `unzip`; removido processo de `git clone`.
- `install.sh`: remove `main.zip` de `$HOME` ao final da instalação.

### v0.2.1 — 2026-05-12

- `install.sh` e `watchdog.sh`: destino dos scripts alterado de `/usr/local/bin` para `/usr/bin`.

### v0.2 — 2026-05-12

- Instalador `install.sh`: instala dependências, copia scripts, configura alias e serviço systemd; auto-remove após instalação bem-sucedida.
- Supervisor `watchdog.sh`: reinicia `cam_view.sh` em falhas inesperadas, respeita encerramento intencional (Ctrl+C / SIGTERM).
- Scripts movidos para `.rsc/`; raiz contém apenas `README.md` e `install.sh`.
- Gravação por detecção de movimento usando filtro `select` do ffmpeg.
- Detector lê o RTSP e emite scores de cena; máquina de estados bash controla o recorder.
- Gravação inicia ao detectar movimento e para após cooldown configurável.
- Threshold e cooldown ajustáveis via variáveis de ambiente (`MOTION_THRESHOLD`, `MOTION_COOLDOWN_SECS`).
- Nome do arquivo com horário real de início e fim: `dd-mm-aaaa_hh-mm-ss_hh-mm-ss.mp4`.
- Stream RTSP via container `bluenviron/mediamtx` gerenciado automaticamente.
- Endpoint HLS acessível por navegador em `http://<ip>:8888/stream` (LL-HLS, ~300 ms de latência).
- Flag `--display` para abrir janela local via ffplay (desativada por padrão).

### v0.1 — 2026-05-11

- Script `cam_view.sh`: detecção automática de câmeras V4L2, instalação de dependências, exibição via ffplay.
- `.gitignore`: configurado para C/C++ + CMake + vcpkg.
