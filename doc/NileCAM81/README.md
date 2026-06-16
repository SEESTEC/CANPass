# NileCAM81_CUOAGX — câmera GMSL2 (referência)

A **NileCAM81_CUOAGX** é a câmera **alternativa** do projeto (a principal é a e-CAM82_CUOAGX MIPI). É **GMSL2**, sensor **onsemi AR0821** 8 MP, com **ISP onboard** no módulo: entrega **YUV pronto** (`UYVY`/`NV16`) e é capturada por **V4L2 direto** (`nvv4l2camerasrc`/`v4l2src`), **nunca** por `nvarguscamerasrc` ("No cameras available" nela é esperado). O `canpass` detecta isso sozinho e roteia a câmera como `yuv:N`.

As duas câmeras usam o **mesmo conector J509** e **um device tree por boot** → **não rodam juntas**; alterna-se uma por boot com `canpass-camera switch`. Ambos os drivers convivem no mesmo flash **L4T 35.2.1 / JP 5.1.0** (kernel 5.10.104-tegra).

Fontes: `NileCAM81_CUOAGX_Datasheet_Rev_1_6.pdf`, `..._Getting_Started_Manual_Rev_1_9.pdf`, `..._Developer_Guide_Rev_1_7.pdf`, `..._Release_Notes_Rev_1_8.pdf`, e a leitura **no hardware** (2026-06-10, driver R02 / L4T 35.2.1, two-lane) via `v4l2-ctl -d /dev/video0 --list-ctrls-menus`. O banner que o `canpass-camera preview nilecam81` imprime espelha este arquivo — mantenha os dois sincronizados.

---

## 1. Hardware — o kit GMSL (pré-requisito inegociável)

Diferente da e-CAM82 (MIPI/IPEX), a NileCAM81 é uma **solução de 3 placas** (SerDes sobre coaxial):

| Peça                       | Modelo                                                | Função                    |
|----------------------------|-------------------------------------------------------|---------------------------|
| Módulo da câmera           | `e-CAM82_CUMI0821_MOD` (sensor **AR0821** 8 MP + ISP) | sensor                    |
| Placa serializadora        | `e-CAM22_CUMI_SER` (serializador GMSL Maxim)          | serializa vídeo → coax    |
| Placa **desserializadora** | `e-CAM_CUOAGX_DESER_6H01R1` (6 conectores FAKRA)      | coax → Orin (no **J509**) |

Cadeia física: módulo → serializador → **cabo coaxial FAKRA (3 m / 15 m)** → desserializador montado no **J509** do Orin + alimentação **12 V 2 A** externa para a desserializadora. Chave **SW1** = modo GMSL2 6 Gbps (padrão).

> **Sem o kit GMSL (desserializador + serializador + coax), a NileCAM81 nem conecta — independe de software.** A e-CAM82 monta a base board MIPI no J509; a NileCAM81 monta a desserializadora — **só cabe uma por vez**.

> ⚠️ **Cuidado com o nome:** o módulo da NileCAM81 se chama `e-CAM82_CUMI0821` (AR0821, GMSL) — **não** confundir com a `e-CAM82_CUOAGX` (IMX485, MIPI) deste projeto. Essa sobreposição de nome "e-CAM82" foi a origem da confusão GMSL × MIPI lá no início.

### Sensor — comparação rápida com a e-CAM82

|                               | e-CAM82_CUOAGX (principal)                      | NileCAM81_CUOAGX (alternativa)         |
|-------------------------------|-------------------------------------------------|----------------------------------------|
| Sensor                        | Sony **IMX485** 8 MP                            | onsemi **AR0821** 8 MP                 |
| Interface                     | **MIPI CSI-2** (cabos IPEX)                     | **GMSL2** (coax FAKRA, até 15 m)       |
| Conexão ao Orin               | base board MIPI no J509                         | desserializador no **J509** + 12 V     |
| ISP / captura                 | ISP externo, via **Argus** (`nvarguscamerasrc`) | **ISP onboard**, **V4L2 direto** (YUV) |
| Módulo de kernel              | `eimx485` / `e_con_cam`                         | `ar0821` (+ `max96712`)                |
| Driver (`install_drivers.sh`) | opção **1**                                     | opção **2**                            |

---

## 2. Instalação e alternância (sem reflash)

O build da NileCAM81 para **L4T 35.2.1 / JP 5.1.0** (R02, kernel 5.10.104 — o **mesmo flash** da e-CAM82) está no repositório em `doc/NileCAM81/NileCAM81_CUOAGX/JP5.1.0_L4T35.2.1/` (md5 conferido). Não há mais necessidade de reflashar para 35.4.1/36.3.0.

```bash
sudo bash install_drivers.sh        # opção 2 — NileCAM81 GMSL
canpass-camera switch nilecam81     # troca o DTB ativo (linha FDT do extlinux) e oferece reboot
canpass-camera switch ecam82        # volta para a e-CAM82
```

- Os dois drivers **coexistem** no flash 35.2.1; os módulos são diferentes (`eimx485`/`e_con_cam` × `ar0821`/`max96712`) e só falham o probe quando o hardware não está presente — sem efeito colateral.
- O `install_drivers.sh` copia os **DTBs nomeados** para `/boot`; o `switch` aponta a linha `FDT` do `extlinux.conf` para o DTB da câmera escolhida e garante o autoload das duas em `/etc/modules`. **Enquanto o DTB da NileCAM81 não estiver em `/boot`, `switch nilecam81` aborta de propósito** (não deixa o Orin sem boot válido).
- **Trocar de câmera é físico:** desligar → trocar a base board no **J509** (MIPI ↔ desserializador GMSL + coax + 12 V) → bootar com o DTB correspondente. É **alternar**, um por boot — **não** rodar as duas juntas.

> Rodar as **duas ao mesmo tempo** exigiria uma carrier board customizada (bricks CSI separados para a MIPI e para o desserializador) + device tree combinado — engenharia custom, fora do devkit.

---

## 3. Por que os controles diferem da e-CAM82

Como a NileCAM81 tem **ISP onboard** e entrega YUV pronto, ela **não passa pelo ISP da NVIDIA (Argus)**. Consequências:

- **Todos os ajustes são controles V4L2** (`v4l2-ctl -c controle=valor`) — as propriedades Argus da e-CAM82 (`aeantibanding`, `exposuretimerange`, `wbmode`, TNR/EE etc.) **não se aplicam**.
- GUI da e-con para explorar os efeitos: `/usr/local/ecam_tk1/bin/ecam_tk1_guvcview`.

### Formatos confirmados (`--list-formats-ext`)

| Formato                         | Resoluções           | FPS    |
|---------------------------------|----------------------|--------|
| `UYVY` (4:2:2) e `NV16` (4:2:2) | 1280x720 · 1920x1080 | **60** |
|                                 | 3840x2160            | **16** |

### Controles V4L2 — User Controls

| Controle                            | Faixa                  | Padrão | Observação            |
|-------------------------------------|------------------------|--------|-----------------------|
| `brightness`                        | -15..15                | 0      |                       |
| `contrast`                          | 0..10                  | 5      |                       |
| `saturation`                        | 0..60                  | 16     |                       |
| `white_balance_automatic`           | 0/1                    | 1      |                       |
| `white_balance_temperature`         | 1000..10000 (passo 50) | 4500   | usado com WB auto = 0 |
| `gamma`                             | 40..500                | 220    |                       |
| `gain`                              | 1..100                 | 1      |                       |
| `horizontal_flip` / `vertical_flip` | 0/1                    | 0      |                       |
| `sharpness`                         | 0..7                   | 2      |                       |

### Controles V4L2 — Camera Controls

| Controle                 | Valores                                       | Padrão | Observação                         |
|--------------------------|-----------------------------------------------|--------|------------------------------------|
| `exposure_auto`          | 0=Full FOV Auto · 1=Manual · 2=ROI Based Auto | 0      |                                    |
| `exposure_time_absolute` | 1..10000                                      | 312    | só em Manual                       |
| `roi_window_size`        | 8..64 (passo 8)                               | 8      | p/ modo ROI                        |
| `roi_exposure`           | 0..65535                                      | 32896  | posição da ROI (x<<8\|y)           |
| `cam_mode`               | 0=**Day HDR** · 1=**Night HDR** · 2=Linear    | 0      | o "WDR/HDR" desta câmera           |
| `trigger`                | 0=Internal · 1=External                       | 0      | ver `External_Trigger_Setup_Guide` |
| `frame_sync`             | 0=Off · 15/30/60 Hz                           | 0      | sincronismo entre câmeras          |
| `denoise`                | 0..15                                         | 8      |                                    |
| `exposure_compensation`  | 8000..1000000                                 | 33333  |                                    |
| `powerline_frequency`    | 0=Auto · 1=50Hz · 2=60Hz                      | 0      | o "Flicker" desta câmera           |
| `frame_rate_control`     | 3..60                                         | 30     |                                    |
| `special_effect`         | Normal/B&W/Gray/Negative/Sketch               | 0      |                                    |

> Os controles `bypass_mode`/`override_enable`/`sensor_*` são da infraestrutura tegra-video — não mexer.

---

## 4. Envs do `canpass-camera preview nilecam81` (cobertura completa)

| Env                    | Controle V4L2               | Faixa / valores                                             | Equivalente na e-CAM82 (Argus)              |
|------------------------|-----------------------------|-------------------------------------------------------------|---------------------------------------------|
| `CANPASS_FLICKER`      | `powerline_frequency`       | `0`=Auto · `1`=50Hz · `2`=60Hz                              | `aeantibanding` (0..3 — escala diferente!)  |
| `CANPASS_HDR`          | `cam_mode`                  | `0`=Day HDR · `1`=Night HDR · `2`=Linear                    | `hdr_enable` (0/1)                          |
| `CANPASS_EXPAUTO`      | `exposure_auto`             | `0`=Full FOV auto · `1`=Manual · `2`=ROI auto               | `aelock` (parcial)                          |
| `CANPASS_EXPTIME`      | `exposure_time_absolute`    | `1..10000` (**implica** `exposure_auto=1`)                  | `exposuretimerange`                         |
| `CANPASS_EXPOSURECOMP` | `exposure_compensation`     | `8000..1000000` (padrão 33333)                              | `exposurecompensation` (-2..2)              |
| `CANPASS_ROI_SIZE`     | `roi_window_size`           | `8..64` passo 8 (**implica** `exposure_auto=2`)             | `aeregion`                                  |
| `CANPASS_ROI_POS`      | `roi_exposure`              | `0..65535`                                                  | `aeregion`                                  |
| `CANPASS_GAIN`         | `gain`                      | `1..100` (padrão 1)                                         | `gainrange`                                 |
| `CANPASS_WBAUTO`       | `white_balance_automatic`   | `0`\|`1` (padrão 1)                                         | `awblock`                                   |
| `CANPASS_WBTEMP`       | `white_balance_temperature` | `1000..10000` K, passo 50 (**implica** WB auto=0)           | `wbmode`                                    |
| `CANPASS_BRIGHTNESS`   | `brightness`                | `-15..15` (padrão 0)                                        | —                                           |
| `CANPASS_CONTRAST`     | `contrast`                  | `0..10` (padrão 5)                                          | —                                           |
| `CANPASS_SATURATION`   | `saturation`                | `0..60` (padrão 16)                                         | `saturation` (0.0..2.0 — escala diferente!) |
| `CANPASS_GAMMA`        | `gamma`                     | `40..500` (padrão 220)                                      | —                                           |
| `CANPASS_SHARPNESS`    | `sharpness`                 | `0..7` (padrão 2)                                           | `ee-mode`/`ee-strength`                     |
| `CANPASS_DENOISE`      | `denoise`                   | `0..15` (padrão 8)                                          | `tnr-mode`/`tnr-strength`                   |
| `CANPASS_HFLIP`        | `horizontal_flip`           | `0`\|`1`                                                    | —                                           |
| `CANPASS_VFLIP`        | `vertical_flip`             | `0`\|`1`                                                    | —                                           |
| `CANPASS_FPS`          | `frame_rate_control`        | `3..60` (padrão 30)                                         | (framerate dos caps)                        |
| `CANPASS_FRAMESYNC`    | `frame_sync`                | `0`=Off · `1`=15Hz · `2`=30Hz · `3`=60Hz                    | —                                           |
| `CANPASS_TRIGGER`      | `trigger`                   | `0`=Interno · `1`=Externo                                   | —                                           |
| `CANPASS_EFFECT`       | `special_effect`            | `0`=Normal · `1`=P&B · `2`=Gray · `3`=Negativo · `4`=Sketch | —                                           |

Regras de precedência (resolvidas pelo `canpass-camera`):

- `CANPASS_EXPAUTO` explícito vence; senão `CANPASS_EXPTIME` liga Manual; senão `CANPASS_ROI_*` ligam ROI auto.
- `CANPASS_WBAUTO` explícito vence; senão `CANPASS_WBTEMP` desliga o WB auto.

```bash
CANPASS_FLICKER=2 CANPASS_HDR=0 canpass-camera preview nilecam81        # 60 Hz + Day HDR
CANPASS_EXPTIME=500 CANPASS_GAIN=10 canpass-camera preview nilecam81    # exposição manual
CANPASS_ROI_SIZE=32 canpass-camera preview nilecam81                    # AE por região
CANPASS_WBTEMP=5500 CANPASS_DENOISE=12 canpass-camera preview nilecam81
CANPASS_HFLIP=1 CANPASS_VFLIP=1 canpass-camera preview nilecam81        # montagem invertida
CANPASS_SHARPNESS=4 canpass-camera preview nilecam81                    # mais nitidez aparente
CANPASS_FRAMESYNC=3 canpass-camera preview nilecam81                    # sync 60 Hz entre câmeras
v4l2-ctl -d /dev/video0 -c cam_mode=1                                   # Night HDR direto, sem preview
```

> ⚠️ Diferente do Argus (que recebe propriedades por sessão), os controles V4L2 são **persistentes no driver** enquanto a câmera estiver probada — um valor setado fica valendo para o `canpass`/stream também, até ser alterado ou a câmera repovoar.

---

## 5. Câmera travada — erro -121 (MCU)

A NileCAM81 tem um **MCU on-board** (driver `ar0821`, I²C sobre GMSL). Uma stream-config falha repetida (ex.: um loop de reconexão martelando o `S_FMT`) **trava o MCU**: o ioctl passa a retornar **`EIO` / `-121`** e a câmera só volta com **reboot** ou recarregando o módulo. **Não é o script nem o cabo** — é estado travado do MCU de uma sessão anterior (provado via SSH no Orin, 2026-06-15).

O `cam_view.sh` tenta o caminho **sem reboot** automaticamente: ao ver a assinatura de câmera travada, recarrega o `ar0821` (`modprobe -r ar0821 && modprobe ar0821`), o que reissua o CHIP reset da desserializadora e re-proba o sensor. Rate-limited por lockfile (no `--all`, vários loops não recarregam juntos). Precisa de **NOPASSWD p/ `modprobe ar0821`** (configurado pelo `install.sh`; se faltar, rode `canpass update`).

- Se o reload trouxer `/dev/videoN` de volta → resolvido sem reboot.
- Se não → **REBOOT é o reset garantido do MCU**.
- Desligar a recuperação automática: `CANPASS_NO_CAM_RECOVER=1`.
- Referência da e-con: `Common/E-CON_SYSTEMS_GMSL2_CAMERA_PRODUCTS_Error_Recovery_Guide_Rev_1_2.pdf`.

---

## 6. Inspecionar o estado atual

```bash
canpass-camera ctrls                         # resumo: atual vs padrão (* amarelo = alterado) + formato/fps
canpass-camera status                        # mostra a câmera ativa (linha FDT atual)
v4l2-ctl -d /dev/video0 --list-ctrls-menus   # lista crua completa, com menus
v4l2-ctl -d /dev/video0 --list-formats-ext   # formatos/resoluções/fps reais do driver
```
