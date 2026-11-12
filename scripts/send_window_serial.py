#!/usr/bin/env python3
"""Envia uma janela do dataset convertido para a placa DE0-CV pela UART.

Contraparte de `rtl/serial_loader.v` (entregavel §6.7). Le os 5 arquivos
.hex de uma classe de `dataset_convertido/` e transmite no protocolo que o
carregador espera:

    [A5][5A][A5][5A]                        magic word (ressincronizacao)
    para cada uma das N amostras, 10 bytes:
        vib_lo vib_hi  ca_lo ca_hi  cb_lo cb_hi  cc_lo cc_hi  temp_lo temp_hi

Little-endian, Q1.15 em complemento de 2 -- exatamente a representacao ja
usada nos .hex (Decisao 1), entao nao ha reinterpretacao de valor aqui, so
reempacotamento.

Por que carregar em lote e nao streamar em tempo real: o pipeline consome 5
canais x 25,6 kHz x 16 bits = 2,048 Mbit/s, muito acima de qualquer UART
comum. A placa carrega a janela inteira na memoria e SO ENTAO a reproduz na
cadencia real de 25,6 kHz -- entao o baud afeta o tempo de espera, nunca a
fidelidade do processamento. Ver o cabecalho de serial_loader.v.

Uso:
    python3 scripts/send_window_serial.py 0Nm_Misalign_03
    python3 scripts/send_window_serial.py 0Nm_Normal --port /dev/ttyUSB0 --baud 115200

Depois de "janela enviada", aperte KEY1 na placa para classificar.

Requer pyserial (`pip install pyserial`). Sem a placa conectada, use
--dry-run para so gerar/conferir o arquivo binario.
"""

import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DATASET = REPO / "dataset_convertido"

CANAIS = [
    "vibracao.hex",
    "corrente_fase_a.hex",
    "corrente_fase_b.hex",
    "corrente_fase_c.hex",
    "temperatura.hex",
]

MAGIC = bytes([0xA5, 0x5A, 0xA5, 0x5A])
N_SAMPLES_PADRAO = 2048  # profundidade das memorias de input_buffer.v


def ler_hex(caminho: Path, n: int) -> list:
    """Le um .hex de amostras Q1.15 (4 digitos hex por linha, '//' = comentario).

    Retorna exatamente n amostras: preenche com zero se o arquivo for menor
    (o dataset tem classes com fases B/C ausentes -- ver convert_dataset.py).
    """
    if not caminho.exists():
        # classe BPFO nao tem fases B/C; zero e o que o RTL ja usa nesse caso
        return [0] * n

    valores = []
    with open(caminho, "r", encoding="utf-8") as f:
        for linha in f:
            linha = linha.strip()
            if not linha or linha.startswith("//"):
                continue
            valores.append(int(linha, 16))
            if len(valores) == n:
                break

    if len(valores) < n:
        valores.extend([0] * (n - len(valores)))
    return valores


def montar_frame(classe: str, n: int) -> bytes:
    base = DATASET / classe
    if not base.is_dir():
        disponiveis = sorted(p.name for p in DATASET.iterdir() if p.is_dir())
        sys.exit(f"classe '{classe}' nao encontrada em {DATASET}.\n"
                 f"disponiveis: {', '.join(disponiveis)}")

    canais = [ler_hex(base / nome, n) for nome in CANAIS]

    frame = bytearray(MAGIC)
    for i in range(n):
        for ch in canais:
            v = ch[i] & 0xFFFF
            frame.append(v & 0xFF)         # LSB primeiro (little-endian)
            frame.append((v >> 8) & 0xFF)
    return bytes(frame)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("classe", help="nome da pasta em dataset_convertido/ (ex: 0Nm_Normal)")
    ap.add_argument("--port", default="/dev/ttyUSB0", help="porta serial (padrao: /dev/ttyUSB0)")
    ap.add_argument("--baud", type=int, default=115200,
                    help="baud rate; precisa casar com CLKS_PER_BIT em smma_top_de0cv.v (padrao: 115200)")
    ap.add_argument("--samples", type=int, default=N_SAMPLES_PADRAO,
                    help=f"amostras por canal (padrao: {N_SAMPLES_PADRAO}, = profundidade das memorias)")
    ap.add_argument("--dry-run", action="store_true",
                    help="nao abre a serial; grava o frame em window.bin para inspecao")
    args = ap.parse_args()

    frame = montar_frame(args.classe, args.samples)
    esperado = 4 + args.samples * 5 * 2
    assert len(frame) == esperado, f"frame com {len(frame)} bytes, esperado {esperado}"

    segundos = len(frame) * 10 / args.baud  # 8N1 = 10 bits por byte
    print(f"classe .......... {args.classe}")
    print(f"amostras/canal .. {args.samples}")
    print(f"frame ........... {len(frame)} bytes ({len(frame)/1024:.1f} KiB)")
    print(f"tempo estimado .. {segundos:.1f} s a {args.baud} baud")

    if args.dry_run:
        saida = REPO / "window.bin"
        saida.write_bytes(frame)
        print(f"\n--dry-run: frame gravado em {saida} (serial nao aberta)")
        return

    try:
        import serial  # pyserial
    except ImportError:
        sys.exit("pyserial nao instalado. Use: pip install pyserial\n"
                 "(ou rode com --dry-run para so gerar o arquivo)")

    try:
        with serial.Serial(args.port, args.baud, timeout=2) as sp:
            print(f"\nenviando por {args.port} ...")
            sp.write(frame)
            sp.flush()
    except serial.SerialException as e:
        sys.exit(f"falha ao abrir/escrever em {args.port}: {e}")

    print("janela enviada. Na placa: LEDR[6] deve acender (janela carregada).")
    print("Aperte KEY1 para classificar; a classe aparece em LEDR[3:0].")


if __name__ == "__main__":
    main()
