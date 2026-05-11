# CANPass

> **v0.2.0** — Stream de câmeras V4L2 via RTSP/WebRTC com exibição local opcional.

## Descrição

CANPass é um projeto C/C++ voltado para comunicação via barramento CAN *(Controller Area Network)*, com utilitários de suporte para captura e visualização de câmeras em sistemas Linux embarcados.

## Requisitos

- Ubuntu 22.04 LTS
- `ffmpeg` / `ffplay` (instalado automaticamente pelo script)
- `v4l-utils` (instalado automaticamente pelo script)
- `docker` (instalado automaticamente via `docker-install.sh`)
- Permissão de acesso a `/dev/video*` (usuário no grupo `video` ou execução com `sudo`)

## Utilitários

### `cam_view.sh` — Visualizador de câmera

Detecta câmeras V4L2, sobe um servidor RTSP/WebRTC via Docker e transmite o stream da câmera selecionada. Na primeira execução, registra o alias `canpass` no `~/.bashrc`.

**Uso básico** (só stream, sem janela local):

```bash
chmod +x cam_view.sh
./cam_view.sh
# ou, após a primeira execução:
canpass
```

**Com exibição local** (abre janela ffplay além do stream):

```bash
canpass --display
```

**Fluxo:**

1. Verifica e instala `ffmpeg`, `v4l-utils` e `docker` se necessário.
2. Sobe o container `mediamtx` (RTSP/WebRTC) se não estiver em execução.
3. Registra o alias `canpass` em `~/.bashrc` na primeira execução.
4. Varre `/dev/video*` filtrando apenas dispositivos de captura real.
5. Se houver mais de uma câmera, solicita seleção interativa.
6. Inicia `ffmpeg` em background capturando o dispositivo e enviando H.264 ao MediaMTX.
7. Exibe os endereços de acesso ao stream.
8. Com `--display`: abre `ffplay` lendo do RTSP para visualização local.
9. Pressione **Ctrl+C** (modo headless) ou **Q** (modo `--display`) para encerrar.

**Endpoints disponíveis após iniciar:**

| Protocolo | Endereço | Acesso |
|-----------|----------|--------|
| RTSP | `rtsp://<ip>:8554/stream` | VLC, ffplay, câmeras IP |
| HLS | `http://<ip>:8888/stream` | Navegador (outra máquina na rede) |

**Gravação por detecção de movimento:**

A gravação ocorre apenas quando movimento é detectado. Os arquivos são salvos em `canpass_rec/`, criado automaticamente ao lado do script.

```
dd_mm_aaaa-hh_mm_ss-hh_mm_ss.mp4
 └─ data   └─ início  └─ fim real
```

Exemplo: `11_05_2026-14_32_00-14_35_47.mp4`

| Variável de ambiente | Padrão | Descrição |
|---|---|---|
| `MOTION_THRESHOLD` | `0.02` | Fração de pixels alterados que caracteriza movimento (0.0–1.0) |
| `MOTION_COOLDOWN_SECS` | `10` | Segundos sem movimento antes de encerrar a gravação |

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

## Build (C/C++)

O projeto usa **CMake** com **vcpkg** para dependências.

```bash
cmake -B build -S .
cmake --build build
```

## Changelog

### 0.3.0 — 2026-05-11

- Gravação por detecção de movimento usando filtro `select` do ffmpeg.
- Detector lê o RTSP e emite scores de cena; máquina de estados bash controla o recorder.
- Gravação inicia ao detectar movimento e para após cooldown configurável.
- Threshold e cooldown ajustáveis via variáveis de ambiente (`MOTION_THRESHOLD`, `MOTION_COOLDOWN_SECS`).
- Nome do arquivo com horário real de início e fim: `dd_mm_aaaa-hh_mm_ss-hh_mm_ss.mp4`.

### 0.2.0 — 2026-05-11

- Stream RTSP via container `bluenviron/mediamtx` gerenciado automaticamente.
- Endpoint WebRTC acessível por navegador em `http://<ip>:8889/stream`.
- Flag `--display` para abrir janela local via ffplay (desativada por padrão).
- Alias `canpass` registrado automaticamente em `~/.bashrc` na primeira execução.
- Instalação automática do Docker via `docker-install.sh` se necessário.

### 0.1.0 — 2026-05-11

- Script `cam_view.sh`: detecção automática de câmeras V4L2, instalação de dependências, exibição via ffplay.
- `.gitignore`: configurado para C/C++ + CMake + vcpkg.
