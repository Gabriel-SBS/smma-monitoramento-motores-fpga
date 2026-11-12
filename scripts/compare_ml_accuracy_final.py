#!/usr/bin/env python3
"""Rodada final: reestrutura a extração de features E a árvore de decisão
até "normal" ser classificado corretamente (pedido explícito do usuário),
corrigindo dois problemas reais achados ao investigar por que TODAS as
arquiteturas testadas em compare_ml_accuracy_4way.py falhavam 100% em
"normal":

PROBLEMA 1 -- resolução espectral: uma janela de 64 amostras a 25,6 kHz
cobre só 2,5 ms (resolução de 400 Hz/bin). A frequência de rotação real do
motor está perto de 50 Hz (achada via espectro médio Welch sobre a
gravação inteira) -- invisível numa janela de 400 Hz/bin. Testei picking
de pico ingênuo (por janela) e decimação simples (256->64, mesma duração
de 10 ms) e nenhum dos dois resolveu -- só quando a duração REAL da janela
aumenta (resolução mais fina, não só reamostragem) o sinal aparece limpo.
Correção: decimar o sinal bruto por 32x (filtro FIR anti-aliasing,
scipy.signal.decimate, em 2 estágios de 8x e 4x) ANTES de alimentar a
FFT-64 -- os mesmos 64 pontos agora cobrem 80 ms (resolução 12,5 Hz/bin,
o suficiente pra isolar os ~50 Hz do motor). Isso também resolve a
pendência já registrada em projeto.md sobre conciliar a taxa de amostragem
do dataset com a FFT-64 -- mas com um fator de decimação bem maior que o
"por 4" cogitado inicialmente, porque o objetivo real não é só casar
contagem de amostras, é ter resolução espectral suficiente.

PROBLEMA 2 -- desbalanceamento de classes: o dataset tem 1 gravação de
"Normal" contra 5 severidades de desbalanceamento, 3 de desalinhamento e 6
de rolamento -- qualquer modelo otimizando acurácia bruta aprende a
sacrificar a classe minoritária. Correção: treino balanceado (mesmo número
de janelas por classe-alvo, sub-amostrando as classes majoritárias).

Árvore de decisão: mantém a MESMA estrutura fixa de prioridade de
ml_classifier.v (3 comparações), recalibrada nas novas features -- para a
correção ficar dentro da família de custo de hardware já decidida
(Decisão 6), não uma CART genérica mais cara.

Uso:
    python3 scripts/compare_ml_accuracy_final.py
"""
import sys
from pathlib import Path

import numpy as np
from scipy.signal import decimate

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compare_ml_accuracy import CLASS_IDX, CLASSES, class_from_filename, confusion_matrix  # noqa: E402
from compare_ml_accuracy_hw import MU_SHIFT, lms_residual_stream, quantize_q15  # noqa: E402
from convert_dataset import DATASET_DIR, load_vibration  # noqa: E402

DECIMATION = 32                 # 25.6kHz -> 800Hz efetivo
WINDOW_SAMPLES_DEC = 64          # ainda FFT-64 (Sec. 3.2) -- so a entrada e decimada
EFFECTIVE_FS = 25600.0 / DECIMATION  # 800 Hz
BIN_HZ = EFFECTIVE_FS / WINDOW_SAMPLES_DEC  # 12.5 Hz/bin
FUND_BAND_LO_HZ, FUND_BAND_HI_HZ = 20.0, 120.0  # banda plausivel de rotacao do motor
MAX_WINDOWS_PER_FILE = 300
RAW_SAMPLES_PER_FILE = MAX_WINDOWS_PER_FILE * WINDOW_SAMPLES_DEC * DECIMATION  # ~614400 (~24s)


def build_dataset(loads):
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

        # decimacao em 2 estagios (scipy recomenda fator <=13 por estagio p/ IIR;
        # usamos FIR, mas cascatear tambem evita um filtro unico com banda de
        # transicao extrema)
        dec8 = decimate(vib_q15, 8, ftype="fir")
        dec32 = decimate(dec8, 4, ftype="fir")

        residual = lms_residual_stream(vib_q15, mu_shift=MU_SHIFT)  # continuo, taxa cheia

        n_windows = min(MAX_WINDOWS_PER_FILE, len(dec32) // WINDOW_SAMPLES_DEC)
        feats = []
        for w in range(n_windows):
            seg = dec32[w * WINDOW_SAMPLES_DEC:(w + 1) * WINDOW_SAMPLES_DEC]
            win = seg * np.hanning(WINDOW_SAMPLES_DEC)
            spec = np.abs(np.fft.rfft(win, n=WINDOW_SAMPLES_DEC))
            spec[0] = 0.0

            k_lo = max(1, int(round(FUND_BAND_LO_HZ / BIN_HZ)))
            k_hi = min(len(spec) - 1, int(round(FUND_BAND_HI_HZ / BIN_HZ)))
            band = spec[k_lo:k_hi + 1]
            k0 = (k_lo + int(np.argmax(band))) if band.size and band.max() > 0 else k_lo
            feat_fund = spec[k0]
            k2 = 2 * k0
            feat_2nd = spec[k2] if k2 < len(spec) else 0.0
            feat_bearing = float(spec.sum() - feat_fund - feat_2nd)

            raw_start = w * WINDOW_SAMPLES_DEC * DECIMATION
            raw_end = raw_start + WINDOW_SAMPLES_DEC * DECIMATION
            res_seg = residual[raw_start:raw_end]
            feat_lms_residual = float(np.sqrt(np.mean(res_seg ** 2))) if len(res_seg) else 0.0

            feats.append([feat_fund, feat_2nd, feat_bearing, feat_lms_residual])

        X.append(np.array(feats))
        y.extend([CLASS_IDX[cls]] * n_windows)
        print(f"  {stem}: {n_windows} janelas (bin={BIN_HZ:.1f}Hz, banda {FUND_BAND_LO_HZ}-{FUND_BAND_HI_HZ}Hz) ({cls})")
    return np.vstack(X), np.array(y)


def balance_classes(X, y, seed=0):
    rng = np.random.default_rng(seed)
    min_count = min(np.sum(y == i) for i in range(len(CLASSES)))
    idx = []
    for i in range(len(CLASSES)):
        idx_c = np.where(y == i)[0]
        idx.extend(rng.choice(idx_c, size=min_count, replace=False))
    idx = np.array(idx)
    return X[idx], y[idx]


# ---------------- Arvore de estrutura FIXA (igual ml_classifier.v), limiares E atribuicao de feature calibrados ----------------
#
# Achado que motivou generalizar isto: com as features corrigidas,
# feat_bearing_energy tem gradiente monotonico limpo entre as 4 classes
# (normal < desbalanceamento < desalinhamento < rolamento) -- muito mais
# forte que a suposicao original de ml_classifier.v (2a harmonica ->
# desalinhamento, fundamental -> desbalanceamento). Calibrar so os 3
# limiares com a atribuicao de feature fixa (original) resolveu "normal"
# mas colapsou "desalinhamento" a 0% de recall (o limiar de rolamento
# "rouba" os casos de desalinhamento antes do comparador de 2a harmonica
# ser avaliado). Generalizamos para buscar TAMBEM qual das 4 features
# alimenta cada um dos 3 comparadores -- estrutura de hardware idêntica
# (3 comparadores em prioridade fixa, zero multiplicadores; só precisa de
# um mux de 4:1 por comparador para selecionar a feature, custo desprezível)
# e o criterio de calibracao muda de acuracia bruta para ACURACIA
# BALANCEADA (media do recall por classe) -- acuracia bruta deixa a busca
# sacrificar uma classe inteira quando isso melhora o total, exatamente o
# que causou o colapso de "desalinhamento".

FEATURE_NAMES = ["fundamental", "2nd_harmonic", "bearing_energy", "lms_residual"]


def fixed_tree_predict(X, feat_idx, thresholds):
    f_bearing, f_misalign, f_unbalance = feat_idx
    t_bearing, t_misalign, t_unbalance = thresholds
    pred = np.full(len(X), CLASS_IDX["normal"])
    pred[X[:, f_unbalance] > t_unbalance] = CLASS_IDX["desbalanceamento"]
    pred[X[:, f_misalign] > t_misalign] = CLASS_IDX["desalinhamento"]
    pred[X[:, f_bearing] > t_bearing] = CLASS_IDX["desgaste_rolamento"]
    return pred


def balanced_accuracy(y_true, y_pred, n_classes):
    recalls = []
    for c in range(n_classes):
        mask = y_true == c
        if mask.sum() == 0:
            continue
        recalls.append(np.mean(y_pred[mask] == c))
    return float(np.mean(recalls))


def calibrate_fixed_tree(X_train, y_train, n_candidates=12):
    """Busca em grade nos 3 limiares E na atribuicao de feature por
    comparador, maximizando acuracia balanceada (media do recall por
    classe) no treino -- ainda so 3 comparacoes em hardware, so a escolha
    de QUAL feature cada uma usa deixa de ser fixa a priori."""
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


def report(name, y_true, y_pred):
    acc = float(np.mean(y_true == y_pred))
    print(f"\n{name}: acuracia = {acc*100:.1f}% ({np.sum(y_true==y_pred)}/{len(y_true)})")
    cm = confusion_matrix(y_true, y_pred, len(CLASSES))
    header = "".join(f"{c[:10]:>12}" for c in CLASSES)
    row_label = "verdadeiro/predito"
    print(f"{row_label:>20}{header}")
    for i, c in enumerate(CLASSES):
        recall = cm[i, i] / cm[i].sum() * 100 if cm[i].sum() else 0.0
        row = "".join(f"{cm[i,j]:>12}" for j in range(len(CLASSES)))
        print(f"{c:>20}{row}   (recall={recall:.1f}%)")
    return acc, cm


def main():
    print(f"Config: FFT-64 sobre sinal decimado {DECIMATION}x -> fs_efetivo={EFFECTIVE_FS:.0f}Hz, "
          f"janela=64 amostras cobrindo {1000*64/EFFECTIVE_FS:.0f}ms, resolucao={BIN_HZ:.1f}Hz/bin\n")

    print("Carregando janelas de TREINO (cargas 0Nm + 4Nm)...")
    X_train, y_train = build_dataset({"0Nm", "4Nm"})
    print(f"\nTreino (bruto, desbalanceado): {len(y_train)} janelas")
    X_train_bal, y_train_bal = balance_classes(X_train, y_train)
    print(f"Treino (balanceado): {len(y_train_bal)} janelas ({len(y_train_bal)//len(CLASSES)} por classe)")

    print("\nCarregando janelas de TESTE (carga 2Nm, nao vista no treino)...")
    X_test, y_test = build_dataset({"2Nm"})
    print(f"\nTeste: {len(y_test)} janelas")

    print("\nCalibrando limiares E atribuicao de feature da arvore de estrutura fixa "
          "(3 comparadores em prioridade fixa, igual ml_classifier.v) no treino balanceado, "
          "otimizando acuracia BALANCEADA (media do recall por classe)...")
    (feat_idx, thresholds), train_bacc = calibrate_fixed_tree(X_train_bal, y_train_bal)
    f_bearing, f_misalign, f_unbalance = feat_idx
    t_bearing, t_misalign, t_unbalance = thresholds
    print(f"  comparador 'rolamento'  usa {FEATURE_NAMES[f_bearing]:14s} > {t_bearing:.5f}")
    print(f"  comparador 'desalinham.' usa {FEATURE_NAMES[f_misalign]:14s} > {t_misalign:.5f}")
    print(f"  comparador 'desbalance.' usa {FEATURE_NAMES[f_unbalance]:14s} > {t_unbalance:.5f}")
    print(f"  acuracia balanceada no treino = {train_bacc*100:.1f}%")

    pred_test = fixed_tree_predict(X_test, feat_idx, thresholds)
    acc, cm = report("Arvore de estrutura FIXA (igual ml_classifier.v), features+treino+atribuicao corrigidos", y_test, pred_test)

    print("\n>>> Recall por classe: " +
          ", ".join(f"{c}={cm[i,i]/cm[i].sum()*100:.1f}%" for c, i in CLASS_IDX.items()) + " <<<")


if __name__ == "__main__":
    main()
