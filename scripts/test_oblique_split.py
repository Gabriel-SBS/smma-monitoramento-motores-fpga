#!/usr/bin/env python3
"""Testa se uma arvore OBLIQUA (split em combinacao linear de features, em
vez de 1 feature por comparador -- "eixo-alinhada", o que ml_classifier.v
usa hoje) melhora a acuracia real, medido contra o MESMO dataset KAIST
real e a MESMA metodologia da recalibracao (`recalibrate_mag_l1.py`), nao
uma estimativa teorica.

sklearn nao esta disponivel neste ambiente -- LDA multiclasse (Fisher,
autovalores de Sw^-1 Sb) implementado direto em numpy, sem dependencia
extra.

Estrutura testada (mantem a MESMA prioridade de 3 comparadores de
ml_classifier.v, unica coisa que muda e se o 2o/3o comparador usa 1
feature crua ou uma combinacao linear de todas as 4):
  1) feat_lms_residual > TH_BEARING -> rolamento (ja 100% de recall,
     inalterado -- oblique nao teria o que melhorar aqui)
  2) combinacao > limiar -> desalinhamento
  3) combinacao > limiar -> desbalanceamento
  4) nenhum dos acima -> normal

Custo de hardware de uma combinacao linear de N features: N multiplicacoes
+ (N-1) somas por comparador, contra ZERO multiplicadores da arvore
eixo-alinhada atual (Decisao 6, ml_classifier.v) -- reportado junto com o
resultado de acuracia, nao escondido.

Uso:
    python3 scripts/test_oblique_split.py
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compare_ml_accuracy import CLASS_IDX, CLASSES  # noqa: E402
from compare_ml_accuracy_final import (  # noqa: E402
    FEATURE_NAMES,
    balance_classes,
    balanced_accuracy,
    calibrate_fixed_tree,
    fixed_tree_predict,
    report,
)
from recalibrate_mag_l1 import build_dataset_l1  # noqa: E402

BEARING_IDX = FEATURE_NAMES.index("lms_residual")
TH_BEARING = 0.02538  # ja calibrado, feat_lms_residual, inalterado


def fisher_lda_directions(X, y, classes):
    """LDA multiclasse (Fisher) via autovalores generalizados de
    Sw^-1 Sb -- ate len(classes)-1 direcoes discriminantes, cada uma uma
    combinacao linear das colunas de X. Implementacao direta (sem
    sklearn), padrao de livro-texto."""
    n_features = X.shape[1]
    overall_mean = X.mean(axis=0)
    Sw = np.zeros((n_features, n_features))
    Sb = np.zeros((n_features, n_features))
    for c in classes:
        Xc = X[y == c]
        if len(Xc) == 0:
            continue
        mean_c = Xc.mean(axis=0)
        diff = Xc - mean_c
        Sw += diff.T @ diff
        mean_diff = (mean_c - overall_mean).reshape(-1, 1)
        Sb += len(Xc) * (mean_diff @ mean_diff.T)
    # regularizacao pequena pra Sw nao ficar singular (features quase
    # colineares, ex. fundamental/2nd_harmonic com muitos zeros)
    Sw += np.eye(n_features) * 1e-8 * np.trace(Sw)
    eigvals, eigvecs = np.linalg.eig(np.linalg.solve(Sw, Sb))
    order = np.argsort(eigvals.real)[::-1]
    return eigvecs[:, order].real, eigvals[order].real


def calibrate_oblique_2way(X_train, y_train, w, class_pos, class_neg_set, n_candidates=40):
    """Dado um vetor de projecao w (combinacao linear), acha o melhor
    limiar (grid de percentis) pra separar class_pos de class_neg_set
    maximizando acuracia balanceada binaria -- mesma filosofia de busca em
    grade de calibrate_fixed_tree, so que sobre a projecao 1D em vez de
    uma feature crua."""
    proj = X_train @ w
    mask = np.isin(y_train, list(class_neg_set) + [class_pos])
    proj_m, y_m = proj[mask], y_train[mask]
    best = (-1.0, None)
    for t in np.percentile(proj_m, np.linspace(5, 95, n_candidates)):
        pred_pos = proj_m > t
        true_pos = y_m == class_pos
        rec_pos = (pred_pos & true_pos).sum() / max(1, true_pos.sum())
        rec_neg = (~pred_pos & ~true_pos).sum() / max(1, (~true_pos).sum())
        bacc = 0.5 * (rec_pos + rec_neg)
        if bacc > best[0]:
            best = (bacc, t)
    return best[1], best[0]


def calibrate_2feature_oblique(X_rest, y_rest, feat_a, feat_b, n_ratios=41, n_candidates=30):
    """Busca DIRETA (nao LDA) por uma combinacao linear de 2 features
    (proj = X[feat_a] + ratio*X[feat_b]) que maximiza acuracia balanceada
    das 3 classes restantes (normal/desbalanceamento/desalinhamento, apos
    separar rolamento) -- MESMO criterio de otimizacao que
    calibrate_fixed_tree ja usa pra features cruas (nao um proxy tipo
    Fisher/LDA), generalizado pra uma combinacao linear de 2 features com 2
    limiares na mesma prioridade (desalinhamento > desbalanceamento) de
    ml_classifier.v."""
    scale = np.std(X_rest[:, feat_a]) / max(1e-9, np.std(X_rest[:, feat_b]))
    best = (-1.0, None, None, None)
    for ratio in np.linspace(-3, 3, n_ratios) * scale:
        proj = X_rest[:, feat_a] + ratio * X_rest[:, feat_b]
        for t_mis in np.percentile(proj, np.linspace(30, 99, n_candidates)):
            for t_unb in np.percentile(proj, np.linspace(30, 99, n_candidates)):
                pred = np.full(len(proj), CLASS_IDX["normal"])
                pred[proj > t_unb] = CLASS_IDX["desbalanceamento"]
                pred[proj > t_mis] = CLASS_IDX["desalinhamento"]
                bacc = balanced_accuracy(y_rest, pred, len(CLASSES))
                if bacc > best[0]:
                    best = (bacc, ratio, t_mis, t_unb)
    return best


def main():
    print("Carregando janelas de TREINO (0Nm+4Nm) e TESTE (2Nm) -- mesma pipeline "
          "de recalibrate_mag_l1.py...\n")
    X_train, y_train = build_dataset_l1({"0Nm", "4Nm"})
    X_train_bal, y_train_bal = balance_classes(X_train, y_train)
    X_test, y_test = build_dataset_l1({"2Nm"})
    print(f"\nTreino balanceado: {len(y_train_bal)} janelas | Teste: {len(y_test)} janelas\n")

    print("=" * 70)
    print("BASELINE -- arvore eixo-alinhada atual (ml_classifier.v, ja em producao)")
    (feat_idx, thresholds), train_bacc = calibrate_fixed_tree(X_train_bal, y_train_bal)
    pred_baseline = fixed_tree_predict(X_test, feat_idx, thresholds)
    acc_base, cm_base = report("Eixo-alinhada (baseline)", y_test, pred_baseline)
    bacc_base = balanced_accuracy(y_test, pred_baseline, len(CLASSES))
    print(f">>> Acuracia balanceada (teste) = {bacc_base*100:.1f}%")

    print("\n" + "=" * 70)
    print("OBLIQUA -- LDA multiclasse (Fisher) nas 3 classes restantes apos "
          "separar rolamento (feat_lms_residual > TH_BEARING, inalterado)")

    # separa rolamento primeiro, exatamente como o comparador 1 real ja faz
    is_bearing_train = X_train_bal[:, BEARING_IDX] > TH_BEARING
    is_bearing_test = X_test[:, BEARING_IDX] > TH_BEARING

    rest_classes = [CLASS_IDX[c] for c in CLASSES if c != "desgaste_rolamento"]
    X_rest_train = X_train_bal[~is_bearing_train]
    y_rest_train = y_train_bal[~is_bearing_train]

    directions, eigvals = fisher_lda_directions(X_rest_train, y_rest_train, rest_classes)
    print(f"Autovalores LDA (poder discriminante por direcao): {eigvals[:3]}")
    w1 = directions[:, 0]  # 1a direcao discriminante -- combinacao linear das 4 features
    print(f"Direcao discriminante 1 (pesos por feature, {FEATURE_NAMES}): "
          + ", ".join(f"{w:+.4f}" for w in w1))

    # calibra 2 limiares na MESMA projecao 1D, priorizando desalinhamento
    # antes de desbalanceamento (mesma ordem de prioridade de
    # ml_classifier.v) -- separa cada classe do "resto" nessa projecao
    t_misalign, bacc_mis = calibrate_oblique_2way(
        X_rest_train, y_rest_train, w1, CLASS_IDX["desalinhamento"],
        {CLASS_IDX["normal"], CLASS_IDX["desbalanceamento"]})
    t_unbalance, bacc_unb = calibrate_oblique_2way(
        X_rest_train, y_rest_train, w1, CLASS_IDX["desbalanceamento"],
        {CLASS_IDX["normal"], CLASS_IDX["desalinhamento"]})
    print(f"Limiar desalinhamento (na projecao): {t_misalign:.5f} (bacc treino 2-vias={bacc_mis*100:.1f}%)")
    print(f"Limiar desbalanceamento (na projecao): {t_unbalance:.5f} (bacc treino 2-vias={bacc_unb*100:.1f}%)")

    def oblique_predict(X):
        pred = np.full(len(X), CLASS_IDX["normal"])
        proj = X @ w1
        pred[proj > t_unbalance] = CLASS_IDX["desbalanceamento"]
        pred[proj > t_misalign] = CLASS_IDX["desalinhamento"]
        is_bearing = X[:, BEARING_IDX] > TH_BEARING
        pred[is_bearing] = CLASS_IDX["desgaste_rolamento"]
        return pred

    pred_oblique = oblique_predict(X_test)
    acc_obl, cm_obl = report("Obliqua (LDA, 4 features combinadas)", y_test, pred_oblique)
    bacc_obl = balanced_accuracy(y_test, pred_oblique, len(CLASSES))
    print(f">>> Acuracia balanceada (teste) = {bacc_obl*100:.1f}%")

    print("\n" + "=" * 70)
    print("OBLIQUA v2 -- busca DIRETA (nao LDA) por combinacao de 2 features "
          "(bearing_energy + w*outra), otimizando acuracia balanceada direto "
          "(mesmo criterio da arvore eixo-alinhada, nao um proxy)")
    BEAR = FEATURE_NAMES.index("bearing_energy")
    best_pair = (-1.0, None, None, None, None)
    for other_name in ["fundamental", "2nd_harmonic", "lms_residual"]:
        other_idx = FEATURE_NAMES.index(other_name)
        bacc, ratio, t_mis, t_unb = calibrate_2feature_oblique(X_rest_train, y_rest_train, BEAR, other_idx)
        print(f"  bearing_energy + {ratio:+.5f}*{other_name}: bacc treino 3-vias={bacc*100:.1f}%")
        if bacc > best_pair[0]:
            best_pair = (bacc, other_idx, ratio, t_mis, t_unb)

    _, other_idx, ratio, t_mis, t_unb = best_pair
    other_name = FEATURE_NAMES[other_idx]
    print(f"\nMelhor par: bearing_energy + {ratio:+.5f}*{other_name} "
          f"(limiares: desalinhamento>{t_mis:.5f}, desbalanceamento>{t_unb:.5f})")

    def oblique2_predict(X):
        pred = np.full(len(X), CLASS_IDX["normal"])
        proj = X[:, BEAR] + ratio * X[:, other_idx]
        pred[proj > t_unb] = CLASS_IDX["desbalanceamento"]
        pred[proj > t_mis] = CLASS_IDX["desalinhamento"]
        is_bearing = X[:, BEARING_IDX] > TH_BEARING
        pred[is_bearing] = CLASS_IDX["desgaste_rolamento"]
        return pred

    pred_obl2 = oblique2_predict(X_test)
    acc_obl2, cm_obl2 = report(f"Obliqua v2 (bearing_energy + {other_name})", y_test, pred_obl2)
    bacc_obl2 = balanced_accuracy(y_test, pred_obl2, len(CLASSES))
    print(f">>> Acuracia balanceada (teste) = {bacc_obl2*100:.1f}%")

    print("\n" + "=" * 70)
    print("RESUMO FINAL")
    print(f"  Eixo-alinhada (producao):        acuracia={acc_base*100:.1f}%  balanceada={bacc_base*100:.1f}%")
    print(f"  Obliqua v1 (LDA, 4 features):    acuracia={acc_obl*100:.1f}%  balanceada={bacc_obl*100:.1f}%")
    print(f"  Obliqua v2 (busca direta, 2 feat): acuracia={acc_obl2*100:.1f}%  balanceada={bacc_obl2*100:.1f}%")
    print(f"  Delta v2 vs producao: {100*(acc_obl2-acc_base):+.1f}pp (bruta), "
          f"{100*(bacc_obl2-bacc_base):+.1f}pp (balanceada)")
    print("\n  Custo de hardware da via obliqua v2 (se implementada): 1 multiplicacao "
          "+ 1 soma por comparador (2 comparadores => 2 multiplicacoes, 2 somas) "
          "contra ZERO multiplicadores da arvore atual (Decisao 6).")


if __name__ == "__main__":
    main()
