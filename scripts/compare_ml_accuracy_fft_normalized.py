#!/usr/bin/env python3
"""Corrige um erro real de calibração achado em revisão de código (15/08/2026):
a árvore de decisão (Decisão 6) foi calibrada com magnitudes de FFT NÃO
normalizadas (np.fft.rfft puro), mas `fft64_core.v` real aplica escala
incondicional de 1/2 por estágio × 6 estágios = /64 total (técnica clássica
de hardware pra evitar overflow -- ver `fft64_butterfly.v`, confirmado contra
o próprio teste já validado `tb_fft64_top.v`: tom de amplitude 0,5 no bin 5
dá 8192 em Q1.15 = (0,5×64/2)/64 em Q1.15, batendo exato com essa convenção).

Os limiares calibrados contra a magnitude "crua" do Python não valem contra
a saída normalizada do hardware real: os 3 features derivados de FFT
(fundamental/2nd_harmonic/bearing_energy) sairiam ~64x menores no RTL do que
no Python usado pra calibrar -- na prática, os comparadores de
desalinhamento/desbalanceamento quase nunca disparariam contra dado real (só
o de rolamento, via feat_lms_residual, que não passa pela FFT, continuaria
válido).

Correção: divide por 64 os 3 features derivados de FFT (não o lms_residual)
ANTES de calibrar -- reproduzindo fielmente a escala real do fft64_core.v --
e refaz a busca em grade DO ZERO (não só divide os limiares antigos por 64:
a resolução de 16 bits do Q1.15 é finita, a busca precisa rodar de novo
nessa escala pra achar limiares realmente representáveis/distinguíveis, não
assumir que uma divisão linear preserva a granularidade de decisão).

Uso:
    python3 scripts/compare_ml_accuracy_fft_normalized.py
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compare_ml_accuracy import CLASS_IDX, CLASSES, confusion_matrix  # noqa: E402
from compare_ml_accuracy_final import (  # noqa: E402
    FEATURE_NAMES,
    balance_classes,
    balanced_accuracy,
    build_dataset,
    fixed_tree_predict,
)

FFT_SCALE_STAGES = 6                # fft64_core.v: 6 estagios radix-2 (64 pontos)
FFT_SCALE = 2 ** FFT_SCALE_STAGES   # /64, escala incondicional real do RTL
FFT_DERIVED_COLS = [0, 1, 2]        # fundamental, 2nd_harmonic, bearing_energy (indice 3 = lms_residual, nao FFT)


def apply_rtl_fft_scale(X):
    X = X.copy()
    for c in FFT_DERIVED_COLS:
        X[:, c] = X[:, c] / FFT_SCALE
    return X


def calibrate_fixed_tree_scaled(X_train, y_train, n_candidates=12):
    """Mesma busca de calibrate_fixed_tree (compare_ml_accuracy_final.py),
    mas roda DEPOIS da escala real do RTL ja aplicada -- os candidatos de
    limiar vem dos percentis dos dados JA escalados, entao a granularidade
    da busca reflete a resolucao real do Q1.15 nessa faixa."""
    n_classes = len(CLASSES)
    best = (-1.0, None)
    feature_indices = range(4)
    for f_bearing in feature_indices:
        for f_misalign in feature_indices:
            for f_unbalance in feature_indices:
                cand_bearing = np.percentile(X_train[:, f_bearing], np.linspace(30, 99, n_candidates))
                cand_misalign = np.percentile(X_train[:, f_misalign], np.linspace(30, 99, n_candidates))
                cand_unbalance = np.percentile(X_train[:, f_unbalance], np.linspace(30, 99, n_candidates))
                for tb in cand_bearing:
                    for tm in cand_misalign:
                        for tu in cand_unbalance:
                            pred = fixed_tree_predict(X_train, (f_bearing, f_misalign, f_unbalance), (tb, tm, tu))
                            bacc = balanced_accuracy(y_train, pred, n_classes)
                            if bacc > best[0]:
                                best = (bacc, ((f_bearing, f_misalign, f_unbalance), (tb, tm, tu)))
    return best[1], best[0]


def q15(x):
    return round(x * 32768)


def main():
    print(f"Escala real do FFT-64 (6 estagios, 1/2 por estagio cada): /{FFT_SCALE}")
    print("Features FFT-derivadas (corrigidas aqui): fundamental, 2nd_harmonic, bearing_energy")
    print("Feature NAO corrigida (nao passa pela FFT): lms_residual\n")

    print("Carregando janelas de TREINO (cargas 0Nm + 4Nm)...")
    X_train, y_train = build_dataset({"0Nm", "4Nm"})
    X_train = apply_rtl_fft_scale(X_train)
    X_train_bal, y_train_bal = balance_classes(X_train, y_train)
    print(f"Treino balanceado: {len(y_train_bal)} janelas ({len(y_train_bal)//len(CLASSES)} por classe)")

    print("\nCarregando janelas de TESTE (carga 2Nm, nao vista no treino)...")
    X_test, y_test = build_dataset({"2Nm"})
    X_test = apply_rtl_fft_scale(X_test)
    print(f"Teste: {len(y_test)} janelas")

    print("\nMedias por classe (features JA na escala real do RTL, pos-/64):")
    print(f"{'classe':>20}" + "".join(f"{n:>18}" for n in FEATURE_NAMES))
    for c, i in CLASS_IDX.items():
        row = X_train_bal[y_train_bal == i]
        print(f"{c:>20}" + "".join(f"{row[:, j].mean():>18.7f}" for j in range(4)))

    print("\nRecalibrando limiares E atribuicao de feature (escala RTL real, otimizando acuracia balanceada)...")
    (feat_idx, thresholds), train_bacc = calibrate_fixed_tree_scaled(X_train_bal, y_train_bal)
    f_b, f_m, f_u = feat_idx
    t_b, t_m, t_u = thresholds
    print(f"  rolamento        usa {FEATURE_NAMES[f_b]:14s} > {t_b:.7f}  (Q1.15={q15(t_b)})")
    print(f"  desalinhamento   usa {FEATURE_NAMES[f_m]:14s} > {t_m:.7f}  (Q1.15={q15(t_m)})")
    print(f"  desbalanceamento usa {FEATURE_NAMES[f_u]:14s} > {t_u:.7f}  (Q1.15={q15(t_u)})")
    print(f"  acuracia balanceada no treino = {train_bacc*100:.1f}%")

    pred_test = fixed_tree_predict(X_test, feat_idx, thresholds)
    acc = float(np.mean(y_test == pred_test))
    bacc = balanced_accuracy(y_test, pred_test, len(CLASSES))
    cm = confusion_matrix(y_test, pred_test, len(CLASSES))
    print(f"\nTeste (carga 2Nm nao vista): acuracia={acc*100:.1f}%  acuracia_balanceada={bacc*100:.1f}%")
    header = "".join(f"{c[:10]:>12}" for c in CLASSES)
    print(f"{'verdadeiro/predito':>20}{header}")
    for i, c in enumerate(CLASSES):
        recall = cm[i, i] / cm[i].sum() * 100 if cm[i].sum() else 0.0
        row = "".join(f"{cm[i, j]:>12}" for j in range(len(CLASSES)))
        print(f"{c:>20}{row}   (recall={recall:.1f}%)")


if __name__ == "__main__":
    main()
