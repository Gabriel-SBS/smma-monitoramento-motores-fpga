#!/usr/bin/env python3
"""Converte o dataset KAIST (Wonho Jung et al., Data in Brief 2023) de
.mat/.tdms (MATLAB/LabVIEW/TDMS -- formatos que o Verilog/Icarus não lê) para
arquivos .hex Q1.15 compatíveis com $readmemh, no formato decidido para a
entrada de dados do SMMA (projeto.md, Decisão 1).

Uso:
    python3 scripts/convert_dataset.py 0Nm_Normal
    python3 scripts/convert_dataset.py 0Nm_BPFI_10 --num-samples 8192
    python3 scripts/convert_dataset.py --all-representative

Estrutura de entrada esperada (dataset já presente no projeto):
    "Vibration, Acoustic, Temperature, and Motor Current Dataset of Rotating
    Machine Under Varying Load Conditions for Fault Diagnosis/"
        vibration/<classe>.mat        -- struct Signal.y_values.values,
                                          (N,4) float64, unidade 'g', 25.6 kHz
        current,temp/<classe>.tdms    -- grupo "Log", 5 canais:
                                          Mod1/ai0, Mod1/ai1  = temperatura (°C)
                                          Mod2/ai0, ai2, ai3  = corrente trifásica (A)

Saída: <output_dir>/<classe>/{vibracao,corrente_fase_a,corrente_fase_b,
corrente_fase_c,temperatura}.hex -- uma amostra Q1.15 (4 dígitos hex) por
linha, mesmo número de linhas em todos os arquivos de uma classe (amostras
sincronizadas por índice), pronto para $readmemh.

Calibração (faixa física -> Q1.15 [-1, 1)): faixas FIXAS, não normalização
por arquivo -- necessário para manter classes comparáveis entre si (um
desbalanceamento com pico maior não pode "parecer igual" a operação normal só
porque cada arquivo foi normalizado pelo próprio pico). Valores escolhidos
com folga sobre o observado nos arquivos do dataset (ver comentários abaixo);
ainda não são uma calibração de sensor real -- fica pendente junto com a
calibração dos thresholds do classificador (projeto.md, Pendências).
"""
import argparse
import struct
import sys
from pathlib import Path

import numpy as np
import scipy.io as sio
from nptdms import TdmsFile

REPO_ROOT = Path(__file__).resolve().parent.parent
DATASET_DIR = REPO_ROOT / (
    "Vibration, Acoustic, Temperature, and Motor Current Dataset of "
    "Rotating Machine Under Varying Load Conditions for Fault Diagnosis"
)

# Faixas fixas de calibração (valor físico -> Q1.15 [-1, 1)).
# Vibração: +-8g (estimativa inicial baseada só em Normal/Unbalance) estava
#   ERRADA -- validate_dataset.py achou 46-58% das amostras de BPFI/BPFO
#   saturadas. Escaneando os .mat completos: Normal ~6.2g, Unbalance ~5.2g,
#   Misalign ~13.0g, mas BPFI ~73.0g e BPFO ~71.0g (falha de rolamento produz
#   impactos impulsivos de amplitude bem maior -- fisicamente esperado, não é
#   ruído). +-96g cobre o pior caso observado (~73g) com margem de ~1,3x,
#   mesma filosofia de folga usada para CURRENT_FS_A abaixo. Custo: Normal/
#   Unbalance passam a usar só ~6% da faixa Q1.15 (~11 bits efetivos) -- o
#   enunciado (Sec. 5) tolera "pequenas perdas de precisão, desde que não
#   comprometam a classificação", e cortar os impactos de BPFI/BPFO seria
#   muito pior (destrói a própria assinatura diagnóstica dessas classes).
VIBRATION_FS_G = 96.0
VIBRATION_CHANNEL = 0  # das 4 colunas do .mat; só uma vai para o ramo de vibração

# Corrente: pico observado ~4.4A; +-8A dá folga.
CURRENT_FS_A = 8.0

# Temperatura: sensor não é bipolar. Mapeia [0, 100] degC para [-1, 1) --
# cobre a faixa observada (~25 degC em repouso) com folga generosa para
# aquecimento sob falha prolongada.
TEMP_MID_C = 50.0
TEMP_HALF_RANGE_C = 50.0

DEFAULT_NUM_SAMPLES = 4096  # ~160 ms a 25.6 kHz; 64 janelas de FFT-64 completas

REPRESENTATIVE_CLASSES = [
    "0Nm_Normal",
    "0Nm_BPFI_10",
    "0Nm_BPFO_10",
    "0Nm_Misalign_03",
    "0Nm_Unbalance_1751mg",
]


def to_q15_hex_lines(values: np.ndarray, full_scale, mid=0.0) -> list:
    """Quantiza valores físicos para Q1.15 (16 bits, two's complement) e
    retorna uma lista de strings hex de 4 dígitos, uma por amostra."""
    normalized = (values - mid) / full_scale
    scaled = np.round(normalized * 32768.0)
    clipped = np.clip(scaled, -32768, 32767).astype(np.int32)
    return [format(int(v) & 0xFFFF, "04x") for v in clipped]


def write_hex_file(path: Path, hex_lines: list, header: str):
    with open(path, "w", encoding="ascii") as f:
        f.write(f"// {header}\n")
        f.write("\n".join(hex_lines))
        f.write("\n")


def load_vibration(class_name: str, num_samples: int) -> np.ndarray:
    mat_path = DATASET_DIR / "vibration" / f"{class_name}.mat"
    d = sio.loadmat(mat_path)
    sig = d["Signal"][0, 0]
    yv = sig["y_values"][0, 0]
    values = yv["values"]  # (N, 4) float64, unidade 'g'
    return values[:num_samples, VIBRATION_CHANNEL]


def load_current_temp(class_name: str, num_samples: int):
    """Retorna (curr_a, curr_b, curr_c, temperatura). curr_b/curr_c podem vir
    como None se o canal estiver vazio na fonte -- visto acontecer em todos
    os arquivos BPFO (fases B/C não gravadas nesse conjunto, lacuna real do
    dataset, não bug do conversor). O chamador decide o que fazer."""
    tdms_path = DATASET_DIR / "current,temp" / f"{class_name}.tdms"
    tf = TdmsFile.read(tdms_path)
    grp = tf["Log"]
    temp_a = grp["cDAQ9185-1F486B5Mod1/ai0"][:num_samples]
    temp_b = grp["cDAQ9185-1F486B5Mod1/ai1"][:num_samples]
    temperature = (temp_a + temp_b) / 2.0  # média dos 2 sensores redundantes

    def read_or_none(ch_name):
        ch = grp[ch_name]
        if len(ch) == 0:
            return None
        return ch[:num_samples]

    curr_a = read_or_none("cDAQ9185-1F486B5Mod2/ai0")
    curr_b = read_or_none("cDAQ9185-1F486B5Mod2/ai2")
    curr_c = read_or_none("cDAQ9185-1F486B5Mod2/ai3")
    return curr_a, curr_b, curr_c, temperature


def convert_class(class_name: str, num_samples: int, output_dir: Path):
    print(f"Convertendo {class_name} ({num_samples} amostras)...")

    vib = load_vibration(class_name, num_samples)
    curr_a, curr_b, curr_c, temp = load_current_temp(class_name, num_samples)

    available = [a for a in (vib, curr_a, curr_b, curr_c, temp) if a is not None]
    n = min(len(a) for a in available)
    if n < num_samples:
        print(f"  aviso: apenas {n} amostras disponiveis (pedido {num_samples})")
    vib, temp = vib[:n], temp[:n]

    out = output_dir / class_name
    out.mkdir(parents=True, exist_ok=True)

    write_hex_file(
        out / "vibracao.hex",
        to_q15_hex_lines(vib, VIBRATION_FS_G),
        f"{class_name} vibracao (canal {VIBRATION_CHANNEL}, g, FS=+-{VIBRATION_FS_G}g), {n} amostras, Q1.15",
    )

    missing_phases = []
    for label, curr in (("a", curr_a), ("b", curr_b), ("c", curr_c)):
        if curr is None:
            missing_phases.append(label)
            continue
        write_hex_file(
            out / f"corrente_fase_{label}.hex",
            to_q15_hex_lines(curr[:n], CURRENT_FS_A),
            f"{class_name} corrente fase {label.upper()} (A, FS=+-{CURRENT_FS_A}A), {n} amostras, Q1.15",
        )
    if missing_phases:
        print(f"  aviso: fase(s) {', '.join(missing_phases)} vazia(s) na fonte "
              f"(.tdms) -- {class_name} nao tem corrente trifasica completa, "
              f"lacuna real do dataset, nao gerado")

    write_hex_file(
        out / "temperatura.hex",
        to_q15_hex_lines(temp, TEMP_HALF_RANGE_C, mid=TEMP_MID_C),
        f"{class_name} temperatura (media de 2 sensores, degC, faixa=[0,100]degC), {n} amostras, Q1.15",
    )
    print(f"  ok -> {out}/")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("class_name", nargs="?", help="ex.: 0Nm_Normal, 0Nm_BPFI_10")
    ap.add_argument("--num-samples", type=int, default=DEFAULT_NUM_SAMPLES)
    ap.add_argument("--output-dir", type=Path, default=REPO_ROOT / "dataset_convertido")
    ap.add_argument("--all-representative", action="store_true",
                     help="converte as 5 classes representativas (0Nm: Normal, BPFI, BPFO, Misalign, Unbalance)")
    args = ap.parse_args()

    if not args.all_representative and not args.class_name:
        ap.error("informe class_name ou use --all-representative")

    classes = REPRESENTATIVE_CLASSES if args.all_representative else [args.class_name]
    for c in classes:
        convert_class(c, args.num_samples, args.output_dir)


if __name__ == "__main__":
    main()
