#!/usr/bin/env python3
# =============================================================================
# FIDO V3 (WITCHER) - ML policy training and Verilog export
#
# Pure Python 3 (no numpy / sklearn), so it runs on the lab machine as-is.
#
#   python3 train_ml.py --untrained -o ml_models.v
#       placeholder models (never request power gating, confidence 0)
#
#   python3 train_ml.py --fine <trace dir> --coarse <trace dir> -o ml_models.v
#       trains from ml_trace_Tnn.csv files written by the testbench with
#       +MLTRACE (cfg cgpg_ml_fine / cgpg_ml_coarse), writes the Verilog
#       models and model_report.txt next to the output file.
#
# Models (one per power domain, chosen by what the domain has to decide)
#   compute domains  (PD_ALU_HI, PD_MUL, PD_DIV / PD_EX)  -> decision tree,
#       depth <= 4, binary "power off now?"; confidence = leaf purity
#   storage / core   (PD_BANK0..3, PD_RF_HI / PD_STORAGE, PD_CORE) ->
#       3-class logistic regression {CG only, PG with retention, PG off};
#       confidence = score margin of the winning class (fixed point)
#
# Label (oracle): at every cycle where the domain is idle, the remaining idle
#   length R is read from the future of the trace. "long" = R >= BE_LBL.
#   compute: gate = long.   storage: PG_RET if long and live, PG_OFF if long
#   and not live, else CG.  (In the shared code every storage domain is live,
#   so PG_OFF is never seen; it becomes reachable with CARAXES' liveness
#   detection.)
# Cost-sensitive: a wrong gate costs a wake-up stall, so idle-short samples
#   are weighted W_NEG times more than idle-long samples.
# Split: tests T02..T08 train, T09..T16 are held out (reported separately).
# =============================================================================
import argparse
import glob
import math
import os
import re
import sys

BE_LBL = 24          # break-even idle length (cycles), same as tb_env.v
W_NEG = 2.0          # weight of "idle too short" samples (wrong gate is costly)
MAX_DEPTH = 4
MIN_LEAF = 20        # minimum training samples per leaf (raw count)
CONF_PURITY = 0.75   # tree: leaf purity needed for confidence = 1
Q = 256              # LR fixed-point scale (8 fractional bits)
LR_MARGIN = math.log(3.0)   # LR: winning score must beat the next by ln 3
TRAIN_TESTS = set(range(2, 9))

FEATS = ["idle", "h1", "h2", "occ", "wfi", "evq"]          # model inputs
FMAX = {"idle": 63, "h1": 7, "h2": 7, "occ": 4, "wfi": 1, "evq": 8}
FWID = {"idle": 6, "h1": 3, "h2": 3, "occ": 3, "wfi": 1, "evq": 4}
FLSB = {"idle": 0, "h1": 6, "h2": 9, "occ": 12, "wfi": 15, "evq": 16}

DOMS = {
    "fine": [("PD_ALU_HI", "tree"), ("PD_MUL", "tree"), ("PD_DIV", "tree"),
             ("PD_BANK0", "lr"), ("PD_BANK1", "lr"), ("PD_BANK2", "lr"),
             ("PD_BANK3", "lr"), ("PD_RF_HI", "lr")],
    "coarse": [("PD_EX", "tree"), ("PD_STORAGE", "lr"), ("PD_CORE", "lr")],
}
CLS_CG, CLS_RET, CLS_OFF = 1, 2, 3


# ----------------------------------------------------------------- traces
def read_traces(tdir, nslots):
    """returns {test: {slot: [row dict per cycle]}}"""
    out = {}
    files = sorted(glob.glob(os.path.join(tdir, "**", "ml_trace_T*.csv"), recursive=True))
    if not files:
        sys.exit("no ml_trace_T*.csv under %s" % tdir)
    for f in files:
        t = int(re.search(r"ml_trace_T(\d+)\.csv", f).group(1))
        per = {s: [] for s in range(nslots)}
        with open(f) as fh:
            hdr = fh.readline().strip().split(",")
            for line in fh:
                v = line.strip().split(",")
                if len(v) != len(hdr):
                    continue
                r = dict(zip(hdr, (int(x) for x in v)))
                if r["slot"] < nslots:
                    per[r["slot"]].append(r)
        out[t] = per
    return out


def samples(rows, live_dom):
    """decision samples: (feature tuple, remaining idle R, live) at idle cycles"""
    n = len(rows)
    rem = [0] * n
    run = 0
    for i in range(n - 1, -1, -1):
        run = 0 if rows[i]["busy"] else run + 1
        rem[i] = run
    res = []
    for i, r in enumerate(rows):
        if not r["busy"]:
            res.append((tuple(r[k] for k in FEATS), rem[i], r["live"] if live_dom is None else live_dom))
    return res


def tree_label(R):
    return 1 if R >= BE_LBL else 0


def lr_label(R, live):
    if R < BE_LBL:
        return CLS_CG
    return CLS_RET if live else CLS_OFF


def compress(data):
    """merge identical feature vectors: {x: {label: count}}"""
    d = {}
    for x, y in data:
        d.setdefault(x, {})
        d[x][y] = d[x].get(y, 0) + 1
    return d


# ----------------------------------------------------------------- decision tree
def tree_fit(cdata, depth=0):
    """cdata: {x: {0/1: count}}. returns node dict."""
    pos = sum(c.get(1, 0) for c in cdata.values())
    neg = sum(c.get(0, 0) for c in cdata.values())
    wp, wn = pos * 1.0, neg * W_NEG
    leaf = {"leaf": True, "pos": pos, "neg": neg, "gate": wp > wn}
    if depth >= MAX_DEPTH or pos == 0 or neg == 0 or (pos + neg) < 2 * MIN_LEAF:
        return leaf

    def gini(a, b):
        t = a + b
        return 0.0 if t == 0 else 1.0 - (a / t) ** 2 - (b / t) ** 2

    tot_w = wp + wn
    base = gini(wp, wn)
    best = None
    for fi, fname in enumerate(FEATS):
        hist = {}
        for x, c in cdata.items():
            h = hist.setdefault(x[fi], [0, 0])
            h[0] += c.get(1, 0)
            h[1] += c.get(0, 0)
        vals = sorted(hist)
        lp = ln = 0
        for v in vals[:-1]:
            lp += hist[v][0]
            ln += hist[v][1]
            rp, rn = pos - lp, neg - ln
            if (lp + ln) < MIN_LEAF or (rp + rn) < MIN_LEAF:
                continue
            lw = lp + ln * W_NEG
            rw = rp + rn * W_NEG
            g = (lw * gini(lp, ln * W_NEG) + rw * gini(rp, rn * W_NEG)) / tot_w
            gain = base - g
            if best is None or gain > best[0] + 1e-12:
                best = (gain, fi, v)
    if best is None or best[0] <= 1e-6:
        return leaf
    _, fi, thr = best
    left = {x: c for x, c in cdata.items() if x[fi] <= thr}
    right = {x: c for x, c in cdata.items() if x[fi] > thr}
    node = {"leaf": False, "f": fi, "thr": thr,
            "l": tree_fit(left, depth + 1), "r": tree_fit(right, depth + 1)}
    # merge children that decide the same way with the same confidence
    a, b = node["l"], node["r"]
    if a["leaf"] and b["leaf"] and a["gate"] == b["gate"] and leaf_conf(a) == leaf_conf(b):
        return leaf
    return node


def leaf_conf(n):
    t = n["pos"] + n["neg"]
    if t == 0:
        return 0
    pur = (n["pos"] if n["gate"] else n["neg"]) / t
    return 1 if pur >= CONF_PURITY else 0


def tree_predict(n, x):
    while not n["leaf"]:
        n = n["l"] if x[n["f"]] <= n["thr"] else n["r"]
    return (CLS_OFF if n["gate"] else CLS_CG), leaf_conf(n)


def tree_nodes(n):
    """internal nodes = comparators in hardware"""
    return 0 if n["leaf"] else 1 + tree_nodes(n["l"]) + tree_nodes(n["r"])


def tree_depth(n):
    return 0 if n["leaf"] else 1 + max(tree_depth(n["l"]), tree_depth(n["r"]))


def tree_verilog(n, sl):
    if n["leaf"]:
        cls = CLS_OFF if n["gate"] else CLS_CG
        return "{1'b%d, 2'd%d}" % (leaf_conf(n), cls)
    f = FEATS[n["f"]]
    return "((%s_%d <= %d'd%d) ? %s : %s)" % (f, sl, FWID[f], n["thr"],
                                               tree_verilog(n["l"], sl), tree_verilog(n["r"], sl))


def tree_text(n, ind=""):
    if n["leaf"]:
        return "%s-> %s (conf %d, long %d / short %d)\n" % (
            ind, "POWER-OFF" if n["gate"] else "stay (CG)", leaf_conf(n), n["pos"], n["neg"])
    f = FEATS[n["f"]]
    return ("%sif %s <= %d:\n" % (ind, f, n["thr"]) + tree_text(n["l"], ind + "    ") +
            "%selse:\n" % ind + tree_text(n["r"], ind + "    "))


# ----------------------------------------------------------------- logistic regression
def lr_fit(cdata, iters=1500, lr=0.5, l2=1e-3):
    """multinomial LR on scaled features; returns quantised (bias, weights) per class"""
    classes = [CLS_CG, CLS_RET, CLS_OFF]
    present = [k for k in classes if any(c.get(k, 0) for c in cdata.values())]
    rows = []
    for x, c in cdata.items():
        xs = [x[i] / float(FMAX[f]) for i, f in enumerate(FEATS)]
        for k, cnt in c.items():
            w = cnt * (W_NEG if k == CLS_CG else 1.0)
            rows.append((xs, k, w))
    W = {k: [0.0] * len(FEATS) for k in present}
    B = {k: 0.0 for k in present}
    tot = sum(r[2] for r in rows)
    if len(present) >= 2:
        for _ in range(iters):
            gW = {k: [0.0] * len(FEATS) for k in present}
            gB = {k: 0.0 for k in present}
            for xs, y, w in rows:
                s = {k: B[k] + sum(W[k][j] * xs[j] for j in range(len(FEATS))) for k in present}
                m = max(s.values())
                e = {k: math.exp(s[k] - m) for k in present}
                z = sum(e.values())
                for k in present:
                    g = (e[k] / z - (1.0 if k == y else 0.0)) * w
                    gB[k] += g
                    for j in range(len(FEATS)):
                        gW[k][j] += g * xs[j]
            for k in present:
                B[k] -= lr * gB[k] / tot
                for j in range(len(FEATS)):
                    W[k][j] -= lr * (gW[k][j] / tot + l2 * W[k][j])
    q = {}
    for k in classes:
        if k in present:
            q[k] = (int(round(B[k] * Q)),
                    [int(round(W[k][j] / FMAX[f] * Q)) for j, f in enumerate(FEATS)])
        else:
            q[k] = (-(1 << 20), [0] * len(FEATS))   # class never chosen
    if len(present) == 1:                           # degenerate: always that class
        q[present[0]] = (1 << 12, [0] * len(FEATS))
    return q


def lr_predict(q, x):
    s = {k: q[k][0] + sum(q[k][1][j] * x[j] for j in range(len(FEATS))) for k in q}
    order = sorted(s, key=lambda k: (-s[k], k))
    top, sec = order[0], order[1]
    conf = 1 if (s[top] - s[sec]) >= int(round(LR_MARGIN * Q)) else 0
    return top, conf


def sconst(v):
    return ("-32'sd%d" % (-v)) if v < 0 else ("32'sd%d" % v)


def lr_verilog(q, sl, out):
    L = []
    for k in (CLS_CG, CLS_RET, CLS_OFF):
        b, w = q[k]
        terms = [sconst(b)]
        for j, f in enumerate(FEATS):
            if w[j] != 0:
                terms.append("(%s * $signed({%d'd0, %s_%d}))" % (sconst(w[j]), 32 - FWID[f], f, sl))
        L.append("  wire signed [31:0] s%d_%d = %s;" % (k, sl, " + ".join(terms)))
    L.append("  wire c1_%d = (s1_%d >= s2_%d) && (s1_%d >= s3_%d);" % ((sl,) * 5))
    L.append("  wire c2_%d = !c1_%d && (s2_%d >= s3_%d);" % ((sl,) * 4))
    L.append("  wire signed [31:0] top_%d = c1_%d ? s1_%d : (c2_%d ? s2_%d : s3_%d);" % ((sl,) * 6))
    L.append("  wire signed [31:0] sec_%d = c1_%d ? ((s2_%d >= s3_%d) ? s2_%d : s3_%d) :" % ((sl,) * 6))
    L.append("                             (c2_%d ? ((s1_%d >= s3_%d) ? s1_%d : s3_%d) :" % ((sl,) * 5))
    L.append("                                     ((s1_%d >= s2_%d) ? s1_%d : s2_%d));" % ((sl,) * 4))
    L.append("  wire conf_%d = ((top_%d - sec_%d) >= 32'sd%d);" % (sl, sl, sl, int(round(LR_MARGIN * Q))))
    L.append("  assign %s = {conf_%d, (c1_%d ? 2'd1 : (c2_%d ? 2'd2 : 2'd3))};" % (out, sl, sl, sl))
    return "\n".join(L)


# ----------------------------------------------------------------- evaluation
def evaluate(pred_fn, data_by_test, is_tree, live):
    """per-test-group confusion on decision cycles, plus the reactive baseline"""
    res = {}
    for grp, tests in (("train T02-T08", TRAIN_TESTS), ("held-out T09-T16", None)):
        tp = fp = fn = tn = 0
        rtp = rfp = rfn = rtn = 0
        nconf = 0
        n = 0
        for t, smp in data_by_test.items():
            if tests is None and t in TRAIN_TESTS:
                continue
            if tests is not None and t not in tests:
                continue
            if t < 2:
                continue
            for x, R, lv in smp:
                long_ = R >= BE_LBL
                cls, conf = pred_fn(x)
                gate = conf == 1 and cls in (CLS_RET, CLS_OFF)
                nconf += conf
                n += 1
                if gate and long_:
                    tp += 1
                elif gate:
                    fp += 1
                elif long_:
                    fn += 1
                else:
                    tn += 1
                rg = x[0] >= 16          # reactive baseline: idle >= THR_PG
                if rg and long_:
                    rtp += 1
                elif rg:
                    rfp += 1
                elif long_:
                    rfn += 1
                else:
                    rtn += 1
        res[grp] = (n, tp, fp, fn, tn, rtp, rfp, rfn, rtn, nconf)
    return res


def fmt_eval(res):
    out = []
    out.append("    %-17s %7s | %-27s | %-27s" % ("cycles (idle)", "", "model  TP     FP     FN", "reactive(idle>=16) TP FP FN"))
    for grp, (n, tp, fp, fn, tn, rtp, rfp, rfn, rtn, nc) in res.items():
        prec = tp / (tp + fp) if (tp + fp) else 0.0
        rprec = rtp / (rtp + rfp) if (rtp + rfp) else 0.0
        out.append("    %-17s %7d | %6d %6d %6d p=%.2f | %6d %6d %6d p=%.2f" %
                   (grp, n, tp, fp, fn, prec, rtp, rfp, rfn, rprec))
    return "\n".join(out)


# ----------------------------------------------------------------- Verilog emit
HDR = """
// ==== ML MODELS BEGIN (generated by ml/train_ml.py - do not edit by hand) ====
//=============================================================================
// ml_models_fine / ml_models_coarse : exported power-gating policies, one per
// power domain. Input: 8 feature slots x 32 bit (see ml_feature_block).
// Output dec[3*d +: 3] = {confidence, class}, class 1 = stay (CG only),
// 2 = power off with retention, 3 = power off. The safety shell accepts a
// power-gating request only with confidence 1.
// %s
//=============================================================================
"""
FTR = "// ==== ML MODELS END ====\n"


def unpack(nsl):
    L = []
    for sl in range(nsl):
        for f in FEATS:
            L.append("  wire [%d:0] %s_%d = feat[%d +: %d];" % (FWID[f] - 1, f, sl, 32 * sl + FLSB[f], FWID[f]))
    return "\n".join(L)


def emit_module(name, grain, models):
    nsl = len(DOMS[grain])
    L = ["module %s (" % name, "  input  wire [255:0] feat,", "  output wire [23:0]  dec", ");"]
    L.append(unpack(nsl))
    for sl, (dname, kind) in enumerate(DOMS[grain]):
        L.append("  // slot %d %s : %s" % (sl, dname, "decision tree" if kind == "tree" else "logistic regression"))
        m = models.get(sl)
        out = "dec[%d +: 3]" % (3 * sl)
        if m is None:
            L.append("  assign %s = {1'b0, 2'd1};   // untrained: never request power gating" % out)
        elif kind == "tree":
            L.append("  assign %s = %s;" % (out, tree_verilog(m, sl)))
        else:
            L.append(lr_verilog(m, sl, out))
    if nsl < 8:
        L.append("  assign dec[23:%d] = %d'd0;" % (3 * nsl, 24 - 3 * nsl))
    L.append("endmodule")
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--untrained", action="store_true")
    ap.add_argument("--fine")
    ap.add_argument("--coarse")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--wneg", type=float, default=W_NEG, help="weight of idle-too-short samples")
    ap.add_argument("--purity", type=float, default=CONF_PURITY, help="tree leaf purity for confidence 1")
    a = ap.parse_args()
    globals()["W_NEG"] = a.wneg
    globals()["CONF_PURITY"] = a.purity

    models = {"fine": {}, "coarse": {}}
    report = ["FIDO V3 ML policy training report",
              "BE_LBL=%d  W_NEG=%.1f  tree depth<=%d min_leaf=%d purity>=%.2f  LR margin=ln3  Q=%d" %
              (BE_LBL, W_NEG, MAX_DEPTH, MIN_LEAF, CONF_PURITY, Q),
              "train: T02-T08   held out: T09-T16   (decision cycles = idle cycles of the domain)", ""]
    if not a.untrained:
        for grain, tdir in (("fine", a.fine), ("coarse", a.coarse)):
            if not tdir:
                sys.exit("--%s <trace dir> required" % grain)
            tr = read_traces(tdir, len(DOMS[grain]))
            report.append("=" * 78)
            report.append("GRAIN %s   traces: tests %s" % (grain.upper(), sorted(tr)))
            for sl, (dname, kind) in enumerate(DOMS[grain]):
                by_test = {t: samples(per[sl], None) for t, per in tr.items()}
                train = [s for t, sm in by_test.items() if t in TRAIN_TESTS for s in sm]
                if kind == "tree":
                    m = tree_fit(compress([(x, tree_label(R)) for x, R, lv in train]))
                    fn = (lambda m_: (lambda x: tree_predict(m_, x)))(m)
                    desc = "decision tree: %d comparators, depth %d" % (tree_nodes(m), tree_depth(m))
                else:
                    m = lr_fit(compress([(x, lr_label(R, lv)) for x, R, lv in train]))
                    fn = (lambda m_: (lambda x: lr_predict(m_, x)))(m)
                    desc = "logistic regression (3 classes, Q8 fixed point)"
                models[grain][sl] = m
                npos = sum(1 for x, R, lv in train if R >= BE_LBL)
                report.append("-" * 78)
                report.append("%-11s %s   train samples %d (long %d)" % (dname, desc, len(train), npos))
                report.append(fmt_eval(evaluate(fn, by_test, kind == "tree", None)))
                if kind == "tree":
                    report.append("    tree:")
                    report.append("".join("      " + l + "\n" for l in tree_text(m).rstrip().split("\n")).rstrip())
                else:
                    for k in (CLS_CG, CLS_RET, CLS_OFF):
                        report.append("    class %d bias %8d  w %s" % (k, m[k][0], dict(zip(FEATS, m[k][1]))))
            report.append("")
    note = "UNTRAINED placeholder" if a.untrained else \
        "trained on T02-T08 traces, BE_LBL=%d cycles (see ml/model_report.txt)" % BE_LBL
    text = HDR % note + emit_module("ml_models_fine", "fine", models["fine"]) + "\n" + \
        emit_module("ml_models_coarse", "coarse", models["coarse"]) + FTR
    with open(a.out, "w") as f:
        f.write(text)
    if not a.untrained:
        rp = os.path.join(os.path.dirname(os.path.abspath(a.out)), "model_report.txt")
        with open(rp, "w") as f:
            f.write("\n".join(report) + "\n")
        print("\n".join(report))
    print("written", a.out)


if __name__ == "__main__":
    main()
