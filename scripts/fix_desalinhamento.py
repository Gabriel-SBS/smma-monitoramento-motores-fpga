#!/usr/bin/env python3
"""Testa as 2 direções levantadas pra melhorar o recall de "desalinhamento"
(50,8% na árvore reestruturada, o mais fraco das 4 classes -- ver
projeto.md, pendência aberta):

  (A) 4o comparador: soma um comparador extra sobre feat_2nd_harmonic
      (calculada mas não usada pela árvore atual), OR'd na condição de
      desalinhamento -- mesma estrutura de prioridade fixa (rolamento >
      desalinhamento > desbalanceamento > normal), só mais barato: 1
      comparador + 1 porta OR a mais.

  (B) feature nova: razão harmônica feat_2nd_harmonic / feat_fundamental
      (proxy direto da relação 1x/2x que a literatura de vibração associa
      a desalinhamento), adicionada ao pool de 4 candidatas e recalibrada
      com a MESMA busca de 3 comparadores já usada (calibrate_fixed_tree),
      agora escolhendo entre 5 features em vez de 4.

Mesma metodologia da quarta/quinta rodada: decimação 32x, treino
balanceado (0Nm+4Nm), teste em 2Nm nunca visto, otimizando acurácia
balanceada.

Uso:
    python3 scripts/fix_desalinhamento.py
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
    calibrate_fixed_tree,
    fixed_tree_predict,
)


def report(name, y_true, y_pred):
    acc = float(np.mean(y_true == y_pred))
    bacc = balanced_accuracy(y_true, y_pred, len(CLASSES))
    cm = confusion_matrix(y_true, y_pred, len(CLASSES))
    print(f"\n{name}")
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
    desalign_recall = cm[CLASS_IDX['desalinhamento'], CLASS_IDX['desalinhamento']] / cm[CLASS_IDX['desalinhamento']].sum() * 100
    return acc, bacc, macro_f1, desalign_recall


# ---------------- Opcao A: 4o comparador (OR com feat_2nd_harmonic) ----------------

def fixed_tree_predict_4cmp(X, feat_idx, thresholds, extra_feat_idx):
    f_bearing, f_misalign, f_unbalance = feat_idx
    t_bearing, t_misalign, t_unbalance, t_extra = thresholds
    pred = np.full(len(X), CLASS_IDX["normal"])
    pred[X[:, f_unbalance] > t_unbalance] = CLASS_IDX["desbalanceamento"]
    misalign_fault = (X[:, f_misalign] > t_misalign) | (X[:, extra_feat_idx] > t_extra)
    pred[misalign_fault] = CLASS_IDX["desalinhamento"]
    pred[X[:, f_bearing] > t_bearing] = CLASS_IDX["desgaste_rolamento"]
    return pred


def calibrate_extra_threshold(X_train, y_train, feat_idx, base_thresholds, extra_feat_idx, n_candidates=20):
    """Parte da atribuicao/limiares JA calibrados (baseline de 3
    comparadores) e busca so o limiar do 4o comparador extra -- extensao
    incremental, nao redescoberta do zero."""
    cand = np.percentile(X_train[:, extra_feat_idx], np.linspace(10, 99.5, n_candidates))
    best = (-1.0, None)
    for te in cand:
        pred = fixed_tree_predict_4cmp(X_train, feat_idx, (*base_thresholds, te), extra_feat_idx)
        bacc = balanced_accuracy(y_train, pred, len(CLASSES))
        if bacc > best[0]:
            best = (bacc, te)
    return best[1], best[0]


# ---------------- Opcao B: feature nova (razao harmonica) no pool de 3 comparadores ----------------

def calibrate_fixed_tree_generic(X_train, y_train, n_features, n_candidates=12):
    """Mesma busca de calibrate_fixed_tree, generalizada pra um numero
    qualquer de features candidatas (a original fixa em 4)."""
    n_classes = len(CLASSES)
    best = (-1.0, None)
    feature_indices = range(n_features)
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


def main():
    print("Carregando janelas de TREINO (cargas 0Nm + 4Nm), FFT-64 sobre sinal decimado 32x...")
    X_train, y_train = build_dataset({"0Nm", "4Nm"})
    X_train_bal, y_train_bal = balance_classes(X_train, y_train)
    print(f"Treino balanceado: {len(y_train_bal)} janelas ({len(y_train_bal)//len(CLASSES)} por classe)")

    print("\nCarregando janelas de TESTE (carga 2Nm, nao vista no treino)...")
    X_test, y_test = build_dataset({"2Nm"})
    print(f"Teste: {len(y_test)} janelas")

    # --- baseline: arvore atual de ml_classifier.v (3 comparadores, 4 features) ---
    (feat_idx, thresholds), _ = calibrate_fixed_tree(X_train_bal, y_train_bal)
    f_b, f_m, f_u = feat_idx
    print(f"\n[baseline] comparadores: rolamento={FEATURE_NAMES[f_b]}  "
          f"desalinhamento={FEATURE_NAMES[f_m]}  desbalanceamento={FEATURE_NAMES[f_u]}")
    pred_base = fixed_tree_predict(X_test, feat_idx, thresholds)
    report("[baseline] Arvore atual (3 comparadores, ml_classifier.v reestruturada)", y_test, pred_base)

    # --- opcao A: 4o comparador com feat_2nd_harmonic (indice 1), OR na condicao de desalinhamento ---
    IDX_2ND_HARMONIC = 1
    t_extra, train_bacc_a = calibrate_extra_threshold(
        X_train_bal, y_train_bal, feat_idx, thresholds, IDX_2ND_HARMONIC)
    print(f"\n[opcao A] 4o comparador: desalinhamento tambem dispara se "
          f"2nd_harmonic > {t_extra:.5f} (acuracia balanceada no treino = {train_bacc_a*100:.1f}%)")
    pred_a = fixed_tree_predict_4cmp(X_test, feat_idx, (*thresholds, t_extra), IDX_2ND_HARMONIC)
    report("[opcao A] Arvore + 4o comparador (feat_2nd_harmonic OR desalinhamento)", y_test, pred_a)

    # --- opcao B: feature nova (razao 2nd_harmonic/fundamental) no pool de 3 comparadores ---
    eps = 1e-9
    ratio_train = X_train_bal[:, 1] / (X_train_bal[:, 0] + eps)
    ratio_test = X_test[:, 1] / (X_test[:, 0] + eps)
    X_train_5 = np.hstack([X_train_bal, ratio_train[:, None]])
    X_test_5 = np.hstack([X_test, ratio_test[:, None]])
    FEATURE_NAMES_5 = FEATURE_NAMES + ["harmonic_ratio(2nd/fund)"]

    (feat_idx5, thresholds5), train_bacc_b = calibrate_fixed_tree_generic(X_train_5, y_train_bal, n_features=5)
    f_b5, f_m5, f_u5 = feat_idx5
    print(f"\n[opcao B] comparadores: rolamento={FEATURE_NAMES_5[f_b5]}  "
          f"desalinhamento={FEATURE_NAMES_5[f_m5]}  desbalanceamento={FEATURE_NAMES_5[f_u5]} "
          f"(acuracia balanceada no treino = {train_bacc_b*100:.1f}%)")
    pred_b = fixed_tree_predict(X_test_5, feat_idx5, thresholds5)
    report("[opcao B] Arvore recalibrada com feature nova (razao harmonica) no pool", y_test, pred_b)

    print("\n=== Resumo (teste carga 2Nm, nao vista no treino) ===")
    for name, pred in [("baseline", pred_base), ("A: 4o comparador (2nd_harmonic)", pred_a),
                        ("B: razao harmonica no pool", pred_b)]:
        acc = np.mean(y_test == pred) * 100
        bacc = balanced_accuracy(y_test, pred, len(CLASSES)) * 100
        cm = confusion_matrix(y_test, pred, len(CLASSES))
        i = CLASS_IDX["desalinhamento"]
        recall_des = cm[i, i] / cm[i].sum() * 100
        print(f"  {name}: acc={acc:.1f}%  bacc={bacc:.1f}%  recall_desalinhamento={recall_des:.1f}%")


if __name__ == "__main__":
    main()
