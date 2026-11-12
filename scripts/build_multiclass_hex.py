#!/usr/bin/env python3
"""Empilha 4 gravacoes do dataset num unico .hex por canal, para a demo de
4 estados na placa (SW[9:8] escolhe a classe).

Cada classe ocupa WINDOW amostras contiguas; input_buffer.v le
mem[class_sel*WINDOW + indice]. Ordem das classes = ordem de SW[9:8]:

    00 normal          -> letra 'n'
    01 desbalanceamento-> letra 'b'
    10 desalinhamento  -> letra 'A'
    11 rolamento       -> letra 'r'

Por que um arquivo empilhado e nao 4 $readmemh com offset: o $readmemh de
4 argumentos (arquivo, memoria, inicio, fim) existe no padrao, mas a
inferencia de memoria do Quartus e historicamente fragil com ele -- e este
modulo ja perdeu a inferencia de M10K uma vez por um detalhe parecido
(4506 ALUTs e zero M10K, ver cabecalho de input_buffer.v). Um arquivo
unico usa o $readmemh de 2 argumentos, que e exatamente a forma ja
comprovada em sintese real neste projeto.

    python3 scripts/build_multiclass_hex.py
"""
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
ENTRADA = RAIZ / "dataset_convertido"
SAIDA = ENTRADA / "multiclasse"
WINDOW = 2048  # 1 janela de vibracao = 80ms; 1 aperto de KEY1 = 1 resultado

# A severidade de desbalanceamento e 3318mg de proposito: e a unica que o
# classificador separa de forma robusta (ver projeto.md, 12/09/2026 -- a de
# 1751mg fica em cima do limiar e erra 1 de 2 janelas).
CLASSES = [
    ("normal",           "0Nm_Normal"),
    ("desbalanceamento", "0Nm_Unbalance_3318mg"),
    ("desalinhamento",   "0Nm_Misalign_03"),
    ("rolamento",        "0Nm_BPFI_10"),
]
CANAIS = ["vibracao", "corrente_fase_a", "corrente_fase_b",
          "corrente_fase_c", "temperatura"]


def ler_amostras(caminho: Path, n: int) -> list:
    linhas = [l.strip() for l in caminho.read_text().splitlines()]
    dados = [l for l in linhas if l and not l.startswith("//")]
    if len(dados) < n:
        raise SystemExit(f"ERRO: {caminho} tem {len(dados)} amostras, precisa de {n}")
    return dados[:n]


def main():
    SAIDA.mkdir(parents=True, exist_ok=True)
    for canal in CANAIS:
        saida = []
        for rotulo, pasta in CLASSES:
            origem = ENTRADA / pasta / f"{canal}.hex"
            if not origem.exists():
                raise SystemExit(f"ERRO: falta {origem}. Rode convert_dataset.py {pasta}")
            saida.extend(ler_amostras(origem, WINDOW))
        destino = SAIDA / f"{canal}.hex"
        cabecalho = ("// multiclasse " + canal + ": " +
                     " | ".join(f"{i:02b}={r}" for i, (r, _) in enumerate(CLASSES)) +
                     f", {WINDOW} amostras cada, {len(saida)} no total, Q1.15")
        destino.write_text(cabecalho + "\n" + "\n".join(saida) + "\n")
        print(f"  {destino.relative_to(RAIZ)}: {len(saida)} amostras "
              f"({len(CLASSES)} x {WINDOW})")
    print(f"\ntotal na FPGA: 5 canais x {len(CLASSES)*WINDOW} x 16 bits = "
          f"{5*len(CLASSES)*WINDOW*16} bits")
    return 0


if __name__ == "__main__":
    sys.exit(main())
