# CANPass

> **v0.2.6** — Stream de câmeras V4L2 via RTSP/HLS com gravação por detecção de movimento, watchdog e instalação automatizada.

## Descrição

CANPass é um projeto C/C++ voltado para comunicação via barramento CAN *(Controller Area Network)*, com utilitários de suporte para captura, transmissão e gravação de câmeras em sistemas Linux embarcados.

## Instalação

### Requisitos

- Ubuntu 22.04 LTS (ou derivado)
- Acesso à internet
- Permissão `sudo`

### Instalar

Cole o comando abaixo no terminal e execute:

```bash
sudo apt install -y unzip wget && wget -P "$HOME" https://github.com/SEESTEC/CANPass/archive/refs/heads/main.zip && unzip "$HOME/main.zip" -d "$HOME" && sudo chmod +x "$HOME/CANPass-main/install.sh" && sudo "$HOME/CANPass-main/install.sh"
```

O instalador cuida automaticamente de:

- Instalar `ffmpeg`, `v4l-utils` e `docker` (via `docker-install.sh` embutido)
- Adicionar o usuário ao grupo `docker`
- Copiar `cam_view.sh` e `watchdog.sh` para `/usr/bin/`
- Registrar o alias `canpass` em `~/.bashrc`
- Criar e registrar o serviço systemd `canpass`
- Remover o arquivo `.zip` e a pasta de instalação ao final

**Após a instalação:**

```bash
source ~/.bashrc
canpass
```

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

Exemplo: `11-05-2026_14_32_00_14_35_47.mp4`

| Variável de ambiente   | Padrão | Descrição                                                      |
|------------------------|--------|----------------------------------------------------------------|
| `MOTION_THRESHOLD`     | `0.02` | Fração de pixels alterados que caracteriza movimento (0.0–1.0) |
| `MOTION_COOLDOWN_SECS` | `30`   | Segundos sem movimento antes de encerrar a gravação            |
| `CANPASS_REC_DIR`      | `~/canpass_rec` | Diretório de destino das gravações                    |

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

## Build (C/C++)

O projeto usa **CMake** com **vcpkg** para dependências.

```bash
cmake -B build -S .
cmake --build build
```

---

## Estrutura do repositório

```
CANPass/
├── README.md          # documentação
├── install.sh         # instalador (auto-remove após execução)
└── .rsc/
    ├── cam_view.sh    # script principal
    ├── watchdog.sh    # supervisor de processo
    └── docker-install.sh  # instalador do Docker
```

---

## Changelog

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
