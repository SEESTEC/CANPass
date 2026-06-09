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

| Variável de ambiente   | Padrão | Descrição                                                      |
|------------------------|--------|----------------------------------------------------------------|
| `MOTION_THRESHOLD`     | `0.02` | Fração de pixels alterados que caracteriza movimento (0.0–1.0) |
| `MOTION_COOLDOWN_SECS` | `30`   | Segundos sem movimento antes de encerrar a gravação            |
| `CANPASS_REC_DIR`      | `~/canpass_rec` | Diretório de destino das gravações                    |
| `CANPASS_CSI_RES`      | `1920x1080@30`  | Resolução e FPS da câmera CSI (Jetson). Ex: `1280x720@30` |
| `CANPASS_CSI_SENSORS`  | `0`             | IDs dos sensores CSI a listar, separados por espaço. Ex: `0 1` |
| `CANPASS_NO_CLOCK_BOOST` | _(desativado)_ | Defina como `1` para **não** maximizar os clocks do Jetson antes do stream CSI |
| `CANPASS_CSI_BITRATE`  | `8000000`       | Bitrate do encoder H.264 da câmera CSI, em bps. Ex: `20000000` para 4K nítido |
| `CANPASS_CSI_ENCODER`  | `auto`          | Encoder da câmera CSI: `auto`/`hw` (NVENC por hardware) ou `sw` (libx264) |

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

A câmera deste projeto é a **e-CAM82_CUOAGX**: **MIPI CSI-2**, sensor **Sony IMX485** com ISP externo, acessada via **Argus/V4L2** (`nvarguscamerasrc` / `/dev/video*`). **Ela NÃO é GMSL.**

> A instalação principal (`install.sh`) **já instala este driver automaticamente** em Jetson,
> de forma não-interativa. Rode `install_drivers.sh` à mão apenas para reinstalar ou escolher
> outro pacote.

O `install_drivers.sh` deve ser executado **no próprio Orin** (aarch64), a partir da raiz deste repositório:

```bash
sudo bash install_drivers.sh          # interativo (menu de opções)
sudo bash install_drivers.sh --auto   # não-interativo: e-CAM82 IMX485, 4 lanes
```

| Opção | Pacote | Alvo | Observação |
|-------|--------|------|------------|
| **1** ✓ | **e-CAM82 (IMX485, MIPI)** | L4T 35.2.1 / JP 5.1.0 (kernel 5.10.104-tegra) | **Driver CORRETO desta câmera** |
| 2 ⚠ | [GMSL] e-CAM YUV OCTA (AR0821) | L4T 36.4.3 / JP 6.2.0 | **OUTRO produto** — não é a e-CAM82 |
| 3 ⚠ | [GMSL] NileCAM81 | L4T 36.3.0 / JP 6.0.0 | **OUTRO produto** |

> ⚠️ **Atenção:** instalar um driver **GMSL** (opções 2/3) na e-CAM82 (IMX485) causa os erros `ser_status=f0` / `ret=-121`. Câmera, cabo e alimentação não são o problema nesse caso — é o driver errado.

**Requisito de flash:** o instalador da e-con confere `/etc/nv_tegra_release` e **aborta** se o L4T do flash não casar **exatamente** com o alvo do pacote. Para a e-CAM82, o Orin precisa estar em **L4T 35.2.1 / JP 5.1.0** (kernel `5.10.104-tegra`). O Orin usa **4 lanes**.

Após instalar, validar a captura com o app `eCAM_argus_camera` (libargus) que acompanha o pacote.

No caminho CSI, o `cam_view.sh` **maximiza automaticamente os clocks** do Jetson (`nvpmodel -m 0`, `jetson_clocks` e, se presente, o `max-isp-vi-clks.sh` da e-con) para obter o frame rate máximo — sem senha, via regras NOPASSWD criadas pelo `install.sh`. Para desativar, exporte `CANPASS_NO_CLOCK_BOOST=1`.

> Os pacotes de driver são grandes (centenas de MB) e versionados via **Git LFS** — é necessário `git lfs install` antes do clone para obtê-los.

---

## Estrutura do repositório

```
CANPass/
├── README.md                  # documentação
├── install.sh                 # instalador do stream (deps, scripts, alias, systemd)
├── install_drivers.sh         # instalador de drivers e-con (rodar NO Orin, aarch64)
├── doc/                       # PDFs oficiais da e-CAM82 (datasheets, guias e-con)
├── .rsc/
│   ├── cam_view.sh            # script principal: detecção, stream RTSP/HLS/WebRTC, gravação
│   ├── watchdog.sh            # supervisor de processo (alias `canpass`)
│   └── docker-install.sh      # instalador do Docker
├── e-CAM82_CUOAGX_JETSON_XAVIER_ORIN_L4T35.2.1_..._R02_RC1/  # driver CORRETO (IMX485, JP5) — LFS
├── e-CAM82_CUOAGX_L4T36.4.3/                                  # driver GMSL OCTA (OUTRO produto) — LFS
└── NileCAM81_CUOAGX/                                          # driver GMSL NileCAM81 (OUTRO produto)
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
