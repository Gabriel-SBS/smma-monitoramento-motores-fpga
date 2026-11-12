#!/usr/bin/env python3
"""Valida os arquivos .hex gerados por convert_dataset.py contra a fonte
original (.mat/.tdms) -- não confia na conversão só porque ela "rodou sem
erro". Para cada canal de cada classe já convertida:

  1. Recarrega a amostra original (mesmo código de leitura de
     convert_dataset.py -- load_vibration/load_current_temp -- reaproveitado
     porque parsear .mat/.tdms não é o ponto sob teste aqui).
  2. Decodifica o .hex de volta para valor físico (complemento de 2 -> Q1.15
     -> unidade física), fazendo o caminho INVERSO da quantização, não o
     mesmo código de ida -- se to_q15_hex_lines() tiver um bug de sinal ou
     escala, comparar contra o valor original pega isso; comparar contra o
     próprio código de quantização não pegaria.
  3. Compara amostra a amostra contra o valor original, com tolerância de
     1 LSB (meio passo de quantização) -- é o mesmo método usado para validar
     a primeira amostra manualmente durante a tarefa de conversão, generalizado
     para todas as amostras de todos os canais de todas as classes.

Reporta por canal: erro máximo, % de amostras saturadas (podem ser
legítimas, mas em excesso indicam faixa física (FS) mal calibrada -- ver
pendência em projeto.md), e formato do arquivo (contagem de linhas, dígitos
hex válidos).

Uso:
    python3 scripts/validate_dataset.py
    python3 scripts/validate_dataset.py --dataset-dir dataset_convertido
"""
import argparse
import re
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from convert_dataset import (  # noqa: E402
    CURRENT_FS_A,
    TEMP_HALF_RANGE_C,
    TEMP_MID_C,
    VIBRATION_FS_G,
    load_current_temp,
    load_vibration,
)

REPO_ROOT = Path(__file__).resolve().parent.parent

CHANNELS = {
    "vibracao.hex":         ("vib", VIBRATION_FS_G, 0.0),
    "corrente_fase_a.hex":  ("curr_a", CURRENT_FS_A, 0.0),
    "corrente_fase_b.hex":  ("curr_b", CURRENT_FS_A, 0.0),
    "corrente_fase_c.hex":  ("curr_c", CURRENT_FS_A, 0.0),
    "temperatura.hex":      ("temp", TEMP_HALF_RANGE_C, TEMP_MID_C),
}

HEX_LINE_RE = re.compile(r"^[0-9a-f]{4}$")


def parse_hex_file(path: Path):
    """Retorna (raw_int16_array, format_errors)."""
    lines = path.read_text(encoding="ascii").splitlines()
    data_lines = [ln for ln in lines if not ln.startswith("//") and ln.strip()]
    errors = []
    raw = np.zeros(len(data_lines), dtype=np.int32)
    for i, ln in enumerate(data_lines):
        if not HEX_LINE_RE.match(ln):
            errors.append(f"linha {i}: '{ln}' não é hex de 4 dígitos minúsculos")
            continue
        v = int(ln, 16)
        raw[i] = v - 0x10000 if v & 0x8000 else v  # complemento de 2 -> assinado
    return raw, errors


def validate_channel(class_dir: Path, filename: str, source_key: str, sources: dict,
                      full_scale: float, mid: float) -> bool:
    path = class_dir / filename
    if not path.exists():
        return True  # ausência legítima (ex.: fases B/C do BPFO) -- não é falha

    raw, fmt_errors = parse_hex_file(path)
    if fmt_errors:
        print(f"  FAIL {filename}: {len(fmt_errors)} erro(s) de formato (ex.: {fmt_errors[0]})")
        return False

    source = sources.get(source_key)
    if source is None:
        print(f"  FAIL {filename}: arquivo existe mas fonte original ({source_key}) veio vazia -- inconsistente")
        return False

    n = min(len(raw), len(source))
    if len(raw) != len(source):
        print(f"  aviso {filename}: {len(raw)} amostras no .hex vs {len(source)} na fonte, comparando as {n} em comum")

    decoded_physical = (raw[:n].astype(np.float64) / 32768.0) * full_scale + mid
    source_physical = source[:n].astype(np.float64)

    lsb = full_scale / 32768.0
    abs_err = np.abs(decoded_physical - source_physical)
    tol = lsb * 0.5 + 1e-9  # meio passo de quantização (arredondamento), + folga de ponto flutuante
    n_bad = int(np.sum(abs_err > tol))
    max_err = float(np.max(abs_err))

    n_clipped = int(np.sum((raw[:n] == 32767) | (raw[:n] == -32768)))
    pct_clipped = 100.0 * n_clipped / n if n else 0.0

    ok = n_bad == 0
    status = "PASS" if ok else "FAIL"
    print(f"  {status} {filename}: {n} amostras, erro_max={max_err:.6f} (tol={tol:.6f}), "
          f"{n_bad} fora da tolerância, {n_clipped} saturadas ({pct_clipped:.1f}%), "
          f"faixa_fonte=[{source_physical.min():.3f}, {source_physical.max():.3f}]")
    if pct_clipped > 1.0:
        print(f"       aviso: >1% das amostras saturadas -- FS={full_scale} pode estar apertado para esta classe")
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dataset-dir", type=Path, default=REPO_ROOT / "dataset_convertido")
    args = ap.parse_args()

    if not args.dataset_dir.exists():
        print(f"'{args.dataset_dir}' não existe -- rode convert_dataset.py --all-representative antes.")
        sys.exit(1)

    class_dirs = sorted(p for p in args.dataset_dir.iterdir() if p.is_dir())
    if not class_dirs:
        print(f"nenhuma classe convertida encontrada em '{args.dataset_dir}'.")
        sys.exit(1)

    all_ok = True
    for class_dir in class_dirs:
        class_name = class_dir.name
        print(f"\n{class_name}:")

        # descobre quantas amostras validar a partir do maior arquivo presente
        n_request = 0
        for filename in CHANNELS:
            p = class_dir / filename
            if p.exists():
                raw, _ = parse_hex_file(p)
                n_request = max(n_request, len(raw))

        vib = load_vibration(class_name, n_request)
        curr_a, curr_b, curr_c, temp = load_current_temp(class_name, n_request)
        sources = {"vib": vib, "curr_a": curr_a, "curr_b": curr_b, "curr_c": curr_c, "temp": temp}

        for filename, (source_key, full_scale, mid) in CHANNELS.items():
            ok = validate_channel(class_dir, filename, source_key, sources, full_scale, mid)
            all_ok = all_ok and ok

    print()
    print("ALL PASS" if all_ok else "FALHAS ENCONTRADAS")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
