#!/usr/bin/env python3
"""
plot_figures.py - redraws Figs. 11-21 of "Performant almost-latch-free data structures using
epoch protection in more depth" from the CSVs written by run_all.ps1.

    pip install matplotlib numpy
    python plot_figures.py                  # all figures that have data
    python plot_figures.py --fig 11 13      # only some
    python plot_figures.py --results results --out figures

Input : results/<folder>/<series>.r<k>.csv   (columns: threads, ops_per_sec). Repetitions are averaged.
Output: figures/fig11.png (+ .pdf) ... ; throughput is shown in M Op/s like in the paper.
"""
import argparse, csv, glob, os, re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# seaborn "colorblind" palette
BLUE, ORANGE, GREEN, RED, PINK, BROWN, LPINK, GRAY, YELLOW = (
    "#0173b2", "#de8f05", "#029e73", "#d55e00", "#cc78bc", "#ca9161", "#fbafe4", "#949494", "#ece133")

# A panel = (subtitle, folder, [(legend label, series file stem, colour), ...])
LIST_SERIES = {
    "latch-free-mock": ("latch-free-mock", RED),
    "latched": ("latched", PINK),
    "simple-version": ("EPVS", BLUE),
    "simple-version-pinned": ("EPVS-pinned", ORANGE),
    "bravo": ("BRAVO", GREEN),
    "two-phase-version": ("2-phase-EPVS", BROWN),
}
def lst(folder, names, rename=None):
    out = []
    for n in names:
        label, col = LIST_SERIES[n]
        if rename and n in rename: label = rename[n]
        out.append((label, n, col))
    return out

P_COLORS = [("latch-free", "latch-free", BLUE), ("p=0", "p=0", ORANGE), ("p=1e-5", "p=1e-5", GREEN),
            ("p=1e-4", "p=1e-4", RED), ("p=1e-3", "p=1e-3", PINK), ("p=1e-2", "p=1e-2", BROWN),
            ("p=1e-1", "p=1e-1", LPINK), ("p=1", "p=1", GRAY), ("latched", "latched", YELLOW)]
E_COLORS = [(f"e={e}", f"e={e}", c) for e, c in zip((64, 128, 256, 512, 1024), (BLUE, ORANGE, GREEN, RED, PINK))]

FIGS = {
 11: dict(xlabel="#threads", ncol=3, panels=[("(a) p=0%", "fig11",
        lst("fig11", ["latch-free-mock", "latched", "simple-version", "simple-version-pinned", "bravo"]))]),
 12: dict(xlabel="#threads", ncol=3, panels=[
        ("(a) p=10%",  "fig12_p10",  lst("", ["latch-free-mock", "latched", "simple-version", "two-phase-version", "simple-version-pinned", "bravo"], {"simple-version": "simple-EPVS"})),
        ("(b) p=50%",  "fig12_p50",  lst("", ["latch-free-mock", "latched", "simple-version", "two-phase-version", "simple-version-pinned", "bravo"], {"simple-version": "simple-EPVS"})),
        ("(c) p=100%", "fig12_p100", lst("", ["latch-free-mock", "latched", "simple-version", "two-phase-version", "simple-version-pinned", "bravo"], {"simple-version": "simple-EPVS"}))]),
 13: dict(xlabel="#threads", ncol=3, panels=[("(a) p=100%", "fig13",
        lst("", ["simple-version", "two-phase-version", "bravo"], {"simple-version": "simple-EPVS"}))]),
 14: dict(xlabel="#threads", ncol=3, panels=[("(a) p=0%", "fig14",
        lst("", ["simple-version", "simple-version-pinned", "bravo"]))]),
 15: dict(xlabel="#threads", ncol=3, panels=[("", "fig15", [("no validation", "no-validation", BLUE),
        ("reader-writer-latch", "reader-writer-latch", ORANGE), ("EPVS", "epvs", GREEN)])]),
 16: dict(xlabel="#threads", ncol=2, ylim=(0, None), panels=[
        (t, f, [("Original FASTER", "original", BLUE), ("EPVS", "epvs", ORANGE)]) for t, f in [
        ("(a) 500ms checkpoints, fine-grained epoch", "fig16_a_500ms_fine"),
        ("(b) 500ms checkpoints, coarse-grained epoch", "fig16_b_500ms_coarse"),
        ("(c) 25ms checkpoints, fine-grained epoch", "fig16_c_25ms_fine"),
        ("(d) 25ms checkpoints, coarse-grained epoch", "fig16_d_25ms_coarse")]]),
 17: dict(xlabel="#threads", ncol=5, panels=[("(a) EPVS", "fig17_epvs", P_COLORS),
        ("(b) BRAVO", "fig17_bravo", [x for x in P_COLORS if x[0] != "latch-free" and x[0] != "latched"]
                                    + []), ]),
 18: dict(xlabel="#threads", ncol=5, panels=[("(a) enter-leave", "fig18_enter_leave", E_COLORS),
        ("(b) refresh", "fig18_refresh", E_COLORS), ("(c) BRAVO", "fig18_bravo", E_COLORS)]),
 19: dict(xlabel="#threads", ncol=4, panels=[("", "fig19", [(f"n={n}", f"n={n}", c) for n, c in
        zip((1, 10, 100, 1000), (BLUE, ORANGE, GREEN, RED))])]),
 20: dict(xlabel="#threads", ncol=4, panels=[("", "fig20", [("BRAVO-1", "BRAVO-1", BLUE), ("BRAVO-4", "BRAVO-4", ORANGE),
        ("EPVS-1", "EPVS-1", GREEN), ("EPVS-4", "EPVS-4", RED)])]),
 21: dict(xlabel="#threads", ncol=3, panels=[
        ("(a) sharing", "fig21_share", [("EPVS", "EPVS", BLUE), ("Latch", "Latch", ORANGE), ("BRAVO", "BRAVO", GREEN)]),
        ("(b) no-sharing", "fig21_noshare", [("EPVS", "EPVS", BLUE), ("Latch", "Latch", ORANGE), ("BRAVO", "BRAVO", GREEN)])]),
}
# Fig. 17(b) shares the latch-free / latched baselines with 17(a)
SHARED_BASELINES = {"fig17_bravo": "fig17_epvs"}


def load(results, folder, stem):
    """mean throughput (M Op/s) per thread count, averaged over repetitions"""
    files = glob.glob(os.path.join(results, folder, stem + ".r*.csv"))
    if not files and folder in SHARED_BASELINES:
        files = glob.glob(os.path.join(results, SHARED_BASELINES[folder], stem + ".r*.csv"))
    acc = {}
    for f in files:
        with open(f, newline="") as fh:
            for row in csv.DictReader(fh):
                try:
                    acc.setdefault(int(row["threads"]), []).append(float(row["ops_per_sec"]) / 1e6)
                except (KeyError, ValueError):
                    pass
    xs = sorted(acc)
    return xs, [sum(acc[x]) / len(acc[x]) for x in xs]


def draw(num, spec, results, outdir):
    panels = spec["panels"]
    # Fig. 17(b) also shows latch-free & latched
    if num == 17:
        panels = [panels[0], ("(b) BRAVO", "fig17_bravo", P_COLORS)]
    height = 3.0 * len(panels) + 0.8
    fig, axes = plt.subplots(len(panels), 1, figsize=(5.6, height), squeeze=False)
    handles, labels, any_data, maxx = {}, [], False, 1
    for ax, (title, folder, series) in zip(axes[:, 0], panels):
        for label, stem, color in series:
            xs, ys = load(results, folder, stem)
            if not xs:
                continue
            any_data = True; maxx = max(maxx, max(xs))
            (h,) = ax.plot(xs, ys, linestyle="--", linewidth=2, color=color, label=label)
            handles.setdefault(label, h)
        ax.set_ylabel("Throughput(M Op/s)")
        ax.set_xlabel(spec["xlabel"])
        ax.grid(axis="y", alpha=.3)
        if "ylim" in spec: ax.set_ylim(spec["ylim"])
        if title:
            ax.set_title(title, y=-0.38, fontsize=11)
    if not any_data:
        plt.close(fig); print(f"Fig. {num}: no data found in {results} - skipped"); return
    step = 8 if maxx > 24 else 4
    for ax in axes[:, 0]:
        ax.set_xticks(list(range(step, maxx + 1, step)))
        ax.set_xlim(left=0.5)
    fig.legend(handles.values(), handles.keys(), loc="upper center", ncol=spec["ncol"], fontsize=8.5,
               frameon=True, fancybox=False, edgecolor="black")
    fig.tight_layout(rect=(0, 0, 1, 1 - 0.55 / height * (1.0 if len(panels) == 1 else 0.7)))
    os.makedirs(outdir, exist_ok=True)
    for ext in ("png", "pdf"):
        fig.savefig(os.path.join(outdir, f"fig{num}.{ext}"), dpi=200)
    plt.close(fig)
    print(f"Fig. {num}: wrote {outdir}/fig{num}.png/.pdf")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default="results")
    ap.add_argument("--out", default="figures")
    ap.add_argument("--fig", type=int, nargs="*", default=sorted(FIGS))
    a = ap.parse_args()
    for n in a.fig:
        draw(n, FIGS[n], a.results, a.out)
