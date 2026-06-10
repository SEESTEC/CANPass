# canpass-can — leitura e log do barramento CAN (CANable USB)

Sniffer **SocketCAN** para o adaptador **CANable** (driver `gs_usb`) no Jetson AGX Orin,
usado para ler o barramento **J1939 da Caterpillar** (250 kbit/s, IDs de 29 bits).

O script (`/.rsc/canpass-can.sh`, instalado como `canpass-can` pelo `install.sh`) resolve a
interface **pelo driver** (`gs_usb`), e não pelo nome: mesmo que o adaptador reenumere e mude
de `can2` para `can3`, o comando continua acertando — e ignora os CAN nativos do Tegra
(`mttcan`).

> **Listen-only é o padrão.** O CANable não transmite, não dá ACK nem injeta frames de erro —
> é seguro plugar no barramento do veículo sem perturbar a rede. Para modo ativo
> (permitir `cansend`), use `CANPASS_CAN_ACTIVE=1` (cuidado em veículo).

## Comandos

```
canpass-can <comando> [bitrate]
```

Sem argumentos, executa `detect`. O `[bitrate]` é opcional em todos os comandos que o
aceitam — padrão **250000** (J1939), sobreponível por `CANPASS_CAN_BITRATE`.

| Comando | Parâmetro | O que faz |
|---|---|---|
| `detect` | — | Lista as interfaces `can*` com seu driver e aponta qual é o CANable (`gs_usb`), ignorando o CAN nativo do Orin (`mttcan`). Confere também a presença no USB (`lsusb`). |
| `up` | `[bitrate]` | Só sobe a interface (listen-only, `restart-ms 100` p/ auto-recuperar de bus-off) e desliga o autosuspend USB do adaptador. |
| `dump` | `[bitrate]` | `up` + `candump -tA` no terminal (timestamp com **data+hora real**). **Supervisionado** (ver abaixo). Ctrl+C encerra. |
| `ascii` (ou `text`) | `[bitrate]` | `up` + `candump -tA -a`: hex + coluna **ASCII** do payload (`.` = byte não-imprimível). Útil p/ frames que carregam texto (VIN, IDs de software); em dados binários vira ponto/lixo (normal). **Supervisionado.** |
| `sniff` | `[bitrate]` | Monitora **bytes que mudam**: imprime uma linha só quando algum byte de um ID muda, destacando o byte em **vermelho**. Funciona com IDs estendidos (29-bit/J1939), ao contrário do `cansniffer` do can-utils. Ideal p/ achar qual ID/byte corresponde a cada eixo do joystick — mexa **um** eixo por vez. **Supervisionado** — o estado dos bytes sobrevive às reciclagens (candump → FIFO → awk). |
| `log` (ou `record`) | `[bitrate]` | Grava a CAN em **arquivo de log** (ver seção abaixo). **Supervisionado.** Ctrl+C encerra. |
| `selftest` (ou `test`) | `[bitrate]` | **Loopback interno**: envia 1 frame (`5A5#DEADBEEF`) e espera o eco — prova controlador + driver gs_usb + caminho USB **sem depender do barramento**. Pede confirmação de que o adaptador está **desconectado do veículo** (o teste sai do listen-only) e deixa a interface DOWN ao final. |
| `status` | — | `ip -details -statistics link show` da interface: estado e contadores. Bitrate certo = `ERROR-ACTIVE`, erros parados, RX subindo. |
| `down` | — | Derruba a interface. |
| `help` (ou `-h`, `--help`) | — | Mostra o uso. |

### Exemplos

```bash
canpass-can detect            # qual interface é o CANable?
canpass-can dump              # ler no terminal @ 250 kbit/s (J1939)
canpass-can dump 500000       # idem @ 500 kbit/s
canpass-can ascii             # ver payload também como texto
canpass-can sniff             # achar o ID/byte de um eixo do joystick
canpass-can log               # gravar em arquivo p/ sincronizar com o vídeo
canpass-can selftest          # adaptador OK? (loopback — FORA do veículo)
canpass-can status            # diagnóstico (bitrate certo? RX subindo?)
canpass-can down
```

## `log` — gravação em arquivo

```bash
canpass-can log [bitrate]
```

Grava os frames em `can_YYYYMMDD_HHMMSS.log` dentro de `CANPASS_CAN_LOGDIR`
(senão `CANPASS_REC_DIR`, senão `~/canpass_rec` — o **mesmo diretório das gravações de
vídeo**, para manter vídeo + CAN juntos).

- **Formato padrão**: `candump -L` — timestamp **epoch**, **replayável** com
  `canplayer -I <arquivo>`. O epoch é o mesmo relógio do vídeo, permitindo casar
  imagem ↔ frame CAN depois.
- **Formato legível**: `CANPASS_CAN_LOG_HUMAN=1` grava com `-tA` (data+hora) —
  porém esse formato **não** é replayável pelo `canplayer`.
- Acompanhe ao vivo em outro terminal: `tail -f <arquivo>`.

### Supervisão (auto-resume + watchdog de fluxo) — `dump`/`ascii`/`sniff`/`log`

Todos os modos de leitura rodam supervisionados e **não desistem**:

- Se o **candump morrer** (interface caiu/reenumerou, p.ex. replug do USB), re-detecta o
  CANable pelo driver e retoma (o `log` continua a gravação **no mesmo arquivo**).
- Se o CANable **sumir do USB**, aguarda reaparecer (tentativas a cada 2 s).
- **Watchdog de fluxo**: se ficar `CANPASS_CAN_STALL_SECS` segundos (padrão **6**) sem
  receber frame novo (`rx_packets` parado — cobre o caso "candump vivo mas RX travado"
  do gs_usb), recicla a interface (down/up) e continua.
- Num barramento mudo, avisa na 1ª reciclagem e depois só a cada ~10 ("chave da máquina
  ligada? fiação?"); quando os frames voltam, anuncia "RX voltou".
- `log` e `sniff` imprimem a cada 15 s um "vivo HH:MM:SS — N frames recebidos" no
  terminal (não vai pro arquivo); no `dump`/`ascii` os próprios frames mostram a vida.

## `selftest` — prova o adaptador sem depender do barramento

```bash
canpass-can selftest        # FORA do veículo — o teste sai do listen-only
```

Sobe a interface em **loopback interno** (o controlador ecoa o próprio frame), envia
`5A5#DEADBEEF` via `cansend` e espera o eco por até 3 s. O eco só acontece se o adaptador
realmente processar o TX — é isso que separa "travado" de "OK":

- **PASS** → controlador, driver gs_usb e caminho USB estão OK. Se o `dump` segue vazio
  no veículo, o problema está **depois** do adaptador: chave da máquina desligada,
  CAN_H/CAN_L nos pinos errados (no conector Deutsch 9p da CAT, J1939 = pinos **F/G**;
  **D/E** são CAT Data Link, que não é CAN) ou transceiver queimado.
- **FAIL** → adaptador travado ou defeituoso: **replugue o USB** (power-cycle real —
  `ip link down/up` não reseta o firmware) e repita; persistindo, troque o CANable.

Ao final a interface fica **DOWN** (nunca permanece em loopback) — `canpass-can dump`
religa em listen-only.

## Variáveis de ambiente

| Variável | Padrão | Efeito |
|---|---|---|
| `CANPASS_CAN_IF` | _(auto-detecção)_ | Força a interface (ex.: `can2`), pulando a busca por driver `gs_usb`. |
| `CANPASS_CAN_BITRATE` | `250000` | Bitrate padrão quando o `[bitrate]` não é passado no comando. |
| `CANPASS_CAN_ACTIVE` | `0` | `=1` sobe **sem** listen-only — permite transmitir (`cansend`). **Cuidado em veículo.** |
| `CANPASS_CAN_LOGDIR` | `CANPASS_REC_DIR` → `~/canpass_rec` | Diretório dos arquivos do `log`. |
| `CANPASS_CAN_LOG_HUMAN` | `0` | `=1` grava o `log` com data+hora legível (`-tA`) em vez de epoch — **não replayável**. |
| `CANPASS_CAN_STALL_SECS` | `6` | Segundos sem frame novo antes de o watchdog (`dump`/`ascii`/`sniff`/`log`) reciclar a interface. |

Exemplos:

```bash
CANPASS_CAN_IF=can2 canpass-can dump            # força a interface
CANPASS_CAN_BITRATE=500000 canpass-can log      # muda o bitrate padrão
CANPASS_CAN_LOGDIR=/data/can canpass-can log    # muda o destino do log
CANPASS_CAN_LOG_HUMAN=1 canpass-can log         # log legível (sem replay)
CANPASS_CAN_ACTIVE=1 canpass-can up             # modo ativo (transmite!)
```

## Solução de problemas

- **CANable não encontrado** — replugue o adaptador e cheque:
  `lsusb | grep -iE '1d50:606f|1209:2323'` · `dmesg | grep -i gs_usb`.
- **`candump` ausente** — `sudo apt-get install can-utils`.
- **Nada chega / só erros** — bitrate errado é a causa clássica. Rode `canpass-can status`:
  bitrate certo aparece como `ERROR-ACTIVE` com contadores de erro parados e RX subindo.
  Caterpillar/J1939 = **250000**.
- **`status` com TUDO zerado** (RX **e** `bus-errors`/`error-warn` em 0) ≠ bitrate errado:
  significa **barramento mudo no conector** — nenhuma transição elétrica chegou. Chave da
  máquina desligada, fiação/pinos errados ou adaptador travado/queimado. Rode
  `canpass-can selftest` (fora do veículo) para separar adaptador de fiação.
- **"Parou de receber" após um tempo** — causa comum era o autosuspend USB; o script já o
  desliga ao subir a interface, e o `log` ainda tem o watchdog de fluxo como rede de segurança.
