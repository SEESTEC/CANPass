# NileCAM81_CUOAGX — análise de compatibilidade com o Orin atual

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

| Peça | Modelo | Função |
|------|--------|--------|
| Módulo da câmera | `e-CAM82_CUMI0821_MOD` (sensor **AR0821** 8 MP + ISP) | sensor |
| Placa serializadora | `e-CAM22_CUMI_SER` (serializador GMSL Maxim) | serializa vídeo→coax |
| Placa **desserializadora** | `e-CAM_CUOAGX_DESER_6H01R1` (6 conectores FAKRA) | coax→Orin |

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

| Pacote no repo | Alvo | Kernel | Roda em 35.2.1? |
|----------------|------|--------|-----------------|
| `JP5.1.2_L4T35.4.1` (R02, jan/2024) | L4T **35.4.1** / JP 5.1.2 | `5.10.120-tegra` | ❌ |
| `JP6.0_L4T36.3.0` (R03, ago/2024)   | L4T **36.3.0** / JP 6.0.0 | `5.15.x-tegra`   | ❌ |

Motivos técnicos (lidos nos `install_binaries.sh`):

- **Checagem exata de L4T (pacote JP5.1.2, linha 148):**
  `if [ $L4T_VERSION != "$JETSON_L4T_STRING" ]` → exige **`L4T35.4.1`**; o Orin reporta
  `L4T35.2.1` → **aborta**. (O pacote JP6.0 foi afrouxado por nós para checar só o major,
  mas major 36 ≠ 35 → também aborta.)
- **Kernel próprio:** o instalador compara `/boot/Image` com o `Kernel/Image` do pacote
  (linha 181) e traz **kernel + módulos `.ko` compilados para 35.4.1 (5.10.120)**. Os
  módulos não dão `insmod` em `5.10.104` (vermagic diferente). Afrouxar o check de versão
  **não** resolve — a ABI do kernel é o bloqueio real.

As *Release Notes* mostram que a e-con já publicou builds da NileCAM81 para várias
revisões L4T 35.x — então **existe** a possibilidade de um build para 35.2.1, mas ele
**não está neste repositório**; teria de ser solicitado à e-con.

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

### Sensor — comparação rápida

| | e-CAM82_CUOAGX (atual) | NileCAM81_CUOAGX |
|---|---|---|
| Sensor | Sony **IMX485** 8 MP | onsemi **AR0821** 8 MP |
| Interface | **MIPI CSI-2** (IPEX) | **GMSL2** (coax FAKRA) |
| Conexão ao Orin | base board MIPI | desserializador no **J509** |
| Flash atual serve? | ✅ (35.2.1) | ❌ (precisa 35.4.1 / 36.3.0 ou build 35.2.1) |
