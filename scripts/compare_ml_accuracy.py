#!/usr/bin/env python3
"""Compara acurácia real de Árvore de Decisão vs. Perceptron (MLP) treinados
com o dataset KAIST completo (não só as 5 classes representativas já
convertidas para .hex) -- pergunta diferente da comparação de LUTs
(projeto.md, Decisão 6): aqui não importa custo de hardware, só qual
algoritmo classifica melhor.

Metodologia (documentada para não inflar acurácia por acidente):
  - Usa as 45 gravações de vibração do dataset (3 cargas x 15
    classes/severidades), não só as 5 já convertidas -- mais dados,
    resultado mais confiável.
  - Cada gravação é cortada em janelas de WINDOW_SAMPLES amostras (janela
    Hann), até MAX_WINDOWS_PER_FILE por arquivo -- evita que classes com
    gravação mais longa (ex. Normal) dominem o dataset.
  - Divisão treino/teste é POR ARQUIVO/CARGA, não por janela: treina com as
    cargas 0 Nm e 4 Nm, testa só com 2 Nm (nunca visto no treino) -- se
    dividisse por janela dentro do mesmo arquivo, janelas vizinhas são
    quase idênticas e a acurácia ficaria artificialmente inflada
    (vazamento de dados).
  - Classes mapeadas para as 4 categorias que o classificador já usa:
    Normal -> normal; Unbalance_* -> desbalanceamento; Misalign_* ->
    desalinhamento; BPFI_*/BPFO_* -> desgaste de rolamento.
  - Features são PROXIES em Python das que o hardware pretende calcular
    (fundamental via pico espectral, 2a harmônica, energia espectral
    agregada, RMS) -- não é o datapath RTL bit-exato (isso exigiria rodar
    milhares de janelas pela FFT-64/MDC/LMS em simulação, fora de escopo
    aqui). Isso mede o poder do ALGORITMO de classificação dado um
    conjunto de features plausível, não a implementação de hardware.
  - Árvore (CART, Gini, profundidade limitada) e MLP (4->8->4, ReLU,
    softmax, backprop) implementados do zero em numpy -- sem scikit-learn
    instalado neste ambiente -- e TREINADOS de verdade nos dados (ao
    contrário dos limiares hand-tuned de ml_classifier.v, que a tarefa 12
    já documenta como placeholders não calibrados).

Uso:
    python3 scripts/compare_ml_accuracy.py
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from convert_dataset import DATASET_DIR, load_vibration  # noqa: E402

WINDOW_SAMPLES = 1024          # ~40 ms a 25.6 kHz
MAX_WINDOWS_PER_FILE = 150     # limite pra balancear classes com gravação mais longa
FUND_BAND_MAX_BIN = 40         # busca do "fundamental" nos bins 1..40 (~25 Hz a 1 kHz)

CLASSES = ["normal", "desbalanceamento", "desalinhamento", "desgaste_rolamento"]
CLASS_IDX = {c: i for i, c in enumerate(CLASSES)}


def class_from_filename(name: str) -> str:
    if "Normal" in name:
        return "normal"
    if "Unbal" in name:  # cobre o typo "Unbalalnce" presente nos arquivos de 2Nm
        return "desbalanceamento"
    if "Misalign" in name:
        return "desalinhamento"
    if "BPFI" in name or "BPFO" in name:
        return "desgaste_rolamento"
    raise ValueError(f"classe desconhecida: {name}")


def extract_features(window: np.ndarray) -> np.ndarray:
    """4 features proxy: fundamental, 2a harmonica, energia espectral
    agregada (proxy de energia de rolamento), RMS no tempo."""
    win = window * np.hanning(len(window))
    spec = np.abs(np.fft.rfft(win))
    spec[0] = 0.0  # remove DC

    band = spec[1:FUND_BAND_MAX_BIN + 1]
    k0 = int(np.argmax(band)) + 1 if band.size and band.max() > 0 else 1
    feat_fund = spec[k0]
    k2 = 2 * k0
    feat_2nd = spec[k2] if k2 < len(spec) else 0.0
    feat_bearing = float(spec.sum() - feat_fund - feat_2nd)
    feat_rms = float(np.sqrt(np.mean(window.astype(np.float64) ** 2)))

    return np.array([feat_fund, feat_2nd, feat_bearing, feat_rms], dtype=np.float64)


def build_dataset(loads):
    X, y, groups = [], [], []
    for mat_path in sorted((DATASET_DIR / "vibration").glob("*.mat")):
        stem = mat_path.stem
        load = stem.split("_", 1)[0]  # "0Nm", "2Nm", "4Nm"
        if load not in loads:
            continue
        cls = class_from_filename(stem)
        vib = load_vibration(stem, 10_000_000)  # arquivo inteiro
        n_windows = min(MAX_WINDOWS_PER_FILE, len(vib) // WINDOW_SAMPLES)
        for w in range(n_windows):
            seg = vib[w * WINDOW_SAMPLES:(w + 1) * WINDOW_SAMPLES]
            X.append(extract_features(seg))
            y.append(CLASS_IDX[cls])
            groups.append(stem)
        print(f"  {stem}: {n_windows} janelas ({cls})")
    return np.array(X), np.array(y), groups


# ---------------- Árvore de Decisão (CART, do zero) ----------------

class TreeNode:
    __slots__ = ("is_leaf", "klass", "feature", "threshold", "left", "right")


def _gini(y, n_classes):
    if len(y) == 0:
        return 0.0
    counts = np.bincount(y, minlength=n_classes)
    p = counts / counts.sum()
    return 1.0 - np.sum(p ** 2)


def _best_split(X, y, n_classes, n_thresholds=32):
    n, d = X.shape
    base = _gini(y, n_classes)
    best = None
    for feat in range(d):
        col = X[:, feat]
        qs = np.unique(np.percentile(col, np.linspace(5, 95, n_thresholds)))
        for t in qs:
            left = col <= t
            n_left = left.sum()
            n_right = n - n_left
            if n_left == 0 or n_right == 0:
                continue
            gl = _gini(y[left], n_classes)
            gr = _gini(y[~left], n_classes)
            weighted = (n_left * gl + n_right * gr) / n
            gain = base - weighted
            if best is None or gain > best[0]:
                best = (gain, feat, t)
    return best


def _build_tree(X, y, n_classes, depth, max_depth, min_samples=10):
    node = TreeNode()
    if depth == max_depth or len(np.unique(y)) == 1 or len(y) < min_samples:
        node.is_leaf = True
        node.klass = int(np.bincount(y, minlength=n_classes).argmax())
        return node
    split = _best_split(X, y, n_classes)
    if split is None or split[0] <= 1e-9:
        node.is_leaf = True
        node.klass = int(np.bincount(y, minlength=n_classes).argmax())
        return node
    _, feat, t = split
    node.is_leaf = False
    node.feature = feat
    node.threshold = t
    mask = X[:, feat] <= t
    node.left = _build_tree(X[mask], y[mask], n_classes, depth + 1, max_depth, min_samples)
    node.right = _build_tree(X[~mask], y[~mask], n_classes, depth + 1, max_depth, min_samples)
    return node


def _predict_one(node, x):
    while not node.is_leaf:
        node = node.left if x[node.feature] <= node.threshold else node.right
    return node.klass


class DecisionTree:
    def __init__(self, max_depth=4):
        self.max_depth = max_depth

    def fit(self, X, y, n_classes):
        self.n_classes = n_classes
        self.root = _build_tree(X, y, n_classes, 0, self.max_depth)
        return self

    def predict(self, X):
        return np.array([_predict_one(self.root, x) for x in X])


# ---------------- MLP (4 -> 8 -> 4, do zero, backprop) ----------------

class MLP:
    def __init__(self, n_in, n_hidden, n_out, seed=0):
        rng = np.random.default_rng(seed)
        self.W1 = rng.normal(0, np.sqrt(2.0 / n_in), (n_in, n_hidden))
        self.b1 = np.zeros(n_hidden)
        self.W2 = rng.normal(0, np.sqrt(2.0 / n_hidden), (n_hidden, n_out))
        self.b2 = np.zeros(n_out)

    def _forward(self, X):
        self.z1 = X @ self.W1 + self.b1
        self.a1 = np.maximum(0.0, self.z1)
        z2 = self.a1 @ self.W2 + self.b2
        z2s = z2 - z2.max(axis=1, keepdims=True)
        exp = np.exp(z2s)
        self.probs = exp / exp.sum(axis=1, keepdims=True)
        return self.probs

    def _backward(self, X, y_onehot, lr):
        n = X.shape[0]
        dz2 = (self.probs - y_onehot) / n
        dW2 = self.a1.T @ dz2
        db2 = dz2.sum(axis=0)
        da1 = dz2 @ self.W2.T
        dz1 = da1 * (self.z1 > 0)
        dW1 = X.T @ dz1
        db1 = dz1.sum(axis=0)
        self.W1 -= lr * dW1
        self.b1 -= lr * db1
        self.W2 -= lr * dW2
        self.b2 -= lr * db2

    def fit(self, X, y, n_classes, epochs=400, lr=0.05, batch_size=64, seed=0):
        rng = np.random.default_rng(seed)
        y_onehot = np.eye(n_classes)[y]
        n = X.shape[0]
        for _ in range(epochs):
            idx = rng.permutation(n)
            for start in range(0, n, batch_size):
                b = idx[start:start + batch_size]
                self._forward(X[b])
                self._backward(X[b], y_onehot[b], lr)
        return self

    def predict(self, X):
        return self._forward(X).argmax(axis=1)


def confusion_matrix(y_true, y_pred, n_classes):
    cm = np.zeros((n_classes, n_classes), dtype=int)
    for t, p in zip(y_true, y_pred):
        cm[t, p] += 1
    return cm


def report(name, y_true, y_pred):
    acc = float(np.mean(y_true == y_pred))
    print(f"\n{name}: acurácia = {acc*100:.1f}% ({np.sum(y_true==y_pred)}/{len(y_true)})")
    cm = confusion_matrix(y_true, y_pred, len(CLASSES))
    header = "".join(f"{c[:10]:>12}" for c in CLASSES)
    row_label = "verdadeiro/predito"
    print(f"{row_label:>20}{header}")
    for i, c in enumerate(CLASSES):
        row = "".join(f"{cm[i,j]:>12}" for j in range(len(CLASSES)))
        print(f"{c:>20}{row}")
    return acc


def main():
    print("Carregando janelas de TREINO (cargas 0Nm + 4Nm)...")
    X_train, y_train, _ = build_dataset({"0Nm", "4Nm"})
    print(f"\nTreino: {len(y_train)} janelas")

    print("\nCarregando janelas de TESTE (carga 2Nm, nao vista no treino)...")
    X_test, y_test, _ = build_dataset({"2Nm"})
    print(f"\nTeste: {len(y_test)} janelas")

    # padroniza (z-score) com estatisticas SO do treino
    mu = X_train.mean(axis=0)
    sigma = X_train.std(axis=0) + 1e-9
    X_train_n = (X_train - mu) / sigma
    X_test_n = (X_test - mu) / sigma

    n_classes = len(CLASSES)

    tree = DecisionTree(max_depth=4).fit(X_train_n, y_train, n_classes)
    tree_acc = report("Arvore de Decisao (CART, profundidade 4)", y_test, tree.predict(X_test_n))

    mlp = MLP(n_in=4, n_hidden=8, n_out=n_classes, seed=0).fit(X_train_n, y_train, n_classes)
    mlp_acc = report("Perceptron / MLP (4->8->4, backprop)", y_test, mlp.predict(X_test_n))

    print(f"\nResumo: Arvore={tree_acc*100:.1f}%  MLP={mlp_acc*100:.1f}%")


if __name__ == "__main__":
    main()
