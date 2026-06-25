# Relatório Técnico — Sistema CANPass

**Plataforma de captura de vídeo e telemetria CAN para máquina pesada Caterpillar**

| | |
|---|---|
| **Projeto** | CANPass |
| **Plataforma alvo** | NVIDIA Jetson AGX Orin (L4T 35.2.1 / JetPack 5.1.0 / kernel 5.10.104-tegra) |
| **Objetivo** | Gravar vídeo (CSI/GMSL/IP) sincronizado com o log do barramento J1939, em campo, de forma autônoma e à prova de parada |
| **Versão de referência** | `v2.11.0-field` (conferir a última com `git tag --sort=-v:refname \| head -1`) |
| **Documento** | Descritivo de hardware, comunicação, topologia e diagrama de blocos |
| **Data** | 2026-06-24 |

---

## 1. Sumário executivo

O CANPass é um sistema embarcado, todo em **shell script** sobre **Linux for Tegra (L4T)**, que transforma uma **NVIDIA Jetson AGX Orin** em um gravador de campo autônomo. Ele:

1. **Detecta e captura** imagem de múltiplas câmeras simultâneas (uma câmera embarcada CSI/GMSL + câmeras IP de rede);
2. **Publica** os vídeos ao vivo em RTSP / HLS / WebRTC através de um servidor **MediaMTX** (Docker);
3. **Grava** os vídeos em MP4 (contínuo recomprimido ou por movimento) em armazenamento **externo com fallback interno**;
4. **Registra continuamente** o barramento **CAN J1939** da máquina Caterpillar via adaptador **CANable USB**;
5. **Sincroniza o relógio** (NTP de rede / RTC / hora do próprio J1939 via PGN 65254) para que vídeo e log CAN compartilhem um **timestamp comum** — permitindo casar imagem ↔ evento CAN;
6. **Resiste a falhas de campo** (câmera que some, disco USB que trava, disco cheio, porta USB ruim) com supervisão, watchdogs de fluxo e auto-recuperação.

Não há etapa de build: a "instalação" copia scripts para `/usr/bin`, configura `sudo` NOPASSWD pontual, um serviço **systemd** e o alias `canpass`. A validação é feita por execução no alvo.

---

## 2. Inventário de hardware

### 2.1 Unidade de processamento — NVIDIA Jetson AGX Orin

| Item | Especificação / observação |
|---|---|
| Módulo | NVIDIA Jetson AGX Orin |
| SO | L4T 35.2.1 · JetPack 5.1.0 · kernel **5.10.104-tegra** (aarch64) |
| Boot | extlinux; a linha **FDT** aponta para o DTB da câmera ativa (`*eimx485*.dtb` ou `*nilecam81*.dtb`) |
| Acesso | **Headless** — SSH e NoMachine, via DHCP na faixa `192.168.20.x` |
| Armazenamento de SO | eMMC interna (raiz) — pequena, viaja com a máquina |
| Armazenamento de mídia | **SSD/HD USB externo** (preferencial) com **fallback** para a eMMC interna |
| Aceleração | NVENC/NVDEC (H.264/HEVC por hardware), ISP Argus, GPU para `nvvidconv`/`nv3dsink` |
| RTC | `rtc0` (PMIC) e `rtc1` (Tegra) — **sem bateria coin-cell** no carrier atual → relógio não sobrevive a power-off (ver §7) |

### 2.2 Câmeras

São **quatro fontes de imagem** em duas classes: **uma câmera embarcada** (conector J509, CSI/GMSL — alternável, nunca as duas juntas) e **duas câmeras IP** de rede.

#### Câmera embarcada — alternável por boot (`canpass-camera switch`)

| Câmera | e-CAM82_CUOAGX *(principal)* | NileCAM81_CUOAGX *(alternativa)* |
|---|---|---|
| Interface | **MIPI CSI-2** | **GMSL2** |
| Sensor | Sony **IMX485** | onsemi **AR0821** |
| Pipeline | ISP externo → Argus / V4L2 (`nvarguscamerasrc`, `/dev/video*`) | Serializa/desserializa → ISP onboard → **YUV via V4L2** direto |
| Módulo de kernel | `eimx485` | `ar0821` + `max96712` |
| Hardware extra | nenhum (conecta direto no J509) | kit GMSL: desserializadora `e-CAM_CUOAGX_DESER_6H01R1` (J509) + serializador + coax FAKRA + 12 V |
| Driver (install_drivers.sh) | opção **1** | opção **2** |
| Status | **Validada** — enumera `/dev/video0` (`eimx485_v2.0.6`) | **Validada** — stream YUV/ISP onboard |

> **Regra de ouro:** mesmo conector J509 + um device tree por boot ⇒ **nunca as duas ao mesmo tempo**. Alterna-se com `canpass-camera switch`, uma por boot. Instalar o pacote GMSL **errado** na e-CAM82 causa `ser_status=f0` / `ret=-121`.
>
> Ambos os drivers são para **L4T 35.2.1** e podem coexistir no **mesmo flash** (build R02 da e-con, 2026-06-10). O instalador da e-con **aborta** se `/etc/nv_tegra_release` não casar exatamente e **reinicia sozinho** ao final.

#### Câmeras IP — de rede (somadas no modo `--all`)

| Câmera | IP / porta | Caminho RTSP | Codec | Credencial |
|---|---|---|---|---|
| **Hikvision** | `10.105.4.57:554` | `/Streaming/Channels/101` | **HEVC (H.265)** | `admin` / `Service@1` |
| **Vivotek** | `10.105.4.51:554` | `/live1s2.sdp` | **H.264** 1920×1080 + áudio `pcm_mulaw` | `root` / `Service@1` |

> Notas de campo: a Vivotek precisa de `-map 0:v` (descartar o áudio `pcm_mulaw` que zerava o MP4 — corrigido desde v2.4.2). A Hikvision em HEVC dá **tela preta no WebRTC** (o navegador não decoda HEVC) → para vê-la ao vivo via WebRTC, ligar `CANPASS_IP_ENCODE=1` (reencode x264); a **gravação funciona normalmente** mesmo sem isso, pois o gravador contínuo reencoda em x264. Senhas vão **URL-encoded** na URL (`Service@1` → `Service%401`).

### 2.3 Interface CAN — adaptador CANable USB

| Item | Especificação |
|---|---|
| Adaptador | **CANable USB** (USB-CAN), VID:PID `1d50:606f` (ou `1209:2323`) |
| Driver | `gs_usb` (SocketCAN) |
| Barramento | **J1939 da máquina Caterpillar** — 250 000 bit/s, IDs estendidos **29-bit** |
| Modo padrão | **listen-only** (não perturba a rede do veículo) |
| Interface de rede | resolvida **pelo driver `gs_usb`**, nunca pelo nome (o Orin tem `mttcan` nativo em `can0`/`can1`, e o nome do CANable muda ao reenumerar) |

> O CAN nativo do Tegra (`mttcan`, `can0`/`can1`) é **ignorado de propósito** — o sistema só usa a interface cujo driver é `gs_usb`. Override manual: `CANPASS_CAN_IF`.

### 2.4 Armazenamento das gravações e logs

| Camada | Destino | Critério |
|---|---|---|
| Preferencial | `CANPASS_REC_DIR` explícito, senão **1º disco USB externo** montado e gravável (`{mount}/canpass_rec`) | removível **ou** hotplug, montado, gravável, fora do disco da raiz |
| Fallback | eMMC interna (`~/canpass_rec`) | quando o externo some/trava/enche |
| Guarda de espaço | margem mínima `CANPASS_MIN_FREE_MB` (**8 GB**) | sem margem em nenhum destino → gravação **pausa** (protege o Orin de encher) |

Montagem do SSD externo no boot headless é feita por um **helper root** dedicado (sem autologin/polkit). Detalhes da lógica de fallback no §6.

### 2.5 Rede

- **Switch/rede Ethernet** liga Orin ↔ câmeras IP (faixa `10.105.4.x` em campo) e Orin ↔ acesso de gestão (`192.168.20.x` via DHCP).
- O **Orin atua como servidor NTP** (fuso de Brasília, `America/Sao_Paulo`) para as câmeras IP e como cliente NTP de um upstream da rede quando houver (`CANPASS_NTP_UPSTREAM`).

---

## 3. Topologia do sistema

```
                          MÁQUINA CATERPILLAR (J1939, 250 kbit/s, 29-bit)
                                         │
                                    [ conector CAN ]
                                         │
                                 ┌───────┴────────┐
                                 │  CANable USB   │  (driver gs_usb, listen-only)
                                 └───────┬────────┘
                                         │ USB
   J509 (1 por boot)                     │
   ┌──────────────┐                      │
   │ e-CAM82 CSI  │── MIPI CSI-2 ──┐     │
   │  (IMX485)    │                │     │
   └──────────────┘                ▼     ▼
   ┌──────────────┐         ┌─────────────────────────────────────────────┐
   │ NileCAM81    │═ GMSL2 ═▶│         NVIDIA JETSON AGX ORIN              │
   │ (AR0821)     │         │  L4T 35.2.1 · headless (SSH/NoMachine)      │
   └──────────────┘         │                                             │
                            │  watchdog.sh ──► cam_view.sh --all          │
   ┌──────────────┐         │       │              │            │         │
   │ Hikvision IP │─ RTSP ─▶│   canpass-can     MediaMTX    gravadores    │
   │ (HEVC) .57   │  H.265  │   (log CAN)       (Docker)    (ffmpeg)      │
   └──────────────┘         │       │           --net host      │         │
   ┌──────────────┐         │       │                │          │         │
   │ Vivotek IP   │─ RTSP ─▶│       ▼                ▼          ▼         │
   │ (H.264) .51  │  +áudio │  log CAN (epoch    RTSP :8554  MP4 segments │
   └──────┬───────┘         │  ou humano)        HLS  :8888  (contínuo/   │
          │                 │                    WebRTC:8889  movimento)  │
          │                 └────────────┬──────────────┬─────────────────┘
          │ Ethernet                     │ publicação   │ gravação
   ┌──────┴───────────────────┐    ┌─────┴──────┐  ┌────┴─────────────────┐
   │   SWITCH / REDE ETHERNET │    │ Clientes   │  │ SSD/HD USB externo   │
   │   IP cams: 10.105.4.x    │    │ (browser,  │  │  → fallback eMMC      │
   │   gestão:  192.168.20.x  │    │  VLC, app) │  │  guarda 8 GB livres   │
   │   Orin = servidor NTP    │    └────────────┘  └──────────────────────┘
   └──────────────────────────┘
```

---

## 4. Diagrama de blocos funcional (software no Orin)

```
┌────────────────────────────────────────────────────────────────────────────┐
│ systemd  ──(boot)──►  watchdog.sh --all   [EnvironmentFile: canpass-field.env]│
│   Restart=on-failure / RestartSec=3                                           │
└───────────────┬──────────────────────────────────────────────────────────────┘
                │  supervisiona e reinicia em falha
                ▼
   ┌────────────────────────────┐        ┌──────────────────────────────────┐
   │  LOG CAN (background)       │        │  cam_view.sh --all                │
   │  canpass-can dump/log       │        │                                   │
   │  • acha iface por gs_usb    │        │  (A) Detecção de câmeras          │
   │  • ip link listen-only 250k │        │      CSI / V4L2 / IP              │
   │  • candump supervisionado   │        │            │                      │
   │  • timestamp epoch comum    │        │            ▼                      │
   └────────────────────────────┘        │  (B) ensure_mediamtx (Docker,     │
                                          │      --network host)              │
   ┌────────────────────────────┐        │            │                      │
   │  RELÓGIO (sincronia)        │        │   ┌────────┴─────────┐            │
   │  canpass-clock (RTC/fake)   │        │   ▼                  ▼            │
   │  chrony (NTP srv+cliente)   │        │ (C) Pipelines      (D) Gravadores │
   │  canpass-can cantime        │        │  publicação 1/cam   1/cam:        │
   │  (PGN 65254 J1939)          │        │  • CSI→NVENC→RTSP   • contínuo    │
   └────────────────────────────┘        │  • YUV/V4L2→NVENC     (x264 CRF,  │
                                          │  • IP RTSP→republica  frag-MP4)   │
                                          │            │        • movimento  │
                                          │            ▼         (-c copy)    │
                                          │   RTSP:8554 / HLS:8888 /          │
                                          │   WebRTC:8889  +  MP4 → storage   │
                                          └──────────────────────────────────┘
```

---

## 5. Modos de comunicação (resumo por enlace)

| Enlace | Meio físico | Protocolo / pilha | Detalhe |
|---|---|---|---|
| Máquina → CANable | Par CAN-H/CAN-L | **J1939** sobre CAN 2.0B (29-bit) @250k | listen-only por padrão |
| CANable → Orin | **USB** | `gs_usb` / SocketCAN (`candump`) | iface resolvida por driver |
| e-CAM82 → Orin | **MIPI CSI-2** (J509) | Argus / V4L2 (`nvarguscamerasrc`) | ISP externo, sensor IMX485 |
| NileCAM81 → Orin | **GMSL2** (coax FAKRA, J509) | V4L2 YUV (`nvv4l2camerasrc`/`/dev/videoN`) | ISP onboard, desserializadora |
| Câmeras IP → Orin | **Ethernet** | **RTSP** (TCP 554) | Hikvision HEVC · Vivotek H.264 |
| Orin → clientes | **Ethernet** | **RTSP / HLS / WebRTC** via MediaMTX | portas 8554 / 8888 / 8889 |
| Orin → storage | **USB** (externo) / barramento eMMC | sistema de arquivos (MP4 / logs) | externo→fallback interno |
| Orin ↔ rede | **Ethernet** | SSH, NoMachine, **NTP** | Orin como servidor NTP de Brasília |

### 5.1 Publicação das imagens (MediaMTX)

- Servidor **MediaMTX** em container Docker, `--network host`, HLS de baixa latência (`MTX_HLSVARIANT=lowLatency`, segmento 200 ms, parte 50 ms).
- Um **path por câmera** no modo `--all` (`/camN`):
  - **RTSP** — `rtsp://<ip>:8554/camN`
  - **WebRTC** — `http://<ip>:8889/camN` (~100 ms)
  - **HLS** — `http://<ip>:8888/camN` (~200 ms)
- Cada pipeline de publicação tem **loop de reconexão** próprio; câmera IP que conecta-mas-não-manda-dado é expirada pelo MediaMTX (404) e o loop reabre.

### 5.2 Gravação

| Modo | Comando interno | Codec/Container | Característica |
|---|---|---|---|
| **Contínuo** (`continuous`) | `_continuous_loop` | x264 (libx264) CRF `21` por padrão, segmentos frag-MP4 | sempre gravando; corte por keyframe; `movflags=+frag_keyframe+empty_moov+default_base_moof` ⇒ **crash-safe** (até o segmento corrente abre no player); arquivos menores |
| **Movimento** (`motion`) | `_motion_loop` | `-c copy` (cópia EXATA do stream) | grava só com cena em movimento (scene-score do ffmpeg); cooldown configurável; qualidade máxima |

Opcionalmente queima **timestamp** no quadro (`CANPASS_REC_TIMESTAMP=1`, posição `tl`/canto) — no modo movimento isso passa a reencodar em x264 (perde o `-c copy`).

---

## 6. Prevenção de parada de gravação (resiliência de campo)

Esta é uma exigência central do projeto — o sistema **não pode parar de gravar silenciosamente**. Camadas de proteção:

1. **Supervisão por systemd** — o serviço roda `watchdog.sh --all` com `Restart=on-failure` / `RestartSec=3`.
2. **Watchdog de processo** — `watchdog.sh` reinicia o `cam_view.sh` se ele cair inesperadamente (e respeita encerramento intencional).
3. **Watchdog de fluxo CAN** — `canpass-can dump/log` roda supervisionado: re-detecta a interface e religa após surto de erro (ex.: bitrate errado, replug do USB).
4. **Loops de reconexão por pipeline** — cada stream/gravador reabre sozinho quando a fonte some e volta.
5. **Fallback de armazenamento a quente** — `_rec_dir_now` é chamado a **cada (re)início de gravação**:
   - externo removido/travado → migra para a eMMC interna automaticamente e avisa;
   - externo volta → retoma nele.
6. **Probe de escrita NÃO-bloqueante** (`_probe_writable`, teto `CANPASS_FS_PROBE_SECS=6 s`) — um disco USB em falha (UAS reset / I/O error) deixa `mkdir`/`touch` presos em **D-state**; a sonda roda em subshell e **abandona** após o timeout, tratando o destino como indisponível ⇒ não pendura o gravador (corrigido na v2.9.0-field; incidente real em que o D-state pendurava o watchdog >400 s).
7. **Guarda de espaço (8 GB)** — `CANPASS_MIN_FREE_MB` (8192); sem margem em nenhum destino, a gravação **pausa** em vez de encher o disco do Orin, e retoma quando libera.
8. **Auto-recuperação de câmera (GMSL)** — se a câmera do projeto estava ativa no boot mas sumiu, `cam_view` re-proba o link e, no build de campo, **reinicia o Orin** (reset garantido do link GMSL). Teto **5 reboots / 30 min** + carência de 60 s para não travar o SSH; usa `sudo -n reboot` (NOPASSWD).
9. **Boot 100% não-interativo** — `CANPASS_NO_INTERVIEW=1` no perfil de campo; o serviço **nunca bloqueia** pedindo senha. O runtime usa sempre `sudo -n` (nunca `sudo -v`), porque no boot via systemd há um `tty1` anexado que enganava a checagem de interatividade e pendurava o serviço (corrigido v2.6.1-field).

---

## 7. Sincronização de tempo (vídeo ↔ CAN)

O valor do produto está em casar **imagem ↔ evento CAN** por um **timestamp epoch comum**. O relógio é tratado em camadas, com hierarquia de confiança:

| Fonte | Mecanismo | Observação |
|---|---|---|
| **NTP de rede** | `chrony` cliente de `CANPASS_NTP_UPSTREAM` + `makestep` | melhor fonte quando há servidor NTP/internet na rede |
| **Orin como servidor NTP** | `chrony` (`allow` por interface) | as **câmeras IP** sincronizam no Orin; fuso de Brasília |
| **Hora real pelo J1939** | `canpass-can cantime` — **PGN 65254 (Time/Date)** | recupera hora real **offline**, sem internet, direto do barramento da máquina |
| **RTC / fake-hwclock** | `canpass-clock` no boot (RTC c/ bateria > fake-hwclock) | só evita "1969"; **não** recupera o tempo desligado |

> **Limitação de hardware conhecida:** o carrier atual **não tem bateria coin-cell** no RTC — `rtc1` (Tegra) reseta para 1970 a cada power-off. Software (fake-hwclock / clock-restore) só evita data inválida; **não recupera** o tempo que a máquina passou desligada. As soluções reais são: **coin-cell no carrier**, **GPS**, ou a **hora do PGN 65254** do próprio CAN (preferida em campo, pois não exige rede). Em bancada sem internet, o cliente NTP não ajuda — só onde houver fonte NTP na rede.

Ordem de boot dos serviços de relógio (systemd): `fake-hwclock` → `canpass-clock` → `canpass-cantime-boot` → `chrony` → serviço CANPass — garantindo que o gravador suba já com o melhor relógio disponível.

---

## 8. Software e instalação

| Script | Papel |
|---|---|
| `install.sh` | instala deps (+`can-utils`), copia scripts p/ `/usr/bin`, cria alias `canpass`, serviço systemd, sudoers NOPASSWD pontual (nvargus, clocks, `ip`, `reboot`, mount), chrony e serviços de relógio. `--update` reinstala tudo |
| `install_drivers.sh` | instala drivers e-con na Jetson (rodar **no Orin**, aarch64): opção 1 = e-CAM82 (IMX485), opção 2 = NileCAM81 (GMSL) |
| `.rsc/watchdog.sh` | entrada do `canpass`: referência + entrevista (timeout 30 s/pergunta → padrões) + log CAN em background + supervisão + `canpass update` |
| `.rsc/cam_view.sh` | núcleo: detecção, publicação RTSP/HLS/WebRTC, gravação, fallback de storage, auto-recovery de câmera |
| `.rsc/canpass-camera.sh` | alterna e-CAM82 ↔ NileCAM81 (DTB/extlinux) + preview local (`nv3dsink`) |
| `.rsc/canpass-can.sh` | sniffer/log CAN (CANable gs_usb, J1939) + `selftest` (loopback) + `cantime` (PGN 65254) |
| `.rsc/canpass-backup.sh` | snapshot/restore da eMMC do Orin (roda no PC host) |
| `.rsc/docker-install.sh` | instalador do Docker |
| `.rsc/canpass-field.env` | **perfil de campo** lido pelo systemd (câmeras, modo de gravação, CAN, boot não-interativo) |

### Perfil de campo (`canpass-field.env`) — resumo

```
CANPASS_IP_URLS    = Hikvision (.57, HEVC) + Vivotek (.51, H.264)   # somadas à câmera embarcada
CANPASS_IP_ENCODE  = 0        # republica IP sem reencode; gravação reencoda mesmo assim
CANPASS_REC_MODE   = continuous
CANPASS_REC_EXTERNAL = 1      # disco USB externo (com fallback interno)
CANPASS_REC_TIMESTAMP = 1 · CANPASS_TS_POSITION = tl   # relógio queimado no quadro
CANPASS_CAN_BITRATE = 250000 · CANPASS_CAN_LOG_HUMAN = 1
CANPASS_NO_INTERVIEW = 1      # boot headless sem operador
```

---

## 9. Diagnóstico de campo (referência rápida)

| Sintoma | Causa provável | Ação |
|---|---|---|
| CAN "parou de ler", `status` tudo zerado (RX + bus-errors) | barramento mudo no conector (chave desligada / fiação / **porta USB do Orin**) | `canpass-can selftest` separa adaptador de fiação (caso real 2026-06-10: era a porta USB) |
| e-CAM82 com `ser_status=f0` / `ret=-121` | pacote de driver **GMSL errado** instalado | reinstalar opção 1 (IMX485) |
| NileCAM81 stream cai, `ar0821 ret=-121` | **MCU travado** de sessão anterior | **reboot** limpa (não é o script nem o cabo) |
| Hikvision tela preta no WebRTC | navegador não decoda **HEVC** | ligar `CANPASS_IP_ENCODE=1` |
| Vivotek MP4 zerado | áudio `pcm_mulaw` | já corrigido (`-map 0:v`, ≥ v2.4.2) |
| Gravação pendurada, nada grava | disco USB em falha (UAS/D-state) | probe não-bloqueante migra p/ interno (≥ v2.9.0-field); checar cabo/gaveta, sair do FAT32 |
| Data em 1969/1970 após desligar | RTC **sem bateria** | coin-cell / GPS / `cantime` (PGN 65254) |
| "logo → tela preta" no acesso | NoMachine tomando a sessão (normal) | não é brick; checar cabo de rede |

---

## 10. Conclusão

O CANPass entrega um gravador de campo **autônomo, headless e resiliente** que une, num timestamp comum, o vídeo de uma câmera embarcada (CSI **e-CAM82/IMX485** ou GMSL **NileCAM81/AR0821**) e de duas câmeras IP (**Hikvision** HEVC, **Vivotek** H.264) com o **log do barramento J1939** da máquina Caterpillar (via **CANable** USB, listen-only). A publicação ao vivo sai por **MediaMTX** em RTSP/HLS/WebRTC; a gravação vai para **disco USB externo com fallback interno e guarda de espaço**; e um conjunto de **watchdogs, loops de reconexão, probes não-bloqueantes e auto-recuperação de câmera** garante que a gravação não pare silenciosamente. A sincronia de tempo — ponto frágil por ausência de bateria de RTC — é coberta por NTP de rede, RTC/fake-hwclock e, de forma independente de internet, pela **hora real do próprio J1939 (PGN 65254)**.

---

*Documento gerado a partir do código-fonte do repositório (scripts em `.rsc/`, `install*.sh`) e do histórico de incidentes de campo registrados no projeto. Para detalhes operacionais por subsistema, ver `doc/CAN/README.md`, `doc/e-CAM82/README.md`, `doc/NileCAM81/README.md` e o `README.md` da raiz.*
