#!/usr/bin/env python3
"""Pages whose split or crop moved between two hill-climb runs.

    diff_split.py <resultsA> <resultsB> <outdir> [--no-images]

A page has moved when its type changed, its split moved more than 0.3% of the width,
or any crop edge moved more than 0.5% of the page. Writes <outdir>/moved.json, and for
each moved page a full-height close-up PNG (render_strips.swift) with A's lines in red
and B's in blue. Pages are matched by book and page number, so a synthetic or sampled
book diffs the same way as any other. Python standard library only.
"""
import json
import os
import subprocess
import sys

SPLIT_LIMIT = 0.003
EDGE_LIMIT = 0.005


def records(folder):
    with open(os.path.join(folder, "split-pages.json")) as f:
        data = json.load(f)
    return {(r["book"], r["page"]): r for r in data["pages"]}


def edges(rect):
    x, y, w, h = rect
    return [x, y, x + w, y + h]


def moved_by(a, b):
    """Why page record `a` differs from `b`, as a list of short reasons (empty: it has not moved)."""
    why = []
    if a["cls"] != b["cls"]:
        why.append("type %s -> %s" % (a["cls"], b["cls"]))
    if a["cls"] == "spread" and b["cls"] == "spread":
        d = abs(a["split"] - b["split"])
        if d > SPLIT_LIMIT:
            why.append("split %.4f -> %.4f (%.2f%%)" % (a["split"], b["split"], 100 * d))
    pairs = [("left", a["left"], b["left"])]
    if a["cls"] == "spread" and b["cls"] == "spread" and a["right"] and b["right"]:
        pairs.append(("right", a["right"], b["right"]))
    names = ["x0", "y0", "x1", "y1"]
    for side, ra, rb in pairs:
        for n, ea, eb in zip(names, edges(ra), edges(rb)):
            if abs(ea - eb) > EDGE_LIMIT:
                why.append("%s %s %.4f -> %.4f" % (side, n, ea, eb))
    return why


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 3:
        print(__doc__)
        sys.exit(2)
    folder_a, folder_b, outdir = args
    images = "--no-images" not in sys.argv
    a, b = records(folder_a), records(folder_b)
    # Where the books are: HILLCLIMB_DIR, else two folders up from results/<label>.
    root = os.environ.get("HILLCLIMB_DIR") or os.path.dirname(os.path.dirname(os.path.abspath(folder_a)))
    common = sorted(set(a) & set(b))
    moved = []
    for key in common:
        why = moved_by(a[key], b[key])
        if why:
            moved.append({"book": key[0], "page": key[1], "why": why, "a": a[key], "b": b[key]})
    only_a, only_b = len(set(a) - set(b)), len(set(b) - set(a))
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "moved.json"), "w") as f:
        json.dump({"compared": len(common), "moved": moved}, f, indent=1, sort_keys=True)
    for m in moved:
        print("%s p%d: %s" % (m["book"], m["page"] + 1, "; ".join(m["why"])))
    print("compared %d pages, %d moved%s" % (
        len(common), len(moved),
        " (%d only in A, %d only in B)" % (only_a, only_b) if only_a or only_b else ""))
    if moved and images:
        jobs = []
        for m in moved:
            name = "%s-p%d.png" % (os.path.splitext(os.path.basename(m["book"]))[0].replace(" ", "_"), m["page"] + 1)
            jobs.append({"pdf": os.path.join(root, m["book"]), "page": m["page"],
                         "out": os.path.join(outdir, name), "a": m["a"], "b": m["b"]})
        job_file = os.path.join(outdir, "jobs.json")
        with open(job_file, "w") as f:
            json.dump(jobs, f)
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "render_strips.swift")
        subprocess.run(["swift", script, job_file], check=False)


if __name__ == "__main__":
    main()
