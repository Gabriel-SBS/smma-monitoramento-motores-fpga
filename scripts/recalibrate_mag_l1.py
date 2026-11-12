#!/usr/bin/env python3
"""Recalibra TH_MISALIGN/TH_UNBALANCE de ml_classifier.v depois do bug real
achado em varredura (28/08/2026, ver projeto.md "Underflow de magnitude L2
em mag_extractor.v"): a implementação original de feat_bearing_energy usava
magnitude L2 (sqrt(re²+im²)), que elevava ao quadrado valores Q1.15
pequenos e reescalava por >>15 -- isso ZERA qualquer bin cujo módulo bruto
seja menor que ~182 (de 32768). Medido em simulação real: TODOS os bins da
FFT decimada real ficam bem abaixo desse piso -- feat_bearing_energy saía
SEMPRE zero na integração (`smma_top.v`), tornando desalinhamento/
desbalanceamento estruturalmente inatingíveis, não uma questão de recall
baixo. `mag_extractor.v` foi reescrito pra usar L1 (|re|+|im|, mesma
filosofia de `peak_detector.v`), que não sofre desse underflow.

IMPORTANTE: mesmo a recalibração k0_mdc anterior (`compare_k0_methods.py`)
usava `spec.sum()` onde `spec = np.abs(fft_complexo)` -- ou seja, TAMBÉM
L2, em ponto flutuante (sem o underflow de ponto fixo, mas ainda assim
matematicamente diferente do que o hardware corrigido (L1) realmente
produz). Os limiares atuais (TH_MISALIGN=1787, TH_UNBALANCE=1389) nunca
foram calibrados contra a métrica que o hardware de fato calcula --
precisam ser recalibrados do zero contra L1, não só ganhar um novo valor
numérico pela mesma fórmula.

Reaproveita a MESMA pipeline/infraestrutura já usada (decimação 32x,
janela 64, FFT real, k0_mdc como fonte de verdade -- não k0_python, mesma
decisão já tomada na recalibração anterior) -- só a fórmula de
feat_bearing_energy muda de L2 pra L1.

Uso:
    python3 scripts/recalibrate_mag_l1.py
"""
import math
import sys
from pathlib import Path

import numpy as np
from scipy.signal import decimate

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compare_ml_accuracy import CLASS_IDX, CLASSES, class_from_filename  # noqa: E402
from compare_ml_accuracy_hw import MU_SHIFT, lms_residual_stream, quantize_q15  # noqa: E402
from compare_ml_accuracy_final import (  # noqa: E402
    DECIMATION,
    WINDOW_SAMPLES_DEC,
    MAX_WINDOWS_PER_FILE,
    RAW_SAMPLES_PER_FILE,
    FEATURE_NAMES,
    fixed_tree_predict,
    balance_classes,
    calibrate_fixed_tree,
    report,
)
from convert_dataset import DATASET_DIR, load_vibration  # noqa: E402


def k0_mdc(re, im):
    """Mesma simulacao de peak_detector.v+mdc_euclides.v ja usada em
    compare_k0_methods.py -- k0_mdc e a fonte de verdade (nao k0_python),
    decisao ja tomada na recalibracao anterior."""
    mag = np.abs(re[1:32]) + np.abs(im[1:32])  # L1, bins 1..31
    order = np.argsort(mag)[::-1]
    bin_a = int(order[0]) + 1
    bin_b = int(order[1]) + 1
    return math.gcd(bin_a, bin_b)


def build_dataset_l1(loads):
    """Mesma extracao de janelas de compare_k0_methods.py, mas
    feat_bearing_energy (e feat_fundamental/feat_2nd_harmonic, por
    completude) usam L1 (|re|+|im|) igual ao mag_extractor.v corrigido, nao
    mais L2 (np.abs do complexo)."""
    X, y = [], []
    for mat_path in sorted((DATASET_DIR / "vibration").glob("*.mat")):
        stem = mat_path.stem
        load = stem.split("_", 1)[0]
        if load not in loads:
            continue
        cls = class_from_filename(stem)

        vib = load_vibration(stem, RAW_SAMPLES_PER_FILE)
        n_raw = (len(vib) // (WINDOW_SAMPLES_DEC * DECIMATION)) * (WINDOW_SAMPLES_DEC * DECIMATION)
        vib = vib[:n_raw]
        vib_q15 = quantize_q15(vib)

        dec8 = decimate(vib_q15, 8, ftype="fir")
        dec32 = decimate(dec8, 4, ftype="fir")

        residual = lms_residual_stream(vib_q15, mu_shift=MU_SHIFT)

        n_windows = min(MAX_WINDOWS_PER_FILE, len(dec32) // WINDOW_SAMPLES_DEC)

        for w in range(n_windows):
            seg = dec32[w * WINDOW_SAMPLES_DEC:(w + 1) * WINDOW_SAMPLES_DEC]
            win = seg * np.hanning(WINDOW_SAMPLES_DEC)
            c = np.fft.rfft(win, n=WINDOW_SAMPLES_DEC)
            re, im = c.real.copy(), c.imag.copy()
            re[0], im[0] = 0.0, 0.0  # bin 0 (DC) forcado a zero, igual mag_extractor.v

            mag_l1_all = np.abs(re) + np.abs(im)  # L1 -- mesma formula de mag_l1() no RTL

            k0 = k0_mdc(re, im)

            feat_fund = mag_l1_all[k0] if k0 < len(mag_l1_all) else 0.0
            k2 = 2 * k0
            feat_2nd = mag_l1_all[k2] if k2 < len(mag_l1_all) else 0.0
            # soma so ate bin 32 (SCAN_MAX do RTL), nao o array rfft inteiro
            # (que vai ate bin 32 mesmo pra N=64 -- len(mag_l1_all)==33)
            feat_bearing = float(mag_l1_all.sum() - feat_fund - feat_2nd)

            raw_start = w * WINDOW_SAMPLES_DEC * DECIMATION
            raw_end = raw_start + WINDOW_SAMPLES_DEC * DECIMATION
            res_seg = residual[raw_start:raw_end]
            feat_lms = float(np.sqrt(np.mean(res_seg ** 2))) if len(res_seg) else 0.0

            X.append([feat_fund, feat_2nd, feat_bearing, feat_lms])
            y.append(CLASS_IDX[cls])

        print(f"  {stem}: {n_windows} janelas ({cls})")

    return np.array(X), np.array(y)


def main():
    print("Recalibracao pos-fix L2->L1 de mag_extractor.v -- feat_bearing_energy "
          "agora usa |re|+|im| (L1), nao mais sqrt(re^2+im^2) (L2, que zerava "
          "sempre em ponto fixo real). k0_mdc como fonte de verdade (nao k0_python), "
          "mesma decisao da recalibracao anterior.\n")

    print("Carregando janelas de TREINO (cargas 0Nm + 4Nm)...")
    X_train, y_train = build_dataset_l1({"0Nm", "4Nm"})
    print(f"\nTreino (bruto, desbalanceado): {len(y_train)} janelas")
    X_train_bal, y_train_bal = balance_classes(X_train, y_train)
    print(f"Treino (balanceado): {len(y_train_bal)} janelas ({len(y_train_bal)//len(CLASSES)} por classe)")

    print("\nCarregando janelas de TESTE (carga 2Nm, nao vista no treino)...")
    X_test, y_test = build_dataset_l1({"2Nm"})
    print(f"\nTeste: {len(y_test)} janelas")

    print("\nCalibrando limiares E atribuicao de feature da arvore de estrutura fixa "
          "(3 comparadores em prioridade fixa, igual ml_classifier.v) no treino balanceado...")
    (feat_idx, thresholds), train_bacc = calibrate_fixed_tree(X_train_bal, y_train_bal)
    f_bearing, f_misalign, f_unbalance = feat_idx
    t_bearing, t_misalign, t_unbalance = thresholds
    print(f"  comparador 'rolamento'  usa {FEATURE_NAMES[f_bearing]:14s} > {t_bearing:.5f}")
    print(f"  comparador 'desalinham.' usa {FEATURE_NAMES[f_misalign]:14s} > {t_misalign:.5f}")
    print(f"  comparador 'desbalance.' usa {FEATURE_NAMES[f_unbalance]:14s} > {t_unbalance:.5f}")
    print(f"  acuracia balanceada no treino = {train_bacc*100:.1f}%")

    pred_test = fixed_tree_predict(X_test, feat_idx, thresholds)
    acc, cm = report("Arvore de estrutura FIXA (igual ml_classifier.v), L1 real + k0_mdc", y_test, pred_test)

    print("\n>>> Recall por classe: " +
          ", ".join(f"{c}={cm[i,i]/cm[i].sum()*100:.1f}%" for c, i in CLASS_IDX.items()) + " <<<")

    # conversao pra Q1.15 inteiro (escala usada em ml_classifier.v -- os
    # feats do RTL sao inteiros Q1.15, nao float [0,1))
    print("\n" + "=" * 70)
    print("LIMIARES EM Q1.15 INTEIRO (pra colar em ml_classifier.v):")
    print(f"  TH_BEARING   (feat_lms_residual) = {round(t_bearing*32768):6d}  (era 832)")
    print(f"  TH_MISALIGN  (feat_bearing_energy) = {round(t_misalign*32768):6d}  (era 1787)")
    print(f"  TH_UNBALANCE (feat_bearing_energy) = {round(t_unbalance*32768):6d}  (era 1389)")


if __name__ == "__main__":
    main()
