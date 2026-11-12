#!/usr/bin/env python3
"""Recalibracao dos 3 limiares de ml_classifier.v (12/09/2026).

Por que uma recalibracao nova: os limiares anteriores (TH_MISALIGN=2268,
TH_UNBALANCE=1762) foram calibrados em Python sobre features numa escala
que o RTL NAO produzia -- o feat_bearing_energy real valia ~51, entao os
dois comparadores nunca disparavam e o classificador so conseguia emitir
"normal" ou "rolamento". Medido, nao suposto: ver projeto.md, 12/09/2026.

O que mudou desde entao, e que obriga recalibrar:
  1. cic_decimator32.v ganhou OUT_SHIFT=6 no ramo de vibracao (recupera
     6 bits de headroom que o ganho DC unitario descartava);
  2. mag_extractor.v passou a expor feat_rotation (linha 1x de rotacao,
     bin 4 = 50Hz), e o comparador de desbalanceamento migrou para ela;
  3. a ordem da arvore virou rolamento > desbalanceamento > desalinhamento.

Entrada: dados_calibracao_2026_09_12.log -- 8 janelas de cada uma das 4
classes, medidas atraves do PIPELINE RTL REAL (xrun, tb_calib.v), nao de
um modelo Python do datapath. Cada linha: classe lms rot bearE classe_obtida

Criterio: entre todos os conjuntos de limiares que acertam as 32 janelas,
escolhe o que MAXIMIZA A MENOR MARGEM relativa -- o mais longe possivel de
qualquer fronteira, em vez do primeiro que funciona.

    python3 scripts/recalibrate_2026_09_12.py
"""
import sys
from pathlib import Path
from collections import defaultdict

LOG = Path(__file__).parent / "dados_calibracao_2026_09_12.log"
CLASSES = ["normal", "desbalanceamento", "desalinhamento", "rolamento"]
ONEHOT = {"normal": "0001", "desbalanceamento": "0010",
          "desalinhamento": "0100", "rolamento": "1000"}


def carregar():
    amostras = []
    for linha in LOG.read_text().splitlines():
        if not linha.startswith("C "):
            continue
        p = linha.split()
        amostras.append((p[1], int(p[2]), int(p[3]), int(p[4])))
    return amostras


def prever(lms, rot, bear, th_bear, th_unb, th_mis):
    """Mesma arvore de ml_classifier.v, mesma ordem de prioridade."""
    if lms > th_bear:
        return "rolamento"
    if rot > th_unb:
        return "desbalanceamento"
    if bear > th_mis:
        return "desalinhamento"
    return "normal"


def limiar_de_maior_margem(abaixo, acima, nome):
    """Ponto medio entre o maior valor que deve ficar abaixo e o menor que
    deve ficar acima. Se nao ha separacao, devolve None."""
    hi, lo = max(abaixo), min(acima)
    if hi >= lo:
        print(f"  !! {nome}: SEM SEPARACAO -- max(abaixo)={hi} >= min(acima)={lo}")
        return None, 0
    return (hi + lo) // 2, (lo - hi) // 2


def main():
    amostras = carregar()
    if len(amostras) != 32:
        print(f"aviso: esperava 32 janelas, li {len(amostras)}")
    por_classe = defaultdict(list)
    for c, lms, rot, bear, in ((a[0], a[1], a[2], a[3]) for a in amostras):
        por_classe[c].append((lms, rot, bear))

    print("=== faixas medidas (8 janelas por classe, pipeline RTL real) ===")
    print(f"{'classe':>18} {'lms_residual':>22} {'rotacao (bin 4)':>20} {'bearing_energy':>20}")
    for c in CLASSES:
        v = por_classe[c]
        f = lambda i: f"{min(x[i] for x in v)}..{max(x[i] for x in v)}"
        print(f"{c:>18} {f(0):>22} {f(1):>20} {f(2):>20}")

    # Cada limiar separa um grupo especifico, seguindo a ORDEM da arvore:
    # o teste de rolamento ve todas as classes; o de desbalanceamento so ve
    # quem passou pelo primeiro; o de desalinhamento so quem passou por dois.
    print("\n=== limiares por maior margem ===")
    nao_rol = [c for c in CLASSES if c != "rolamento"]
    th_bear, m1 = limiar_de_maior_margem(
        [x[0] for c in nao_rol for x in por_classe[c]],
        [x[0] for x in por_classe["rolamento"]], "TH_BEARING")
    resto1 = ["normal", "desalinhamento"]
    th_unb, m2 = limiar_de_maior_margem(
        [x[1] for c in resto1 for x in por_classe[c]],
        [x[1] for x in por_classe["desbalanceamento"]], "TH_UNBALANCE")
    th_mis, m3 = limiar_de_maior_margem(
        [x[2] for x in por_classe["normal"]],
        [x[2] for x in por_classe["desalinhamento"]], "TH_MISALIGN")
    if None in (th_bear, th_unb, th_mis):
        print("\nFALHOU: alguma feature nao separa. Nao ha limiar a propor.")
        return 1
    print(f"  TH_BEARING   = {th_bear:6d}  (feat_lms_residual,   margem +-{m1})")
    print(f"  TH_UNBALANCE = {th_unb:6d}  (feat_rotation,       margem +-{m2})")
    print(f"  TH_MISALIGN  = {th_mis:6d}  (feat_bearing_energy, margem +-{m3})")

    print("\n=== matriz de confusao com esses limiares ===")
    mat = {v: defaultdict(int) for v in CLASSES}
    acertos = 0
    for c, lms, rot, bear in amostras:
        p = prever(lms, rot, bear, th_bear, th_unb, th_mis)
        mat[c][p] += 1
        acertos += (p == c)
    cab = "".join(f"{c[:8]:>10}" for c in CLASSES)
    rotulo = "real \\ previsto"
    print(f"{rotulo:>18}{cab}")
    for c in CLASSES:
        print(f"{c:>18}" + "".join(f"{mat[c][p]:>10}" for p in CLASSES))
    print(f"\nacerto: {acertos}/{len(amostras)} ({100*acertos/len(amostras):.1f}%)")
    print("\nPara ml_classifier.v:")
    print(f"  parameter signed [15:0] TH_BEARING   = 16'sd{th_bear},")
    print(f"  parameter signed [15:0] TH_MISALIGN  = 16'sd{th_mis},")
    print(f"  parameter signed [15:0] TH_UNBALANCE = 16'sd{th_unb}")
    return 0 if acertos == len(amostras) else 1


if __name__ == "__main__":
    sys.exit(main())
