# CANPass

> **v0.1.0** — Detecção e visualização de câmeras V4L2 no Ubuntu 22.04 LTS via ffplay.

## Descrição

CANPass é um projeto C/C++ voltado para comunicação via barramento CAN *(Controller Area Network)*, com utilitários de suporte para captura e visualização de câmeras em sistemas Linux embarcados.

## Requisitos

- Ubuntu 22.04 LTS
- `ffmpeg` / `ffplay` (instalado automaticamente pelo script)
- `v4l-utils` (instalado automaticamente pelo script)
- Permissão de acesso a `/dev/video*` (usuário no grupo `video` ou execução com `sudo`)

## Utilitários

### `cam_view.sh` — Visualizador de câmera

Verifica dependências, detecta câmeras V4L2 disponíveis e abre o stream em tempo real com ffplay.

```bash
chmod +x cam_view.sh
./cam_view.sh
```

**Fluxo:**

1. Instala `ffmpeg` e `v4l-utils` caso não estejam presentes.
2. Varre `/dev/video*` filtrando apenas dispositivos de captura.
3. Se houver mais de uma câmera, solicita seleção interativa.
4. Abre o stream em 1280×720 @ 30 fps; faz fallback para parâmetros automáticos se necessário.
5. Pressione **Q** ou feche a janela para encerrar.

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

### 0.1.0 — 2026-05-11

- Script `cam_view.sh`: detecção automática de câmeras V4L2, instalação de dependências, exibição via ffplay.
- `.gitignore`: configurado para C/C++ + CMake + vcpkg.
