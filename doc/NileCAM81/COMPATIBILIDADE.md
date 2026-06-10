# NileCAM81_CUOAGX — análise de compatibilidade com o Orin atual

> ✅ **ATUALIZAÇÃO (2026-06-10): o bloqueio de SOFTWARE foi RESOLVIDO.** O build da
> NileCAM81 para **L4T 35.2.1 / JP 5.1.0** (R02, kernel 5.10.104 — o MESMO flash da
> e-CAM82) chegou da e-con e está no repositório em
> `doc/NileCAM81/NileCAM81_CUOAGX/JP5.1.0_L4T35.2.1/` (md5 conferido).
> Instalação: `sudo bash install_drivers.sh` → **opção 2**; alternância por boot:
> `canpass-camera switch ecam82|nilecam81`. O reflash para 35.4.1/36.3.0 (rota B e o
> roteiro do TESTE_RAPIDO.md) ficou **obsoleto** para este fim.
> ⚠️ O bloqueio de **HARDWARE** continua: a NileCAM81 só conecta com o kit GMSL
> (desserializadora `e-CAM_CUOAGX_DESER_6H01R1` no J509 + serializador + coax FAKRA + 12 V).
> A análise original segue abaixo como registro.

> **Pergunta:** com o JetPack instalado hoje no Orin (L4T **35.2.1** / JP **5.1.0**,
> kernel `5.10.104-tegra`), dá para usar também a **NileCAM81_CUOAGX**?
>
> **Resposta curta: não como está** — por **dois** motivos independentes (hardware e
> software). É possível com mudanças; veja "Como fazer" abaixo.

Análise feita a partir da documentação oficial da e-con (extraída para `doc/NileCAM81/`)
e dos instaladores dos pacotes no repositório.

---

## 1. Bloqueio de HARDWARE (o principal)

A NileCAM81 **não é uma câmera MIPI** como a e-CAM82 que está funcionando. Ela é
**GMSL2** (SerDes sobre cabo coaxial). Pelo *Getting Started Manual Rev 1.9* e pelo
*Datasheet Rev 1.6*, é uma **solução de 3 placas**:

| Peça                       | Modelo                                                | Função               |
|----------------------------|-------------------------------------------------------|----------------------|
| Módulo da câmera           | `e-CAM82_CUMI0821_MOD` (sensor **AR0821** 8 MP + ISP) | sensor               |
| Placa serializadora        | `e-CAM22_CUMI_SER` (serializador GMSL Maxim)          | serializa vídeo→coax |
| Placa **desserializadora** | `e-CAM_CUOAGX_DESER_6H01R1` (6 conectores FAKRA)      | coax→Orin            |

Cadeia física: módulo → serializador → **cabo coaxial FAKRA (3 m/15 m)** →
desserializador → montado no **conector J509** do kit Orin + alimentação **12 V 2 A**
externa para a placa desserializadora. Há ainda a chave **SW1** (modo GMSL2 6 Gbps por padrão).

➡️ O setup atual é a **e-CAM82_CUOAGX MIPI** (sensor IMX485, módulo `e-CAM84_CUMI485`),
ligada pela **base board MIPI** com cabos **IPEX**. A NileCAM81 exige a **placa
desserializadora GMSL no J509 + serializador + cabo coaxial** — hardware que esse setup
**não tem**. As duas câmeras **não são intercambiáveis** no mesmo adaptador.

> ⚠️ **Cuidado com o nome:** o módulo da NileCAM81 se chama `e-CAM82_CUMI0821` (AR0821,
> GMSL) — **não** confundir com a `e-CAM82_CUOAGX` (IMX485, MIPI) deste projeto. Essa
> sobreposição de nome "e-CAM82" foi a origem da confusão GMSL×MIPI lá no início.

**Sem o kit GMSL (desserializador + serializador + coax), a NileCAM81 nem conecta —
independe de software.**

---

## 2. Bloqueio de SOFTWARE / FLASH

Mesmo com o hardware GMSL, os pacotes de driver que temos no repositório **não casam**
com o L4T 35.2.1 do Orin:

| Pacote no repo                      | Alvo                      | Kernel           | Roda em 35.2.1? |
|-------------------------------------|---------------------------|------------------|-----------------|
| `JP5.1.2_L4T35.4.1` (R02, jan/2024) | L4T **35.4.1** / JP 5.1.2 | `5.10.120-tegra` | ❌              |
| `JP6.0_L4T36.3.0` (R03, ago/2024)   | L4T **36.3.0** / JP 6.0.0 | `5.15.x-tegra`   | ❌              |

Motivos técnicos (lidos nos `install_binaries.sh`):

- **Checagem exata de L4T (pacote JP5.1.2, linha 148):**
  `if [ $L4T_VERSION != "$JETSON_L4T_STRING" ]` → exige **`L4T35.4.1`**; o Orin reporta
  `L4T35.2.1` → **aborta**. (O pacote JP6.0 foi afrouxado por nós para checar só o major,
  mas major 36 ≠ 35 → também aborta.)
- **Kernel próprio:** o instalador compara `/boot/Image` com o `Kernel/Image` do pacote
  (linha 181) e traz **kernel + módulos `.ko` compilados para 35.4.1 (5.10.120)**. Os
  módulos não dão `insmod` em `5.10.104` (vermagic diferente). Afrouxar o check de versão
  **não** resolve — a ABI do kernel é o bloqueio real.

**PORÉM (confirmado nas Release Notes Rev 1.8):** a NileCAM81 **tem** um build para
**exatamente o L4T 35.2.1** do Orin atual — release **R01_RC4 (10-FEB-2023), JetPack 5.1,
L4T R35.2.1, kernel 5.10.104** (o MESMO kernel da e-CAM82 que está rodando). Esse pacote
**não está neste repositório** (temos 35.4.1 e 36.3.0), mas existe e pode ser solicitado à
e-con. Com ele, dá para ter os dois drivers no flash atual **sem reflashar** — ver seção 4.

Versões de NileCAM81 publicadas (Release Notes Rev 1.8): L4T 35.1.0 (JP5.0.2),
**35.2.1 (JP5.1)**, 35.3.1 (JP5.1.1), 35.4.1 (JP5.1.2) e 36.3.0 (JP6.0).

---

## 3. Rodar as DUAS câmeras ao mesmo tempo? Não (no devkit padrão)

Não existe versão de JetPack que permita rodar a e-CAM82 **e** a NileCAM81
simultaneamente no Orin devkit — e **não é** limitação de software:

- **Conector físico único:** ambas usam o **mesmo conector de câmera, o J509**, do AGX
  Orin devkit. A e-CAM82 monta a base board MIPI `e-CAM30_HEXCUXVR_BASE_BRD` nele; a
  NileCAM81 monta a desserializadora GMSL `e-CAM_CUOAGX_DESER_6H01R1` nele. Cada base
  board ocupa o J509 inteiro → **só cabe uma por vez** (fonte: Getting Started das duas).
- **Device tree único por boot:** o DTB ativo descreve uma configuração de câmera; os
  pacotes das duas se sobrescrevem.

**Sem reflashar ≠ rodar as duas.** Dá para *instalar* os dois drivers no flash atual
(35.2.1) **se** a e-con fornecer um build da NileCAM81 para 35.2.1 (o do repo é 35.4.1) —
mas usar a outra exige **trocar a base board** + selecionar o DTB + bootar. É **alternar**,
um por boot, não rodar juntas.

**Único caminho para as duas de verdade ao mesmo tempo:** uma **carrier board customizada**
com conectores separados (bricks CSI distintos para a MIPI e para o desserializador GMSL)
+ um **device tree combinado** — engenharia custom / pedido especial à e-con; não é o devkit.

---

## Como fazer (se realmente quiser a NileCAM81)

**Pré-requisito inegociável:** ter o **kit GMSL** — módulo NileCAM81 + placa serializadora
+ placa desserializadora `e-CAM_CUOAGX_DESER_6H01R1` (no J509) + cabo coaxial FAKRA +
fonte 12 V 2 A.

Com o hardware em mãos, duas rotas de software:

- **Rota A — manter a e-CAM82 e o flash 35.2.1:** pedir à e-con um pacote da NileCAM81
  **buildado para L4T 35.2.1 / JP 5.1.0** (kernel 5.10.104). Observação: rodar **as duas
  câmeras ao mesmo tempo** exigiria um device tree combinado (overlays MIPI + GMSL); na
  prática a e-con entrega um produto por vez. Normalmente se usa **uma** família por flash.

- **Rota B — trocar para a NileCAM81:** **reflashar** o Orin para **L4T 35.4.1 (JP 5.1.2)**
  e instalar o pacote `JP5.1.2_L4T35.4.1` do repo (ou L4T 36.3.0 com o pacote JP6.0).
  ⚠️ Isso **quebra a e-CAM82**, que exige exatamente 35.2.1 — as duas não coexistem no
  mesmo flash.

**Recomendação:** se a e-CAM82 (IMX485, MIPI) já atende, **não vale** trocar — você
perderia o setup que acabou de funcionar e precisaria comprar todo o conjunto GMSL. A
NileCAM81 só faz sentido se você precisa especificamente de **GMSL** (cabo coaxial longo,
até 15 m, p/ posicionar a câmera longe do Orin) e tiver o hardware desserializador.

---

## 4. ✅ Alternar e-CAM82 ↔ NileCAM81 SEM reflash (você já tem o hardware)

Como existe um L4T comum às duas = **35.2.1 (o flash atual)**, o caminho é:

**Falta apenas 1 item:** o pacote da **NileCAM81 para L4T 35.2.1**. Você tem os de 35.4.1
e 36.3.0, não o de 35.2.1. Solicite à e-con (Developer Resources / ticket de suporte):
> NileCAM81_CUOAGX para **JetPack 5.1 / L4T R35.2.1** (kernel 5.10.104) — release **R01_RC4**
> (10-FEB-2023) ou equivalente 35.2.1. Padrão do nome: `e-CAM_YUV-GMSL-PRODUCTS_..._L4T35.2.1_..._R01`.

**Depois de ter o pacote 35.2.1, é zero reflash:**
1. Instalar os **dois** drivers no flash 35.2.1 (e-CAM82 já está; instalar o da NileCAM81).
   Os módulos são diferentes (`eimx485` vs `nilecam`/`max96712`) e **coexistem**; o
   **device tree ativo** decide qual câmera é probada no boot.
2. Manter os **dois DTBs** em `/boot` e selecionar o ativo via `/boot/extlinux/extlinux.conf`
   (linha `FDT`), um por câmera — sem reflash.
3. **Trocar de câmera:** desligar → trocar a base board no **J509** (HEX MIPI ↔
   desserializador GMSL) + conectar a câmera → bootar com o DTB correspondente.

> **Automação possível:** um comando `canpass-camera ecam82|nilecam81` que troca a linha
> `FDT` do extlinux e reinicia — a montar quando o pacote 35.2.1 estiver instalado e os
> nomes reais dos DTBs (`...camera-4lane-eimx485.dtb` × `...nilecam..._two_lane.dtb`)
> forem conhecidos.

**Alternativa (se a e-con só fornecer NileCAM81 mais novo):** reflashar **uma única vez**
para L4T 35.4.1 (JP 5.1.2) — a NileCAM81 35.4.1 você já tem; obter a e-CAM82 para 35.4.1.
Depois nunca mais reflasha. É inferior a ficar no 35.2.1 (exige 1 reflash + driver e-CAM82
novo), mas funciona.

---

### Sensor — comparação rápida

| | e-CAM82_CUOAGX (atual) | NileCAM81_CUOAGX |
|---|---|---|
| Sensor | Sony **IMX485** 8 MP | onsemi **AR0821** 8 MP |
| Interface | **MIPI CSI-2** (IPEX) | **GMSL2** (coax FAKRA) |
| Conexão ao Orin | base board MIPI | desserializador no **J509** |
| Flash atual serve? | ✅ (35.2.1) | ❌ (precisa 35.4.1 / 36.3.0 ou build 35.2.1) |
