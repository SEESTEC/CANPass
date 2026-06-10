# Teste rápido da NileCAM81 (reflash + driver) — e volta para a e-CAM82

> ✅ **OBSOLETO (2026-06-10): este roteiro não é mais necessário.** O build da
> NileCAM81 para **L4T 35.2.1** chegou da e-con e está no repo
> (`NileCAM81_CUOAGX/JP5.1.0_L4T35.2.1/`) — instale com
> `sudo bash install_drivers.sh` (opção 2) **sem reflash** e alterne com
> `canpass-camera switch`. Mantido apenas como registro do Plano B.

Roteiro de bancada para **avaliar a NileCAM81** sem esperar o build 35.2.1 da e-con,
e depois **voltar** ao setup e-CAM82 funcionando (Plano B, reprodutível pelo repo).

> Resumo da estratégia: o teste exige **reflashar** (o driver NileCAM que temos é de
> outro L4T). Não dá pra rodar as duas no mesmo flash hoje. Fazemos:
> **flash 35.4.1 → driver NileCAM → testa → reflash 35.2.1 → install_drivers.sh**.

---

## 0. Versão EXATA e por quê

- **Flashar: L4T 35.4.1 / JetPack 5.1.2** — é o pacote NileCAM que temos
  (`NileCAM81_CUOAGX/JP5.1.2_L4T35.4.1/`). O driver confere `/etc/nv_tegra_release`
  e traz módulos para o **kernel 5.10.120**; só casa com **35.4.1 exato**.
- ⚠️ **NÃO use o SDK Manager** aqui: ele só oferece os JetPacks recentes (5.1.5/5.1.6 =
  **L4T 35.6.x**, kernel diferente) → o driver 35.4.1 **aborta** (vermagic não bate).
- ➡️ Baixe o BSP **R35.4.1** do arquivo histórico e flashe por `flash.sh`.

## Pré-requisitos

- **PC host Linux x86_64** (Ubuntu 20.04/22.04), cabo **USB-C**.
- **Kit GMSL montado**: desserializadora `e-CAM_CUOAGX_DESER_6H01R1` no **J509** +
  serializador + coax FAKRA + fonte **12 V**. Sem isso, não há imagem.
- Recovery mode: Orin desligado → segure **FORCE RECOVERY** → ligue (Power) → solte
  após ~2 s. Confirme no host: `lsusb | grep 0955` (deve aparecer `0955:7023`).

---

## 1. Flashar L4T 35.4.1 (no host)

Baixe do **Jetson Linux archive → R35.4.1** (`developer.nvidia.com/embedded/jetson-linux-r3541`):
- `Jetson_Linux_R35.4.1_aarch64.tbz2`
- `Tegra_Linux_Sample-Root-Filesystem_R35.4.1_aarch64.tbz2`

```bash
tar xf Jetson_Linux_R35.4.1_aarch64.tbz2
sudo tar xpf Tegra_Linux_Sample-Root-Filesystem_R35.4.1_aarch64.tbz2 -C Linux_for_Tegra/rootfs/
cd Linux_for_Tegra
sudo ./tools/l4t_flash_prerequisites.sh
sudo ./apply_binaries.sh
# Orin em recovery:
sudo ./flash.sh jetson-agx-orin-devkit internal
```

## 2. Instalar o driver NileCAM81 (no Orin já flashado)

```bash
cd CANPass/NileCAM81_CUOAGX/JP5.1.2_L4T35.4.1
tar xf e-CAM_YUV-GMSL-PRODUCTS_JETSON_L4T35.4.1_04-JAN-2024_R02_RC3.tar.xz
cd e-CAM_YUV-GMSL-PRODUCTS_*
sudo bash install_binaries.sh 81     # '81' = variante NileCAM81
sudo reboot
```

## 3. Testar

```bash
ls /dev/video0                       # deve existir após o boot
sudo systemctl restart nvargus-daemon

# Preview (escolha a resolução no menu):
canpass-camera preview nilecam81

# Ou direto:
gst-launch-1.0 nvarguscamerasrc sensor-id=0 ! \
  "video/x-raw(memory:NVMM),width=1920,height=1080,framerate=60/1,format=NV12" ! \
  nv3dsink sync=false
```

### Ajustes de WDR / Flicker / Auto-exposure no teste
Os mesmos controles da e-CAM82 valem para qualquer câmera Argus. Via env do preview:
```bash
CANPASS_FLICKER=3 canpass-camera preview nilecam81           # 60 Hz
CANPASS_HDR=1 canpass-camera preview nilecam81               # WDR/HDR on (se o driver expor)
CANPASS_AELOCK=true canpass-camera preview nilecam81         # trava exposição
CANPASS_EXPTIME="34000 33333333" CANPASS_GAINRANGE="1 8" canpass-camera preview nilecam81
```
A lista real de controles desta câmera/driver:
```bash
v4l2-ctl -d /dev/video0 --list-ctrls-menus
gst-inspect-1.0 nvarguscamerasrc
```
(Tabela completa de parâmetros e faixas: `doc/ecam82/README.md`.)

---

## 4. Voltar para a e-CAM82 (Plano B — à prova de bala)

```bash
# host — baixe o BSP R35.2.1 (mesmo arquivo histórico) e flashe:
#   Jetson_Linux_R35.2.1_aarch64.tbz2 + Sample-Root-Filesystem_R35.2.1
cd Linux_for_Tegra      # (o do 35.2.1)
sudo ./apply_binaries.sh
# Orin em recovery, base board MIPI de volta no J509:
sudo ./flash.sh jetson-agx-orin-devkit internal

# no Orin:
cd CANPass
sudo bash install_drivers.sh    # opção 1 — e-CAM82 IMX485, 4 lanes → /dev/video0
sudo bash install.sh            # reinstala scripts/alias/serviço
```

Pronto — e-CAM82 reconstruída exatamente como antes, sem depender de imagem de backup.

> Se você fez a imagem de rootfs com `canpass-backup.sh` (e estivesse em L4T 35.3.1+),
> o restore por `l4t_backup_restore.sh -r` é uma alternativa. No 35.2.1 a ferramenta
> não existe — por isso o Plano B (reflash + install_drivers.sh) é o caminho oficial.

---

## Armadilhas comuns

- **Recovery mode** não confirmado por `lsusb` → flash falha. Cheque sempre.
- **Hardware GMSL ausente** no J509 → sem imagem, independente do driver.
- Flashar **35.6.x** (SDK Manager) em vez de **35.4.1** → driver NileCAM aborta.
- Esquecer de **trocar a base board** no J509 ao alternar MIPI ↔ GMSL.
