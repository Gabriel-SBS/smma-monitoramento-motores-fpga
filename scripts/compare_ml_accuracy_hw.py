#!/usr/bin/env python3
"""Segunda rodada da comparação Árvore vs. MLP (ver
scripts/compare_ml_accuracy.py para a primeira, mais genérica) -- desta vez
com metodologia deliberadamente mais fiel ao que o projeto realmente
implementa em hardware, para servir de insumo à decisão final:

Diferenças em relação à primeira rodada:
  1. Janela de 64 amostras (nao 1024) -- o tamanho exato da FFT-64, nao uma
     resolucao espectral maior "de brinde" que o hardware nao tem.
  2. Sinal de entrada quantizado para Q1.15 com a MESMA calibracao fisica
     do conversor real (VIBRATION_FS_G=96.0, Decisao 5) antes de extrair
     qualquer feature -- o hardware nunca ve o valor fisico bruto em g,
     so a amostra normalizada de 16 bits.
  3. feat_lms_residual é calculado de verdade -- um filtro LMS de 8 taps
     rodando CONTINUAMENTE sobre o sinal (não reiniciado por janela, igual
     ao hardware real: lms_filter.v processa o stream continuo, a FFT
     e quem opera em janelas), mesmo mu=2^-MU_SHIFT do lms_filter.v
     (MU_SHIFT=8, o default de producao, nao o mu maior usado só no
     testbench pra acelerar convergência). Na primeira rodada essa feature
     não existia -- era a suspeita levantada como pendência.
  4. Duas árvores comparadas:
       (a) a MESMA estrutura fixa de ml_classifier.v (prioridade
           rolamento > desalinhamento > desbalanceamento > normal, só 3
           limiares) -- mas com os limiares CALIBRADOS de verdade via busca
           em grade no conjunto de treino (o que a tarefa 12 pede), não os
           placeholders atuais nem uma CART genérica mais flexível;
       (b) CART genérica (mesma da primeira rodada) para referência, agora
           também com feat_lms_residual disponível.
  5. MLP com a mesma topologia 4->8->4 já sintetizada para a comparação de
     LUTs (Decisão 6), agora recebendo as 4 features reais incluindo o
     resíduo do LMS.

Mesma divisão treino (0Nm+4Nm) / teste (2Nm, carga nunca vista) da primeira
rodada, para as duas rodadas serem comparáveis.

Uso:
    python3 scripts/compare_ml_accuracy_hw.py
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compare_ml_accuracy import (  # noqa: E402
    CLASS_IDX,
    CLASSES,
    DecisionTree,
    MLP,
    class_from_filename,
    confusion_matrix,
)
from convert_dataset import DATASET_DIR, VIBRATION_FS_G, load_vibration  # noqa: E402

WINDOW_SAMPLES = 64            # tamanho exato da FFT-64 (Sec. 3.2)
MAX_WINDOWS_PER_FILE = 300     # 300*64 = 19200 amostras (~750ms) por arquivo
FUND_BAND_MAX_BIN = 16         # limita busca do fundamental a bins 1..16 (garante 2*k0 <= 32)
MU_SHIFT = 8                   # default de PRODUCAO do lms_filter.v (nao o do testbench)


def quantize_q15(vib: np.ndarray) -> np.ndarray:
    """Mesma formula de to_q15_hex_lines() em convert_dataset.py, mas
    devolve a fracao [-1,1) em float64 em vez do inteiro de 16 bits --
    equivalente a int16/32768, so evita a ida-e-volta por hex."""
    normalized = vib / VIBRATION_FS_G
    scaled = np.round(normalized * 32768.0)
    clipped = np.clip(scaled, -32768, 32767)
    return clipped / 32768.0


def lms_residual_stream(x: np.ndarray, n_taps=8, mu_shift=MU_SHIFT) -> np.ndarray:
    """Filtro LMS auto-referenciado (Adaptive Line Enhancer), mesmo
    algoritmo de lms_filter.v: preve x[n] a partir das 8 amostras
    anteriores, atualiza pesos por mu=2^-mu_shift. Roda em float (nao
    replica a aritmetica Q1.15 bit-exata do RTL, mas o MESMO algoritmo/
    mu/numero de taps) continuamente sobre o sinal inteiro. Retorna o
    residuo e[n] = x[n]-y[n] amostra a amostra."""
    # listas/floats puros de Python, nao arrays numpy, dentro do laco: para
    # n_taps=8 o overhead de despacho de np.dot/np.roll por amostra domina
    # o tempo -- pure Python e bem mais rapido aqui (so vetoriza quando o
    # array interno e grande, nao quando e um estado de 8 elementos
    # reavaliado milhoes de vezes)
    n = len(x)
    x_list = x.tolist()
    taps = [0.0] * n_taps
    weights = [0.0] * n_taps
    mu = 2.0 ** (-mu_shift)
    residual = [0.0] * n
    for i in range(n):
        xi = x_list[i]
        y = 0.0
        for k in range(n_taps):
            y += weights[k] * taps[k]
        e = xi - y
        residual[i] = e
        mue = mu * e
        for k in range(n_taps):
            weights[k] += mue * taps[k]
        for k in range(n_taps - 1, 0, -1):
            taps[k] = taps[k - 1]
        taps[0] = xi
    return np.array(residual)


def extract_features_stream(vib_q15: np.ndarray, residual: np.ndarray, n_windows: int):
    """Extrai as 4 features por janela de WINDOW_SAMPLES, usando o sinal
    JA quantizado Q1.15 (vib_q15) para o espectro e o residuo LMS JA
    calculado continuamente (residual) para a 4a feature."""
    feats = []
    for w in range(n_windows):
        seg = vib_q15[w * WINDOW_SAMPLES:(w + 1) * WINDOW_SAMPLES]
        res_seg = residual[w * WINDOW_SAMPLES:(w + 1) * WINDOW_SAMPLES]

        win = seg * np.hanning(len(seg))
        spec = np.abs(np.fft.rfft(win, n=WINDOW_SAMPLES))  # 33 bins (0..32)
        spec[0] = 0.0

        band = spec[1:FUND_BAND_MAX_BIN + 1]
        k0 = int(np.argmax(band)) + 1 if band.size and band.max() > 0 else 1
        feat_fund = spec[k0]
        k2 = 2 * k0
        feat_2nd = spec[k2] if k2 < len(spec) else 0.0
        feat_bearing = float(spec.sum() - feat_fund - feat_2nd)
        feat_lms_residual = float(np.sqrt(np.mean(res_seg ** 2)))

        feats.append([feat_fund, feat_2nd, feat_bearing, feat_lms_residual])
    return np.array(feats, dtype=np.float64)


def build_dataset(loads):
    X, y = [], []
    for mat_path in sorted((DATASET_DIR / "vibration").glob("*.mat")):
        stem = mat_path.stem
        load = stem.split("_", 1)[0]
        if load not in loads:
            continue
        cls = class_from_filename(stem)
        vib = load_vibration(stem, 10_000_000)
        n_windows = min(MAX_WINDOWS_PER_FILE, len(vib) // WINDOW_SAMPLES)
        n_samples_used = n_windows * WINDOW_SAMPLES

        vib_q15 = quantize_q15(vib[:n_samples_used])
        residual = lms_residual_stream(vib_q15)  # continuo, mesma filosofia do hardware

        feats = extract_features_stream(vib_q15, residual, n_windows)
        X.append(feats)
        y.extend([CLASS_IDX[cls]] * n_windows)
        print(f"  {stem}: {n_windows} janelas de {WINDOW_SAMPLES} amostras ({cls})")
    return np.vstack(X), np.array(y)


# ---------------- Arvore de estrutura FIXA (igual ml_classifier.v), limiares calibrados ----------------

def fixed_tree_predict(X, th_bearing, th_misalign, th_unbalance):
    feat_fund, feat_2nd, feat_bearing, _ = X[:, 0], X[:, 1], X[:, 2], X[:, 3]
    bearing_fault = feat_bearing > th_bearing
    misalign_fault = feat_2nd > th_misalign
    unbalance_fault = feat_fund > th_unbalance
    pred = np.full(len(X), CLASS_IDX["normal"])
    pred[unbalance_fault] = CLASS_IDX["desbalanceamento"]
    pred[misalign_fault] = CLASS_IDX["desalinhamento"]
    pred[bearing_fault] = CLASS_IDX["desgaste_rolamento"]  # maior prioridade por ultimo, sobrescreve
    return pred


def calibrate_fixed_tree(X_train, y_train, n_candidates=12):
    """Busca em grade nos 3 limiares (mesma estrutura de prioridade fixa
    de ml_classifier.v), maximizando acuracia no TREINO -- e exatamente o
    que a tarefa 12 (calibracao) pede, feito aqui pela primeira vez com
    dados reais em vez de placeholders."""
    cand_bearing = np.percentile(X_train[:, 2], np.linspace(50, 99, n_candidates))
    cand_misalign = np.percentile(X_train[:, 1], np.linspace(50, 99, n_candidates))
    cand_unbalance = np.percentile(X_train[:, 0], np.linspace(50, 99, n_candidates))

    best = (-1, None)
    for tb in cand_bearing:
        for tm in cand_misalign:
            for tu in cand_unbalance:
                pred = fixed_tree_predict(X_train, tb, tm, tu)
                acc = np.mean(pred == y_train)
                if acc > best[0]:
                    best = (acc, (tb, tm, tu))
    return best[1], best[0]


def report(name, y_true, y_pred):
    acc = float(np.mean(y_true == y_pred))
    print(f"\n{name}: acuracia = {acc*100:.1f}% ({np.sum(y_true==y_pred)}/{len(y_true)})")
    cm = confusion_matrix(y_true, y_pred, len(CLASSES))
    header = "".join(f"{c[:10]:>12}" for c in CLASSES)
    row_label = "verdadeiro/predito"
    print(f"{row_label:>20}{header}")
    for i, c in enumerate(CLASSES):
        row = "".join(f"{cm[i,j]:>12}" for j in range(len(CLASSES)))
        print(f"{c:>20}{row}")
    return acc


def main():
    print(f"Config: janela={WINDOW_SAMPLES} amostras (FFT-64), quantizacao Q1.15 (FS={VIBRATION_FS_G}g), MU_SHIFT={MU_SHIFT} (default de producao)\n")

    print("Carregando janelas de TREINO (cargas 0Nm + 4Nm)...")
    X_train, y_train = build_dataset({"0Nm", "4Nm"})
    print(f"\nTreino: {len(y_train)} janelas")

    print("\nCarregando janelas de TESTE (carga 2Nm, nao vista no treino)...")
    X_test, y_test = build_dataset({"2Nm"})
    print(f"\nTeste: {len(y_test)} janelas")

    mu = X_train.mean(axis=0)
    sigma = X_train.std(axis=0) + 1e-9
    X_train_n = (X_train - mu) / sigma
    X_test_n = (X_test - mu) / sigma
    n_classes = len(CLASSES)

    print("\nCalibrando limiares da arvore de estrutura fixa (igual ml_classifier.v) via busca em grade no treino...")
    (th_bearing, th_misalign, th_unbalance), train_acc = calibrate_fixed_tree(X_train, y_train)
    print(f"  limiares calibrados (escala fisica das features, nao normalizada): "
          f"TH_BEARING={th_bearing:.4f} TH_MISALIGN={th_misalign:.4f} TH_UNBALANCE={th_unbalance:.4f} "
          f"(acuracia treino={train_acc*100:.1f}%)")
    pred_fixed = fixed_tree_predict(X_test, th_bearing, th_misalign, th_unbalance)
    fixed_acc = report("Arvore de estrutura FIXA (igual ml_classifier.v, limiares calibrados)", y_test, pred_fixed)

    cart = DecisionTree(max_depth=4).fit(X_train_n, y_train, n_classes)
    cart_acc = report("CART generica (profundidade 4, referencia)", y_test, cart.predict(X_test_n))

    mlp = MLP(n_in=4, n_hidden=8, n_out=n_classes, seed=0).fit(X_train_n, y_train, n_classes, epochs=400)
    mlp_acc = report("Perceptron / MLP (4->8->4, backprop)", y_test, mlp.predict(X_test_n))

    print(f"\nResumo: Arvore-fixa-calibrada={fixed_acc*100:.1f}%  CART-generica={cart_acc*100:.1f}%  MLP={mlp_acc*100:.1f}%")


if __name__ == "__main__":
    main()
