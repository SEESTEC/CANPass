# NileCAM81_CUOAGX — Controles de imagem (referência)

> Levantado **no hardware** em 2026-06-10 (driver R02 / L4T 35.2.1, two-lane), via
> `v4l2-ctl -d /dev/video0 --list-ctrls-menus`. O banner do
> `canpass-camera preview nilecam81` espelha este arquivo — mantenha os dois sincronizados.

## Arquitetura: por que os controles são diferentes da e-CAM82

A NileCAM81 (AR0821, GMSL2) tem **ISP onboard** no módulo e entrega **YUV pronto**
(`UYVY`/`NV16`) — ela **não passa pelo ISP da NVIDIA (Argus)**. Consequências:

- Captura por **V4L2 direto** (`nvv4l2camerasrc`/`v4l2src`), nunca `nvarguscamerasrc`
  ("No cameras available" nela é esperado). O `canpass` detecta isso sozinho e roteia
  a câmera como `yuv:N`.
- **Todos os ajustes são controles V4L2** (`v4l2-ctl -c controle=valor`) — as
  propriedades Argus da e-CAM82 (`aeantibanding`, `exposuretimerange`, `wbmode`,
  TNR/EE etc.) **não se aplicam**.
- GUI da e-con para explorar os efeitos: `/usr/local/ecam_tk1/bin/ecam_tk1_guvcview`.

## Formatos confirmados (`--list-formats-ext`)

| Formato | Resoluções | FPS |
|---|---|---|
| `UYVY` (4:2:2) e `NV16` (4:2:2) | 1280x720 · 1920x1080 | **60** |
| | 3840x2160 | **16** |

## Controles V4L2 (lista real do driver)

### User Controls

| Controle | Faixa | Padrão | Observação |
|---|---|---|---|
| `brightness` | -15..15 | 0 | |
| `contrast` | 0..10 | 5 | |
| `saturation` | 0..60 | 16 | |
| `white_balance_automatic` | 0/1 | 1 | |
| `white_balance_temperature` | 1000..10000 (passo 50) | 4500 | usado com WB auto = 0 |
| `gamma` | 40..500 | 220 | |
| `gain` | 1..100 | 1 | |
| `horizontal_flip` / `vertical_flip` | 0/1 | 0 | |
| `sharpness` | 0..7 | 2 | |

### Camera Controls

| Controle | Valores | Padrão | Observação |
|---|---|---|---|
| `exposure_auto` | 0=Full FOV Auto · 1=Manual · 2=ROI Based Auto | 0 | |
| `exposure_time_absolute` | 1..10000 | 312 | só em Manual |
| `roi_window_size` | 8..64 (passo 8) | 8 | p/ modo ROI |
| `roi_exposure` | 0..65535 | 32896 | posição da ROI (x<<8\|y) |
| `cam_mode` | 0=**Day HDR** · 1=**Night HDR** · 2=Linear | 0 | o "WDR/HDR" desta câmera |
| `trigger` | 0=Internal · 1=External | 0 | ver External_Trigger_Setup_Guide |
| `frame_sync` | 0=Off · 15/30/60 Hz | 0 | sincronismo entre câmeras |
| `denoise` | 0..15 | 8 | |
| `exposure_compensation` | 8000..1000000 | 33333 | |
| `powerline_frequency` | 0=Auto · 1=50Hz · 2=60Hz | 0 | o "Flicker" desta câmera |
| `frame_rate_control` | 3..60 | 30 | |
| `special_effect` | Normal/B&W/Gray/Negative/Sketch | 0 | |

(Os controles `bypass_mode`/`override_enable`/`sensor_*` são da infraestrutura
tegra-video — não mexer.)

## Mapeamento de envs do `canpass-camera preview nilecam81`

| Env | Controle V4L2 | Equivalente na e-CAM82 (Argus) |
|---|---|---|
| `CANPASS_FLICKER` | `powerline_frequency` (0/1/2) | `aeantibanding` (0..3 — escala diferente!) |
| `CANPASS_HDR` | `cam_mode` (0=Day HDR, 1=Night HDR, 2=Linear) | `hdr_enable` (0/1) |
| `CANPASS_EXPTIME` | `exposure_auto=1` + `exposure_time_absolute` | `exposuretimerange` |
| `CANPASS_EXPOSURECOMP` | `exposure_compensation` (8000..1000000) | `exposurecompensation` (-2..2) |
| `CANPASS_GAIN` | `gain` (1..100) | `gainrange` |
| `CANPASS_WBTEMP` | `white_balance_automatic=0` + `white_balance_temperature` | `wbmode` |
| `CANPASS_SATURATION` | `saturation` (0..60) | `saturation` (0.0..2.0 — escala diferente!) |
| `CANPASS_DENOISE` | `denoise` (0..15) | `tnr-mode`/`tnr-strength` |
| `CANPASS_FPS` | `frame_rate_control` (3..60) | (framerate dos caps) |

Exemplos:

```bash
CANPASS_FLICKER=2 CANPASS_HDR=0 canpass-camera preview nilecam81   # 60 Hz + Day HDR
CANPASS_EXPTIME=500 CANPASS_GAIN=10 canpass-camera preview nilecam81  # exposição manual
CANPASS_WBTEMP=5500 CANPASS_DENOISE=12 canpass-camera preview nilecam81
v4l2-ctl -d /dev/video0 -c cam_mode=1          # Night HDR direto, sem preview
```

> ⚠️ Diferente do Argus (que recebe propriedades por sessão), os controles V4L2 são
> **persistentes no driver** enquanto a câmera estiver probada — um valor setado fica
> valendo para o `canpass`/stream também, até ser alterado ou a câmera repovoar.
