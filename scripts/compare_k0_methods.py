#!/usr/bin/env python3
"""Compara os 2 métodos de estimar o bin fundamental k0, pendência registrada
em mag_extractor.v e projeto.md (15/08/2026):

  MÉTODO PYTHON (o que a calibração de compare_ml_accuracy_final.py usa):
      k0 = argmax da magnitude numa banda de frequência FIXA (20-120Hz),
      assumindo que a rotação do motor está sempre nessa faixa.

  MÉTODO MDC (o que o hardware realmente calcula, peak_detector.v +
  mdc_euclides.v): acha os 2 bins de maior magnitude L1 no espectro inteiro
  (1..31, sem faixa de frequência alguma) e tira o MDC dos dois -- ideia é
  que harmônicos são múltiplos inteiros da fundamental, então o MDC de dois
  picos aproxima k0, SEM precisar assumir uma faixa de frequência a priori.

  Nunca foram comparados um com o outro contra dado real -- é isso que este
  script faz, sobre os MESMOS dados reais (KAIST) e a MESMA pipeline
  (decimação 32x, janela 64, FFT real) usada pela calibração já existente.

  Duas perguntas reais:
    1) k0_mdc e k0_python concordam? Em quantas janelas, por classe?
    2) Se o classificador usasse feat_fundamental/feat_2nd_harmonic
       calculados com k0_mdc (o que o hardware real produz) EM VEZ de
       k0_python (o que foi calibrado), os limiares JÁ CALIBRADOS ainda
       classificam corretamente no teste (carga 2Nm)? Ou a acurácia cai?

Uso:
    python3 scripts/compare_k0_methods.py
"""
import math
import sys
from pathlib import Path

import numpy as np
from scipy.signal import decimate

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compare_ml_accuracy import CLASS_IDX, CLASSES, class_from_filename, confusion_matrix  # noqa: E402
from compare_ml_accuracy_hw import MU_SHIFT, lms_residual_stream, quantize_q15  # noqa: E402
from compare_ml_accuracy_final import (  # noqa: E402
    DECIMATION,
    WINDOW_SAMPLES_DEC,
    BIN_HZ,
    FUND_BAND_LO_HZ,
    FUND_BAND_HI_HZ,
    MAX_WINDOWS_PER_FILE,
    RAW_SAMPLES_PER_FILE,
    FEATURE_NAMES,
    fixed_tree_predict,
    balanced_accuracy,
    calibrate_fixed_tree,
    balance_classes,
    report,
)
from convert_dataset import DATASET_DIR, load_vibration  # noqa: E402


def k0_mdc(re, im):
    """Simula peak_detector.v (top-2 magnitude L1 entre bins 1..31) +
    mdc_euclides.v (MDC subtrativo). math.gcd(a,0)=a, math.gcd(0,0)=0 --
    mesmo caso de borda tratado explicitamente em mdc_euclides.v
    ("gcd_out <= reg_a | reg_b" quando um dos dois é zero)."""
    mag = np.abs(re[1:32]) + np.abs(im[1:32])  # L1, mesmo bins 1..31 do peak_detector.v
    order = np.argsort(mag)[::-1]
    bin_a = int(order[0]) + 1
    bin_b = int(order[1]) + 1
    return math.gcd(bin_a, bin_b)


def build_dataset_dual(loads):
    """Para cada janela, calcula as 4 features 2 vezes (uma com k0_python,
    uma com k0_mdc), mais os dois valores de k0 pra comparação direta."""
    X_py, X_mdc, y, k0_py_list, k0_mdc_list, cls_list = [], [], [], [], [], []
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
        k_lo = max(1, int(round(FUND_BAND_LO_HZ / BIN_HZ)))
        k_hi = min(WINDOW_SAMPLES_DEC // 2, int(round(FUND_BAND_HI_HZ / BIN_HZ)))

        for w in range(n_windows):
            seg = dec32[w * WINDOW_SAMPLES_DEC:(w + 1) * WINDOW_SAMPLES_DEC]
            win = seg * np.hanning(WINDOW_SAMPLES_DEC)
            c = np.fft.rfft(win, n=WINDOW_SAMPLES_DEC)
            spec = np.abs(c)
            spec[0] = 0.0
            re, im = c.real.copy(), c.imag.copy()
            re[0], im[0] = 0.0, 0.0

            band = spec[k_lo:k_hi + 1]
            k0py = (k_lo + int(np.argmax(band))) if band.size and band.max() > 0 else k_lo
            k0md = k0_mdc(re, im)

            raw_start = w * WINDOW_SAMPLES_DEC * DECIMATION
            raw_end = raw_start + WINDOW_SAMPLES_DEC * DECIMATION
            res_seg = residual[raw_start:raw_end]
            feat_lms = float(np.sqrt(np.mean(res_seg ** 2))) if len(res_seg) else 0.0

            for k0, X_out in ((k0py, X_py), (k0md, X_mdc)):
                feat_fund = spec[k0] if k0 < len(spec) else 0.0
                k2 = 2 * k0
                feat_2nd = spec[k2] if k2 < len(spec) else 0.0
                feat_bearing = float(spec.sum() - feat_fund - feat_2nd)
                X_out.append([feat_fund, feat_2nd, feat_bearing, feat_lms])

            y.append(CLASS_IDX[cls])
            k0_py_list.append(k0py)
            k0_mdc_list.append(k0md)
            cls_list.append(cls)

        print(f"  {stem}: {n_windows} janelas ({cls})")

    return (np.array(X_py), np.array(X_mdc), np.array(y),
            np.array(k0_py_list), np.array(k0_mdc_list), cls_list)


def main():
    print(f"Config: FFT-64 sobre sinal decimado {DECIMATION}x, banda k0_python="
          f"{FUND_BAND_LO_HZ}-{FUND_BAND_HI_HZ}Hz\n")

    print("Carregando janelas de TREINO (cargas 0Nm + 4Nm)...")
    X_py_tr, X_mdc_tr, y_tr, k0py_tr, k0mdc_tr, cls_tr = build_dataset_dual({"0Nm", "4Nm"})
    print(f"\nTreino: {len(y_tr)} janelas")

    print("\nCarregando janelas de TESTE (carga 2Nm, não vista no treino)...")
    X_py_te, X_mdc_te, y_te, k0py_te, k0mdc_te, cls_te = build_dataset_dual({"2Nm"})
    print(f"\nTeste: {len(y_te)} janelas")

    # ---- pergunta 1: k0_mdc e k0_python concordam? ----
    k0py_all = np.concatenate([k0py_tr, k0py_te])
    k0mdc_all = np.concatenate([k0mdc_tr, k0mdc_te])
    cls_all = cls_tr + cls_te
    agree = k0py_all == k0mdc_all
    print("\n" + "=" * 70)
    print(f"CONCORDÂNCIA k0_mdc == k0_python: {agree.mean()*100:.1f}% "
          f"({agree.sum()}/{len(agree)} janelas, todas as cargas)")
    print(f"|k0_mdc - k0_python| médio: {np.mean(np.abs(k0mdc_all.astype(int) - k0py_all.astype(int))):.2f} bins")
    k_lo = max(1, int(round(FUND_BAND_LO_HZ / BIN_HZ)))
    k_hi = min(32, int(round(FUND_BAND_HI_HZ / BIN_HZ)))
    in_band = (k0mdc_all >= k_lo) & (k0mdc_all <= k_hi)
    print(f"k0_mdc dentro da banda plausível [{k_lo},{k_hi}] usada pelo Python: "
          f"{in_band.mean()*100:.1f}% das janelas")

    print("\nConcordância por classe:")
    for c in CLASSES:
        mask = np.array([cc == c for cc in cls_all])
        if mask.sum() == 0:
            continue
        a = (k0py_all[mask] == k0mdc_all[mask]).mean()
        print(f"  {c:20s}: {a*100:5.1f}% concordam  (n={mask.sum()})")

    # ---- pergunta 2: os limiares calibrados com k0_python ainda
    # classificam certo se alimentados com k0_mdc? ----
    X_tr_bal, y_tr_bal = balance_classes(X_py_tr, y_tr)
    print(f"\nTreino balanceado: {len(y_tr_bal)} janelas ({len(y_tr_bal)//len(CLASSES)} por classe)")

    print("\nCalibrando a árvore de estrutura fixa (igual ml_classifier.v) "
          "SÓ com features de k0_python (reproduz a calibração já existente)...")
    (feat_idx, thresholds), train_bacc = calibrate_fixed_tree(X_tr_bal, y_tr_bal)
    f_bearing, f_misalign, f_unbalance = feat_idx
    t_bearing, t_misalign, t_unbalance = thresholds
    print(f"  comparador 'rolamento'  usa {FEATURE_NAMES[f_bearing]:14s} > {t_bearing:.5f}")
    print(f"  comparador 'desalinham.' usa {FEATURE_NAMES[f_misalign]:14s} > {t_misalign:.5f}")
    print(f"  comparador 'desbalance.' usa {FEATURE_NAMES[f_unbalance]:14s} > {t_unbalance:.5f}")
    print(f"  acurácia balanceada no treino = {train_bacc*100:.1f}%")

    pred_py = fixed_tree_predict(X_py_te, feat_idx, thresholds)
    acc_py, cm_py = report("BASELINE -- teste com features de k0_python (o que foi calibrado)", y_te, pred_py)

    pred_mdc = fixed_tree_predict(X_mdc_te, feat_idx, thresholds)
    acc_mdc, cm_mdc = report("REAL -- MESMOS limiares, teste com features de k0_mdc (o que o hardware produz)", y_te, pred_mdc)

    print("\n" + "=" * 70)
    print(f"RESUMO: acurácia com k0_python={acc_py*100:.1f}%  vs  k0_mdc={acc_mdc*100:.1f}%  "
          f"(delta={100*(acc_mdc-acc_py):+.1f}pp)")
    print(">>> Recall por classe (k0_python): " +
          ", ".join(f"{c}={cm_py[i,i]/cm_py[i].sum()*100:.1f}%" for c, i in CLASS_IDX.items()))
    print(">>> Recall por classe (k0_mdc):    " +
          ", ".join(f"{c}={cm_mdc[i,i]/cm_mdc[i].sum()*100:.1f}%" for c, i in CLASS_IDX.items()))


if __name__ == "__main__":
    main()
