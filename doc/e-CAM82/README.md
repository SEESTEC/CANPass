# e-CAM82_CUOAGX — Resolução, Flicker e Auto-Exposure (referência)

Referência dos valores usados pelo preview local (`canpass-camera preview`) na câmera **e-CAM82_CUOAGX** (sensor **IMX485**, MIPI, via **Argus/`nvarguscamerasrc`**).
O banner que o programa imprime ao ser chamado espelha este arquivo — mantenha os dois sincronizados.

Fontes:
- **Table 1** → `e-CAM82_CUOAGX_Getting_Started_Manual_Rev_1_4.pdf`.
- **Auto-exposure / imagem** → `gst-inspect-1.0 nvarguscamerasrc` (no Orin deste projeto).
- **WDR/HDR e ganho** → `v4l2-ctl -d /dev/video0 --list-ctrls-menus` (driver e-con).

---

## 1. Table 1 — Maximum Frame Rate Supported (AGX Orin / Xavier)

| Lanes      | Resolução   | FPS (10-bit) | FPS (12-bit) |
|------------|-------------|:------------:|:------------:|
| **4-lane** | 1920 × 1080 | **90**       | 90           |
| **4-lane** | 3840 × 2160 | **60**       | 50           |
| 2-lane     | 1920 × 1080 | 62           | 62           |
| 2-lane     | 3840 × 2160 | 39           | 33           |

> Este projeto usa o pacote IMX485 de **4 lanes** → valem as duas primeiras linhas:
> **1920×1080 @ 90 fps** e **3840×2160 @ 60 fps** (50 em saída 12-bit). É o que o menu do preview oferece.

Pipeline base:
```bash
gst-launch-1.0 nvarguscamerasrc sensor-id=0 ! "video/x-raw(memory:NVMM),width=3840,height=2160,framerate=60/1,format=NV12" ! nv3dsink sync=false
```

---

## 2. Flicker / anti-banding

Compensação de cintilação de iluminação artificial (lâmpadas).

| Valor | Modo          | Quando usar                           |
|:-----:|---------------|---------------------------------------|
| 0     | Off           | luz natural / sem cintilação          |
| 1     | Auto (padrão) | deixa o ISP decidir                   |
| 2     | **50 Hz**     | rede elétrica de 50 Hz (Europa, etc.) |
| 3     | **60 Hz**     | rede elétrica de **60 Hz (Brasil)**   |

- **Argus** (caminho do canpass): propriedade `aeantibanding` → env **`CANPASS_FLICKER`**.
- **V4L2** (alternativo, se exposto): `v4l2-ctl -d /dev/video0 -c power_line_frequency=1` (50 Hz) / `=2` (60 Hz).

```bash
CANPASS_FLICKER=3 canpass-camera preview # 60 Hz
```

---

## 3. Auto-exposure & imagem (`nvarguscamerasrc`)

Cada parâmetro tem uma variável de ambiente que o preview injeta na pipeline.
Faixas/defaults vêm do `gst-inspect-1.0 nvarguscamerasrc` desta câmera.

| Env                   | Propriedade Argus      | Faixa / valores                                                                                                       | Padrão | Função                      |
|-----------------------|------------------------|-----------------------------------------------------------------------------------------------------------------------|:------:|-----------------------------|
| `CANPASS_FLICKER`     | `aeantibanding`        | 0 Off, 1 Auto, 2 50 Hz, 3 60 Hz                                                                                       | 1      | anti-flicker                |
| `CANPASS_EXPOSURECOMP`| `exposurecompensation` | −2.0 … 2.0 (EV)                                                                                                       | 0      | compensação de exposição    |
| `CANPASS_EXPTIME`     | `exposuretimerange`    | `"min max"` em **ns** (ex `"34000 33333333"`)                                                                         | —      | limita tempo de exposição   |
| `CANPASS_GAINRANGE`   | `gainrange`            | `"min max"` (ex `"1 16"`)                                                                                             | —      | limita ganho analógico      |
| `CANPASS_ISPGAIN`     | `ispdigitalgainrange`  | `"min max"` (ex `"1 8"`)                                                                                              | —      | limita ganho digital do ISP |
| `CANPASS_AELOCK`      | `aelock`               | `true` / `false`                                                                                                      | false  | **congela** a exposição     |
| `CANPASS_AWBLOCK`     | `awblock`              | `true` / `false`                                                                                                      | false  | trava o white balance       |
| `CANPASS_WBMODE`      | `wbmode`               | 0 off, 1 auto, 2 incandescent, 3 fluorescent, 4 warm-fluorescent, 5 daylight, 6 cloudy, 7 twilight, 8 shade, 9 manual | 1      | white balance               |
| `CANPASS_SATURATION`  | `saturation`           | 0.0 … 2.0                                                                                                             | 1      | saturação                   |
| `CANPASS_TNR_MODE`    | `tnr-mode`             | 0 Off, 1 Fast, 2 HighQuality                                                                                          | 1      | redução de ruído temporal   |
| `CANPASS_TNR_STRENGTH`| `tnr-strength`         | −1.0 … 1.0                                                                                                            | −1     | força da TNR                |
| `CANPASS_EE_MODE`     | `ee-mode`              | 0 Off, 1 Fast, 2 HighQuality                                                                                          | 1      | realce de bordas            |
| `CANPASS_EE_STRENGTH` | `ee-strength`          | −1.0 … 1.0                                                                                                            | −1     | força do realce             |
| `CANPASS_AEREGION`    | `aeregion`             | `"left top right bottom peso"` (ex `"0 0 256 256 1"`)                                                                 | —      | ROI de auto-exposure        |
| `CANPASS_SENSOR_MODE` | `sensor-mode`          | −1 … 4 (−1 = melhor match)                                                                                            | −1     | modo do sensor              |

### "Explosão de luz" / tempo de adaptação à luminosidade
É o **auto-exposure convergindo** quando a luz muda de repente. Controle assim:
- **Estreitar a faixa de exposição/ganho** → menos "estouro" e adaptação previsível:
  ```bash
  CANPASS_EXPTIME="34000 33333333" CANPASS_GAINRANGE="1 4" CANPASS_ISPGAIN="1 2" canpass-camera preview
  ```
- **Travar** (zero adaptação): `CANPASS_AELOCK=true canpass-camera preview`
- **Compensar** sem travar: `CANPASS_EXPOSURECOMP=-1.0` (escurece o alvo do AE).

---

## 4. WDR / HDR e ganho — controles V4L2 (driver e-con)

`v4l2-ctl -d /dev/video0 --list-ctrls-menus` expõe, nesta câmera:

| Controle         | Faixa / valores             | Observação                           |
|------------------|-----------------------------|--------------------------------------|
| `hdr_enable`     | 0 / 1                       | **WDR/HDR** ligado/desligado         |
| `exposure_short` | 450 … 400000 (µs)           | exposição curta (par do HDR)         |
| `gain`           | 0 … 300 (passo 3)           | ganho                                |
| `exposure`       | 450 … 400000 (µs)           | tempo de exposição                   |
| `frame_rate`     | 2 500 000 … 60 000 000      | valor ÷ 1e6 = fps (2.5–60)           |
| `sensor_mode`    | 0 … 4                       | modo do sensor                       |
| `group_hold`     | bool                        | aplica vários registros atomicamente |

WDR/HDR pelo preview (aplica `hdr_enable` via `v4l2-ctl` antes do Argus):
```bash
CANPASS_HDR=1 canpass-camera preview
```

> Os controles `bypass_mode`, `override_enable`, `*_align`, `write_isp_format`, `sensor_*_properties` etc. são plumbing do VI/Tegra — não mexer.

---

## 5. Exemplos combinados

```bash
# 4K@60, 60 Hz, WDR ligado, ganho limitado (cena com fonte de luz forte):
CANPASS_HDR=1 CANPASS_FLICKER=3 CANPASS_GAINRANGE="1 8" canpass-camera preview ecam82
# (escolha [1] 3840x2160@60 no menu)

# 1080p@90 travado (sem variação de exposição), white balance daylight:
CANPASS_AELOCK=true CANPASS_WBMODE=5 canpass-camera preview ecam82
```

Para descobrir o que ESTE driver expõe a qualquer momento, a fonte da verdade é:
```bash
v4l2-ctl -d /dev/video0 --list-ctrls-menus
gst-inspect-1.0 nvarguscamerasrc
```
