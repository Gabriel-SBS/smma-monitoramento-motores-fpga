#!/usr/bin/env python3
"""Testa o SVM com kernels diferentes (linear, polinomial, RBF) -- até agora
só o linear tinha sido testado (Decisão 6). Implementado do zero em numpy
(sem scikit-learn, mesma convenção do projeto): formulação DUAL do SVM de
margem suave, resolvida por ascensão de gradiente projetada (clipping de
alpha em [0,C] a cada passo, sem SMO completo).

Truque pra evitar a restrição de igualdade sum(alpha*y)=0 (que exigiria SMO
de verdade): usa K'(x,x') = K(x,x') + 1, que dá um termo de viés implícito
-- simplificação padrão em implementações didáticas de SVM dual, permite
ascensão de gradiente por coordenada simples (clip por caixa) em vez de
Sequential Minimal Optimization completo.

Kernel polinomial de grau d tem mapeamento explícito EXATO (K(x,x')=(x·x'+1)^d
é equivalente a treinar um SVM linear no espaço de todas as combinações
polinomiais até grau d) -- mas aqui resolvido via kernel trick na forma dual
mesmo assim, pra usar o MESMO código pra todos os kernels e poder comparar
custo computacional de treino de forma justa.

IMPORTANTE -- custo de hardware: um SVM com kernel não-linear precisa
armazenar TODOS os vetores de suporte (até 2400 no treino balanceado) e
avaliar o kernel pra cada um deles por classificação -- ordens de magnitude
mais caro que o SVM linear (que precisa só de W,b fixos, 4 MACs por classe).
RBF em particular precisa de exp() por avaliação. Isso é só uma comparação
acadêmica de acurácia -- nenhuma variante de kernel SVM é candidata real pra
Decisão 6 (a árvore continua dominante em custo de hardware).

Uso:
    python3 scripts/compare_svm_kernels.py
"""
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compare_ml_accuracy import CLASS_IDX, CLASSES, confusion_matrix  # noqa: E402
from compare_ml_accuracy_4way import LinearSVM  # noqa: E402
from compare_ml_accuracy_final import (  # noqa: E402
    balance_classes,
    balanced_accuracy,
    build_dataset,
)


class KernelSVM:
    """SVM dual de margem suave, kernel generico, one-vs-rest. Ascensao de
    gradiente projetada: alpha_i += lr*(1 - y_i*sum_j(alpha_j*y_j*K(x_i,x_j))),
    clip em [0,C] a cada passo. K'=K+1 da o viés implícito (ver cabeçalho).

    Normalizacao do kernel (achado ao rodar pela 1a vez, nao decidido a
    priori): kernels diferentes tem escalas MUITO diferentes -- linear tem
    diagonal media ~5, polinomial grau 3 chega a ~995, RBF fica em ~2 (ver
    projeto.md). Usar a MESMA taxa de aprendizado bruta pra todos faz o
    gradiente ou saturar todo alpha em C (kernel de escala pequena, lr
    relativamente grande demais -- deu 7% de acuracia, pior que chute
    aleatorio) ou nem sair do lugar (kernel de escala grande, lr relativamente
    pequeno demais). Corrigido dividindo K pela media da sua propria diagonal
    ANTES de otimizar -- normaliza a escala de todos os kernels pra ~1,
    permitindo uma unica lr bem calibrada pra todos, comparacao justa."""

    def __init__(self, kernel_fn, n_classes, C=1.0):
        self.kernel_fn = kernel_fn
        self.n_classes = n_classes
        self.C = C

    def fit(self, X, y, epochs=300, lr=0.002):
        self.X_train = X
        n = X.shape[0]
        K_raw = self.kernel_fn(X, X) + 1.0
        self.scale = np.diag(K_raw).mean()  # normaliza a escala do kernel
        K = K_raw / self.scale
        self.alpha_y = np.zeros((n, self.n_classes))
        for c in range(self.n_classes):
            yc = np.where(y == c, 1.0, -1.0)
            alpha = np.zeros(n)
            for _ in range(epochs):
                grad = 1.0 - yc * (K @ (alpha * yc))
                alpha = np.clip(alpha + lr * grad, 0.0, self.C)
            self.alpha_y[:, c] = alpha * yc
        return self

    def decision_function(self, X):
        K_test = (self.kernel_fn(X, self.X_train) + 1.0) / self.scale
        return K_test @ self.alpha_y

    def predict(self, X):
        return self.decision_function(X).argmax(axis=1)


def kernel_linear(A, B):
    return A @ B.T


def kernel_poly(degree):
    def k(A, B):
        return (A @ B.T + 1.0) ** degree
    return k


def kernel_rbf(gamma):
    def k(A, B):
        a2 = np.sum(A ** 2, axis=1)[:, None]
        b2 = np.sum(B ** 2, axis=1)[None, :]
        sq = np.maximum(a2 + b2 - 2.0 * (A @ B.T), 0.0)
        return np.exp(-gamma * sq)
    return k


def report(name, y_true, y_pred, elapsed):
    acc = float(np.mean(y_true == y_pred))
    bacc = balanced_accuracy(y_true, y_pred, len(CLASSES))
    cm = confusion_matrix(y_true, y_pred, len(CLASSES))
    print(f"\n{name}  (treino: {elapsed:.1f}s)")
    print(f"  acuracia = {acc*100:.1f}%  acuracia_balanceada = {bacc*100:.1f}%")
    print(f"  {'classe':>20}{'precisao':>12}{'recall':>12}{'F1':>12}")
    f1s = []
    for i, c in enumerate(CLASSES):
        tp = cm[i, i]
        fp = cm[:, i].sum() - tp
        fn = cm[i].sum() - tp
        precision = tp / (tp + fp) * 100 if (tp + fp) else 0.0
        recall = tp / (tp + fn) * 100 if (tp + fn) else 0.0
        f1 = 2 * precision * recall / (precision + recall) if (precision + recall) else 0.0
        f1s.append(f1)
        print(f"  {c:>20}{precision:>11.1f}%{recall:>11.1f}%{f1:>11.1f}%")
    macro_f1 = sum(f1s) / len(f1s)
    print(f"  {'macro F1':>20}{'':>12}{'':>12}{macro_f1:>11.1f}%")
    return acc, bacc, macro_f1


def main():
    print("Carregando janelas de TREINO (cargas 0Nm + 4Nm), FFT-64 sobre sinal decimado 32x...")
    X_train, y_train = build_dataset({"0Nm", "4Nm"})
    X_train_bal, y_train_bal = balance_classes(X_train, y_train)
    print(f"\nTreino balanceado: {len(y_train_bal)} janelas ({len(y_train_bal)//len(CLASSES)} por classe)")

    print("\nCarregando janelas de TESTE (carga 2Nm, nao vista no treino)...")
    X_test, y_test = build_dataset({"2Nm"})
    print(f"\nTeste: {len(y_test)} janelas")

    mu = X_train_bal.mean(axis=0)
    sigma = X_train_bal.std(axis=0) + 1e-9
    Xn_train = (X_train_bal - mu) / sigma
    Xn_test = (X_test - mu) / sigma
    n_classes = len(CLASSES)

    results = {}

    # 0. baseline ja conhecido (Decisao 6, quinta rodada) -- SVM linear via
    # gradiente PRIMAL (LinearSVM), reproduzido aqui so pra referencia direta
    t0 = time.time()
    svm_primal = LinearSVM(n_in=4, n_classes=n_classes, C=1.0, seed=0).fit(Xn_train, y_train_bal, epochs=300, lr=0.01)
    results["0. SVM linear (primal, ja testado na Decisao 6)"] = report(
        "0. SVM linear (primal, referencia -- Decisao 6)", y_test, svm_primal.predict(Xn_test), time.time() - t0)

    # 1. SVM kernel linear (dual) -- deve reproduzir aproximadamente o resultado do primal
    t0 = time.time()
    svm_lin = KernelSVM(kernel_linear, n_classes, C=1.0).fit(Xn_train, y_train_bal, epochs=300, lr=0.002)
    results["1. SVM kernel linear (dual)"] = report(
        "1. SVM kernel linear (dual)", y_test, svm_lin.predict(Xn_test), time.time() - t0)

    # 2. SVM kernel polinomial grau 2
    t0 = time.time()
    svm_p2 = KernelSVM(kernel_poly(2), n_classes, C=1.0).fit(Xn_train, y_train_bal, epochs=300, lr=0.002)
    results["2. SVM kernel polinomial grau 2"] = report(
        "2. SVM kernel polinomial grau 2", y_test, svm_p2.predict(Xn_test), time.time() - t0)

    # 3. SVM kernel polinomial grau 3
    t0 = time.time()
    svm_p3 = KernelSVM(kernel_poly(3), n_classes, C=1.0).fit(Xn_train, y_train_bal, epochs=300, lr=0.002)
    results["3. SVM kernel polinomial grau 3"] = report(
        "3. SVM kernel polinomial grau 3", y_test, svm_p3.predict(Xn_test), time.time() - t0)

    # 4. SVM kernel RBF, gamma=0.5
    t0 = time.time()
    svm_rbf1 = KernelSVM(kernel_rbf(0.5), n_classes, C=1.0).fit(Xn_train, y_train_bal, epochs=300, lr=0.002)
    results["4. SVM kernel RBF (gamma=0.5)"] = report(
        "4. SVM kernel RBF (gamma=0.5)", y_test, svm_rbf1.predict(Xn_test), time.time() - t0)

    # 5. SVM kernel RBF, gamma=2.0 (mais localizado)
    t0 = time.time()
    svm_rbf2 = KernelSVM(kernel_rbf(2.0), n_classes, C=1.0).fit(Xn_train, y_train_bal, epochs=300, lr=0.002)
    results["5. SVM kernel RBF (gamma=2.0)"] = report(
        "5. SVM kernel RBF (gamma=2.0)", y_test, svm_rbf2.predict(Xn_test), time.time() - t0)

    print("\n=== Resumo (acuracia / acuracia balanceada / macro F1, teste carga 2Nm nao vista) ===")
    for name, (acc, bacc, macro_f1) in results.items():
        print(f"  {name}: acc={acc*100:.1f}%  bacc={bacc*100:.1f}%  macroF1={macro_f1:.1f}%")


if __name__ == "__main__":
    main()
