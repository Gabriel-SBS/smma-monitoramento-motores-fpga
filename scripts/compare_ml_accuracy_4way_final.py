#!/usr/bin/env python3
"""Repete o teste das 4 arquiteturas do §3.5 (compare_ml_accuracy_4way.py)
com a metodologia CORRIGIDA da quarta rodada (compare_ml_accuracy_final.py):
FFT-64 alimentada por sinal decimado 32x (resolução 12,5 Hz/bin, resolve a
frequência de rotação do motor ~50 Hz) e treino balanceado por classe.

Árvore de decisão: usa a estrutura fixa de `ml_classifier.v` (3
comparadores em prioridade fixa) com a atribuição de feature POR
comparador também calibrada (achado da quarta rodada -- não fixa a
suposição original do módulo), otimizando acurácia balanceada.

SVM, Perceptron e Rede Totalmente Conectada: mesmas classes de
compare_ml_accuracy_4way.py (implementadas do zero em numpy), agora
treinadas no conjunto balanceado com as features corrigidas.

Uso:
    python3 scripts/compare_ml_accuracy_4way_final.py
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compare_ml_accuracy import CLASS_IDX, CLASSES, confusion_matrix  # noqa: E402
from compare_ml_accuracy_4way import DenseNet, LinearSVM  # noqa: E402
from compare_ml_accuracy_final import (  # noqa: E402
    FEATURE_NAMES,
    balance_classes,
    balanced_accuracy,
    build_dataset,
    calibrate_fixed_tree,
    fixed_tree_predict,
)


def report(name, y_true, y_pred):
    acc = float(np.mean(y_true == y_pred))
    bacc = balanced_accuracy(y_true, y_pred, len(CLASSES))
    print(f"\n{name}: acuracia = {acc*100:.1f}%  acuracia_balanceada = {bacc*100:.1f}% "
          f"({np.sum(y_true==y_pred)}/{len(y_true)})")
    cm = confusion_matrix(y_true, y_pred, len(CLASSES))
    header = "".join(f"{c[:10]:>12}" for c in CLASSES)
    row_label = "verdadeiro/predito"
    print(f"{row_label:>20}{header}")
    for i, c in enumerate(CLASSES):
        recall = cm[i, i] / cm[i].sum() * 100 if cm[i].sum() else 0.0
        row = "".join(f"{cm[i,j]:>12}" for j in range(len(CLASSES)))
        print(f"{c:>20}{row}   (recall={recall:.1f}%)")
    return acc, bacc


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

    # 1. Arvore de decisao -- estrutura fixa de ml_classifier.v, feature POR
    # comparador tambem calibrada (achado da 4a rodada)
    (feat_idx, thresholds), _ = calibrate_fixed_tree(X_train_bal, y_train_bal)
    f_b, f_m, f_u = feat_idx
    print(f"\nArvore -- comparadores: rolamento={FEATURE_NAMES[f_b]}  "
          f"desalinhamento={FEATURE_NAMES[f_m]}  desbalanceamento={FEATURE_NAMES[f_u]}")
    pred = fixed_tree_predict(X_test, feat_idx, thresholds)
    results["1. Arvore de Decisao (ml_classifier.v, reestruturada)"] = report(
        "1. Arvore de Decisao (estrutura fixa de ml_classifier.v, reestruturada)", y_test, pred)

    # 2. SVM linear multiclasse (one-vs-rest)
    svm = LinearSVM(n_in=4, n_classes=n_classes, C=1.0, seed=0).fit(Xn_train, y_train_bal, epochs=300, lr=0.01)
    results["2. SVM linear (one-vs-rest)"] = report(
        "2. Maquina de Vetores de Suporte (SVM linear, one-vs-rest)", y_test, svm.predict(Xn_test))

    # 3. Perceptron multicamadas (1 camada oculta)
    mlp = DenseNet(n_in=4, hidden_sizes=[8], n_out=n_classes, seed=0).fit(Xn_train, y_train_bal, n_classes, epochs=400)
    results["3. Perceptron Multicamadas (4->8->4)"] = report(
        "3. Perceptron Multicamadas (4->8->4, 1 camada oculta)", y_test, mlp.predict(Xn_test))

    # 4. Rede neural totalmente conectada (2 camadas ocultas)
    deep = DenseNet(n_in=4, hidden_sizes=[16, 8], n_out=n_classes, seed=0).fit(Xn_train, y_train_bal, n_classes, epochs=400)
    results["4. Rede Totalmente Conectada (4->16->8->4)"] = report(
        "4. Rede Neural Totalmente Conectada (4->16->8->4, 2 camadas ocultas)", y_test, deep.predict(Xn_test))

    print("\n=== Resumo (acuracia / acuracia balanceada, teste carga 2Nm nao vista) ===")
    for name, (acc, bacc) in results.items():
        print(f"  {name}: acc={acc*100:.1f}%  bacc={bacc*100:.1f}%")


if __name__ == "__main__":
    main()
