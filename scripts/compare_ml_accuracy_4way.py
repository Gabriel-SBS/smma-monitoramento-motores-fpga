#!/usr/bin/env python3
"""Compara os 4 modelos que o enunciado (Sec. 3.5, PBL - CD IV-2.pdf) lista
como opções de arquitetura de ML -- "perceptron multicamadas", "máquina de
vetores de suporte", "árvore de decisão", "rede neural totalmente
conectada" -- usando a MESMA metodologia fiel ao hardware já validada em
compare_ml_accuracy_hw.py (janela de 64 amostras = tamanho exato da FFT-64,
sinal quantizado Q1.15 com a calibração real ±96g/Decisão 5,
feat_lms_residual calculado por um filtro LMS de 8 taps rodando de verdade,
mesmo mu=2^-8 de produção do lms_filter.v).

Árvore de decisão: reusa a CART genérica de profundidade 4 já testada (a
estrutura de prioridade fixa real de ml_classifier.v já foi analisada à
parte em compare_ml_accuracy_hw.py -- aqui a CART representa a categoria
"árvore de decisão" de forma mais geral/justa, do jeito que o enunciado
pede como opção de arquitetura, não a implementação específica atual).

SVM: SVM linear multiclasse one-vs-rest, soft-margin (hinge loss + L2),
treinado por subgradiente -- não há scikit-learn instalado neste ambiente,
então é implementado do zero em numpy, mesmo padrão das outras classes.

Perceptron multicamadas: MLP de 1 camada oculta (4->8->4), mesma topologia
já sintetizada no Quartus para a comparação de LUTs (Decisão 6).

Rede neural totalmente conectada: rede mais profunda, 2 camadas ocultas
(4->16->8->4) -- arquitetura distinta do perceptron simples, para separar
as duas opções do enunciado de fato.

Uso:
    python3 scripts/compare_ml_accuracy_4way.py
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compare_ml_accuracy import CLASSES, DecisionTree, confusion_matrix  # noqa: E402
from compare_ml_accuracy_hw import build_dataset  # noqa: E402


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


# ---------------- SVM linear multiclasse (one-vs-rest, hinge loss, do zero) ----------------

class LinearSVM:
    def __init__(self, n_in, n_classes, C=1.0, seed=0):
        rng = np.random.default_rng(seed)
        self.W = rng.normal(0, 0.01, (n_in, n_classes))
        self.b = np.zeros(n_classes)
        self.C = C

    def fit(self, X, y, epochs=300, lr=0.01, batch_size=64, seed=0):
        rng = np.random.default_rng(seed)
        n = X.shape[0]
        n_classes = self.W.shape[1]
        Y = -np.ones((n, n_classes))
        Y[np.arange(n), y] = 1.0  # alvo one-vs-rest: +1 para a classe certa, -1 pro resto
        for _ in range(epochs):
            idx = rng.permutation(n)
            for start in range(0, n, batch_size):
                b_idx = idx[start:start + batch_size]
                Xb, Yb = X[b_idx], Y[b_idx]
                scores = Xb @ self.W + self.b
                margins = Yb * scores
                active = (margins < 1.0).astype(np.float64)  # subgradiente da hinge loss
                grad_W = self.W / self.C - (Xb.T @ (active * Yb)) / len(b_idx)
                grad_b = -np.mean(active * Yb, axis=0)
                self.W -= lr * grad_W
                self.b -= lr * grad_b
        return self

    def predict(self, X):
        return (X @ self.W + self.b).argmax(axis=1)


# ---------------- Rede densa generica (N camadas ocultas, do zero) ----------------

class DenseNet:
    def __init__(self, n_in, hidden_sizes, n_out, seed=0):
        rng = np.random.default_rng(seed)
        sizes = [n_in] + list(hidden_sizes) + [n_out]
        self.Ws, self.bs = [], []
        for i in range(len(sizes) - 1):
            self.Ws.append(rng.normal(0, np.sqrt(2.0 / sizes[i]), (sizes[i], sizes[i + 1])))
            self.bs.append(np.zeros(sizes[i + 1]))

    def _forward(self, X):
        self.zs = []
        self.as_ = [X]
        a = X
        for i in range(len(self.Ws) - 1):
            z = a @ self.Ws[i] + self.bs[i]
            a = np.maximum(0.0, z)
            self.zs.append(z)
            self.as_.append(a)
        z_out = a @ self.Ws[-1] + self.bs[-1]
        self.zs.append(z_out)
        z_out_s = z_out - z_out.max(axis=1, keepdims=True)
        exp = np.exp(z_out_s)
        self.probs = exp / exp.sum(axis=1, keepdims=True)
        return self.probs

    def _backward(self, y_onehot, lr):
        n = y_onehot.shape[0]
        dz = (self.probs - y_onehot) / n
        for i in reversed(range(len(self.Ws))):
            a_prev = self.as_[i]
            grad_W = a_prev.T @ dz
            grad_b = dz.sum(axis=0)
            if i > 0:
                da = dz @ self.Ws[i].T
                dz = da * (self.zs[i - 1] > 0)
            self.Ws[i] -= lr * grad_W
            self.bs[i] -= lr * grad_b

    def fit(self, X, y, n_classes, epochs=400, lr=0.05, batch_size=64, seed=0):
        rng = np.random.default_rng(seed)
        y_onehot = np.eye(n_classes)[y]
        n = X.shape[0]
        for _ in range(epochs):
            idx = rng.permutation(n)
            for start in range(0, n, batch_size):
                b = idx[start:start + batch_size]
                self._forward(X[b])
                self._backward(y_onehot[b], lr)
        return self

    def predict(self, X):
        return self._forward(X).argmax(axis=1)


def main():
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

    results = {}

    tree = DecisionTree(max_depth=4).fit(X_train_n, y_train, n_classes)
    results["Arvore de Decisao (CART, prof. 4)"] = report(
        "1. Arvore de Decisao (CART, profundidade 4)", y_test, tree.predict(X_test_n))

    svm = LinearSVM(n_in=4, n_classes=n_classes, C=1.0, seed=0).fit(X_train_n, y_train, epochs=300, lr=0.01)
    results["SVM linear (one-vs-rest)"] = report(
        "2. Maquina de Vetores de Suporte (SVM linear, one-vs-rest)", y_test, svm.predict(X_test_n))

    mlp = DenseNet(n_in=4, hidden_sizes=[8], n_out=n_classes, seed=0).fit(X_train_n, y_train, n_classes, epochs=400)
    results["Perceptron multicamadas (4->8->4)"] = report(
        "3. Perceptron Multicamadas (4->8->4, 1 camada oculta)", y_test, mlp.predict(X_test_n))

    deep = DenseNet(n_in=4, hidden_sizes=[16, 8], n_out=n_classes, seed=0).fit(X_train_n, y_train, n_classes, epochs=400)
    results["Rede totalmente conectada (4->16->8->4)"] = report(
        "4. Rede Neural Totalmente Conectada (4->16->8->4, 2 camadas ocultas)", y_test, deep.predict(X_test_n))

    print("\n=== Resumo (acuracia no teste, carga 2Nm nao vista) ===")
    for name, acc in results.items():
        print(f"  {name}: {acc*100:.1f}%")


if __name__ == "__main__":
    main()
