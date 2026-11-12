#!/usr/bin/env python3
"""Extrai um subconjunto de sinais de smma_top_waveform.vcd (dump real do
xrun sobre tb_smma_top_waveform.v, CLKS_PER_SAMPLE=1953 real) e gera 2
figuras: (1) visao macro da FSM mestre (top_state/class_onehot/busy/
result_valid) ao longo dos 160ms simulados inteiros; (2) zoom em clk real
durante a computacao da 1a janela, pra mostrar forma de onda de verdade
(nao so o log textual $display), atendendo a tarefa 14 (simulacao completa
com waveform, esperado vs obtido).

Parser proprio de VCD (streaming, 1 passada) porque o arquivo tem ~410MB
(a maior parte sao toggles de clk a cada 10ns por 160ms = ~16M linhas) --
nao caberia inteiro em memoria nem vale a pena depender de uma lib externa
so pra isso.
"""
import sys

VCD_PATH = "quartus/smma_fft64/smma_top_waveform.vcd"

# codigos de identificador VCD (achados via grep no cabecalho do dump real)
CODE_CLK = ","
CODE_BUSY = "0"
CODE_RESULT_VALID = "5"
CODE_CLASS_ONEHOT = "7"
CODE_TOP_STATE = "p!"

# janela de zoom (ns): em torno do inicio da computacao da janela 1
# (top_state 1->2 em t=79995170000ps segundo o log textual, ~5us de contexto)
ZOOM_START_NS = 79_994_500
ZOOM_END_NS = 80_028_000

# zoom fino (ns): poucos ciclos de clk reais (50MHz, 20ns/periodo) em torno
# do pulso de result_valid da janela 1 -- pra mostrar o clock quadrado de
# verdade (o zoom acima, em dezenas de us, tem toggles densos demais pra
# distinguir bordas individuais)
FINE_ZOOM_START_NS = 80_026_900
FINE_ZOOM_END_NS = 80_027_300

STATE_NAMES = {
    0: "IDLE", 1: "STREAM", 2: "WAIT_FFT_VIB", 3: "PEAK_START", 4: "PEAK_WAIT",
    5: "MDC_START", 6: "MDC_WAIT", 7: "MAG_START", 8: "MAG_WAIT",
    9: "RELEASE_VIB", 10: "HARM_DECIDE", 11: "HARM_CHECK", 12: "LOAD_CURR_FFT",
    13: "CURR_FFT_START", 14: "WAIT_FFT_CURR", 15: "HARM_FFT_VALID",
    16: "HARM_READ", 17: "CLASSIFY_START", 18: "CLASSIFY_WAIT",
    19: "ESTIMATE_START", 20: "ESTIMATE_WAIT", 21: "OUTPUT",
}


def parse(vcd_path):
    macro = {"busy": [], "result_valid": [], "class_onehot": [], "top_state": []}
    clk_zoom = []
    clk_fine = []
    rv_fine = []
    t_ps = 0
    timescale_div = 1000.0  # arquivo esta em 1ps, queremos ns

    with open(vcd_path, "r", errors="ignore") as f:
        in_defs = True
        for line in f:
            if in_defs:
                if line.startswith("$enddefinitions"):
                    in_defs = False
                continue
            if not line:
                continue
            c0 = line[0]
            if c0 == "#":
                t_ps = int(line[1:].strip())
                continue
            if c0 in "01":
                code = line[1:].strip()
                val = int(c0)
                t_ns = t_ps / timescale_div
                if code == CODE_BUSY:
                    macro["busy"].append((t_ns, val))
                elif code == CODE_RESULT_VALID:
                    macro["result_valid"].append((t_ns, val))
                    if FINE_ZOOM_START_NS <= t_ns <= FINE_ZOOM_END_NS:
                        rv_fine.append((t_ns, val))
                elif code == CODE_CLK:
                    if ZOOM_START_NS <= t_ns <= ZOOM_END_NS:
                        clk_zoom.append((t_ns, val))
                    if FINE_ZOOM_START_NS <= t_ns <= FINE_ZOOM_END_NS:
                        clk_fine.append((t_ns, val))
                continue
            if c0 == "b":
                parts = line[1:].strip().split()
                if len(parts) != 2:
                    continue
                bits, code = parts
                val = int(bits, 2) if all(ch in "01" for ch in bits) else -1
                t_ns = t_ps / timescale_div
                if code == CODE_CLASS_ONEHOT:
                    macro["class_onehot"].append((t_ns, val))
                elif code == CODE_TOP_STATE:
                    macro["top_state"].append((t_ns, val))
                continue
    return macro, clk_zoom, clk_fine, rv_fine


def main():
    macro, clk_zoom, clk_fine, rv_fine = parse(VCD_PATH)
    for k, v in macro.items():
        print(f"{k}: {len(v)} eventos")
    print(f"clk (zoom {ZOOM_START_NS}-{ZOOM_END_NS}ns): {len(clk_zoom)} eventos")
    print(f"clk (fine zoom {FINE_ZOOM_START_NS}-{FINE_ZOOM_END_NS}ns): {len(clk_fine)} eventos")

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, axes = plt.subplots(4, 1, figsize=(12, 8), sharex=True,
                              gridspec_kw={"height_ratios": [2, 1, 1, 1]})
    fig.suptitle("smma_top.v — simulação completa, CLKS_PER_SAMPLE=1953 (real)\n"
                 "0Nm_Normal → esperado class_onehot=0001 (normal)")

    def step_plot(ax, events, end_ns, label, yticks=None, yticklabels=None):
        if not events:
            return
        xs = [e[0] / 1e6 for e in events]  # ns -> ms
        ys = [e[1] for e in events]
        xs.append(end_ns / 1e6)
        ys.append(ys[-1])
        ax.step(xs, ys, where="post")
        ax.set_ylabel(label, rotation=0, ha="right", va="center")
        if yticks is not None:
            ax.set_yticks(yticks)
            ax.set_yticklabels(yticklabels)
        ax.grid(alpha=0.3)

    end_ns = macro["top_state"][-1][0] + 100 if macro["top_state"] else 1
    step_plot(axes[0], macro["top_state"], end_ns, "top_state")
    step_plot(axes[1], macro["busy"], end_ns, "busy", [0, 1], ["0", "1"])
    step_plot(axes[2], macro["result_valid"], end_ns, "result_valid", [0, 1], ["0", "1"])
    step_plot(axes[3], macro["class_onehot"], end_ns, "class_onehot")
    axes[3].set_xlabel("tempo (ms)")

    for t, val in macro["class_onehot"]:
        if val == 1:
            axes[3].axvline(t / 1e6, color="green", linestyle="--", alpha=0.6)

    plt.tight_layout()
    plt.savefig("scripts/out_smma_waveform_macro.png", dpi=130)
    print("Salvo: scripts/out_smma_waveform_macro.png")

    # zoom: clk real + top_state na janela em torno da 1a classificacao
    fig2, ax2 = plt.subplots(2, 1, figsize=(12, 5), sharex=True)
    fig2.suptitle("Zoom — clk real (50MHz) durante o fim da janela 1 (PEAK→OUTPUT)")
    if clk_zoom:
        xs = [e[0] / 1000.0 for e in clk_zoom]  # ns -> us
        ys = [e[1] for e in clk_zoom]
        xs.append(ZOOM_END_NS / 1000.0)
        ys.append(ys[-1])
        ax2[0].step(xs, ys, where="post", linewidth=0.8)
    ax2[0].set_ylabel("clk")
    ax2[0].set_yticks([0, 1])

    ts_zoom = [(t, v) for t, v in macro["top_state"] if ZOOM_START_NS <= t <= ZOOM_END_NS]
    if ts_zoom:
        xs = [t / 1000.0 for t, _ in ts_zoom]
        ys = [v for _, v in ts_zoom]
        xs.append(ZOOM_END_NS / 1000.0)
        ys.append(ys[-1])
        ax2[1].step(xs, ys, where="post")
        for t, v in ts_zoom:
            ax2[1].annotate(STATE_NAMES.get(v, str(v)), (t / 1000.0, v),
                             fontsize=6, rotation=45, ha="left", va="bottom")
    ax2[1].set_ylabel("top_state")
    ax2[1].set_xlabel("tempo (us)")

    plt.tight_layout()
    plt.savefig("scripts/out_smma_waveform_zoom.png", dpi=130)
    print("Salvo: scripts/out_smma_waveform_zoom.png")

    # zoom fino: clk quadrado de verdade (poucos ciclos, 20ns/periodo) +
    # pulso real de result_valid no fim da janela 1
    fig3, ax3 = plt.subplots(2, 1, figsize=(12, 4), sharex=True)
    fig3.suptitle("Zoom fino — clk real @50MHz (poucos ciclos) + pulso de result_valid, fim da janela 1")
    if clk_fine:
        xs = [e[0] for e in clk_fine]
        ys = [e[1] for e in clk_fine]
        xs.append(FINE_ZOOM_END_NS)
        ys.append(ys[-1])
        ax3[0].step(xs, ys, where="post")
    ax3[0].set_ylabel("clk")
    ax3[0].set_yticks([0, 1])
    if rv_fine:
        xs = [e[0] for e in rv_fine]
        ys = [e[1] for e in rv_fine]
        xs.append(FINE_ZOOM_END_NS)
        ys.append(ys[-1])
        ax3[1].step(xs, ys, where="post", color="green")
    ax3[1].set_ylabel("result_valid")
    ax3[1].set_yticks([0, 1])
    ax3[1].set_xlabel("tempo (ns)")

    plt.tight_layout()
    plt.savefig("scripts/out_smma_waveform_fine.png", dpi=130)
    print("Salvo: scripts/out_smma_waveform_fine.png")


if __name__ == "__main__":
    main()
