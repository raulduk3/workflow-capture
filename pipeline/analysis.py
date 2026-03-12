#!/usr/bin/env python3
"""
Bulley & Andrews Workflow Study — EDA, Clustering & Visualization Pipeline.

Reads workflow_analysis.csv, performs integrity checks, feature engineering,
K-Means clustering with PCA, and generates publication-quality figures for
the summative LaTeX report.

Usage:
    python pipeline/analysis.py
"""

import os
import re
import ast
import sys
import hashlib
import warnings
import textwrap
from pathlib import Path
from collections import Counter

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")  # headless rendering
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
import seaborn as sns
from sklearn.preprocessing import StandardScaler, MultiLabelBinarizer
from sklearn.decomposition import PCA
from sklearn.cluster import KMeans, DBSCAN, AgglomerativeClustering
from sklearn.mixture import GaussianMixture
from sklearn.metrics import silhouette_score, silhouette_samples
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.manifold import TSNE
from sklearn.neighbors import NearestNeighbors
from scipy.cluster.hierarchy import linkage, fcluster, dendrogram
from scipy.spatial.distance import pdist

warnings.filterwarnings("ignore", category=FutureWarning)

# ── Paths ────────────────────────────────────────────────────────────────────
ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs"
FIGS = ROOT / "docs" / "figures"
FIGS.mkdir(parents=True, exist_ok=True)

CSV_PATH = LOGS / "workflow_analysis.csv"
SESSIONS_PATH = LOGS / "workflow_sessions.csv"

# ── Style ────────────────────────────────────────────────────────────────────
plt.rcParams.update({
    "font.family": "serif",
    "font.size": 9,
    "axes.titlesize": 10,
    "axes.labelsize": 9,
    "xtick.labelsize": 8,
    "ytick.labelsize": 8,
    "legend.fontsize": 8,
    "figure.dpi": 300,
    "savefig.dpi": 300,
    "savefig.bbox": "tight",
    "savefig.pad_inches": 0.05,
})
PALETTE = sns.color_palette("Set2", 8)
SUSPECT_PRIMARY_APPS = {"Workflow Capture", "Sessions", "Windows", "Unknown"}
HALLUCINATION_PATTERNS = re.compile(r"NASDAQ|S&P 500|stock|bitcoin|crypto", re.IGNORECASE)
AUTOMATION_BANDS = [
    (0.00, 0.30, "Low"),
    (0.30, 0.50, "Moderate"),
    (0.50, 0.70, "Medium"),
    (0.70, 0.85, "High"),
    (0.85, 1.000001, "Very High"),
]

# ── Participant enrichment (from POC-Participants CSV) ───────────────────────
PARTICIPANT_MAP = {
    # username → (Full Name, Department, Group)
    "rcrane":       ("Bob Crane",         "Project Accounting",  "Test"),
    "lwhite":       ("Liam White",        "General Accounting",  "Test"),
    "efuentes":     ("Erica Fuentes",     "Project Accounting",  "Test"),
    "hmillion":     ("Hannah Million",    "Project Accounting",  "Test"),
    "mbehun":       ("Michelle Behun",    "VP/Exec",             "Test"),
    "bmacgregor":   ("Blake MacGregor",   "Project Accounting",  "Test"),
    "jfahrenbach":  ("Joe Fahrenbach",    "PM",                  "Test"),
    "jcampo":       ("Jack Campo",        "PM",                  "Test"),
    "naquino":      ("Nahir Aquino",      "VP/Exec",             "Test"),
    "eflores":      ("Eduardo Flores",    "Project Accounting",  "Test"),
    "tpuntillo":    ("Tim Puntillo",      "OOC",                 "Control"),
    "abrown":       ("AJ Brown",          "VDC",                 "Control"),
    "kriggio":      ("Karen Riggio",      "Project Accounting",  "Unassigned"),
    "ggarneata":    ("Gabriel Garneata",  "General Accounting",  "Unassigned"),
    "cheras":       ("C. Heras",          "Unknown",             "Unknown"),
    "acuspilich":   ("A. Cuspilich",      "VDC",                 "Unknown"),
    "localutility": ("System Admin",      "IT (Pipeline)",       "N/A"),
}


def safe_parse_list(val):
    """Parse a JSON/Python-style list string into a Python list."""
    if pd.isna(val) or val == "":
        return []
    try:
        return ast.literal_eval(val)
    except (ValueError, SyntaxError):
        # Try stripping quotes
        val = str(val).strip("[]")
        return [x.strip().strip('"').strip("'") for x in val.split(",") if x.strip()]


def filtered_analysis_df(df, exclude_suspect=False):
    """Return the user-analysis subset, optionally excluding suspect Gemini rows."""
    dfa = df[df["username"] != "localutility"].copy()
    if exclude_suspect:
        dfa = dfa.loc[~identify_suspect_rows(dfa)].copy()
    return dfa


def identify_suspect_rows(df):
    """Flag rows with likely Gemini hallucination artifacts for reporting views."""
    workflow_text = df.get("workflow_description", pd.Series(index=df.index, dtype="object")).fillna("")
    return df["primary_app"].isin(SUSPECT_PRIMARY_APPS) | workflow_text.str.contains(HALLUCINATION_PATTERNS, na=False)


def finalize_figure(fig, output_path, rect=None):
    """Apply consistent spacing before saving publication figures."""
    if rect is None:
        fig.tight_layout(pad=1.0)
    else:
        fig.tight_layout(rect=rect, pad=1.0)
    fig.savefig(output_path)
    plt.close(fig)


def add_axis_padding(ax, x_pad=0.05, y_pad=0.08):
    """Expand axis limits slightly so markers and labels do not hug the frame."""
    x0, x1 = ax.get_xlim()
    y0, y1 = ax.get_ylim()
    if np.isfinite([x0, x1]).all() and x1 > x0:
        x_margin = (x1 - x0) * x_pad
        ax.set_xlim(x0 - x_margin, x1 + x_margin)
    if np.isfinite([y0, y1]).all() and y1 > y0:
        y_margin = (y1 - y0) * y_pad
        ax.set_ylim(y0 - y_margin, y1 + y_margin)


def wrapped_label(value, width=16):
    """Wrap long axis labels for compact layouts."""
    return textwrap.fill(str(value), width=width, break_long_words=False)


def latex_escape(value):
    """Escape LaTeX-sensitive characters in generated table content."""
    if pd.isna(value):
        return "—"
    text = str(value)
    replacements = {
        "\\": r"\textbackslash{}",
        "&": r"\&",
        "%": r"\%",
        "$": r"\$",
        "#": r"\#",
        "_": r"\_",
        "{": r"\{",
        "}": r"\}",
        "~": r"\textasciitilde{}",
        "^": r"\textasciicircum{}",
    }
    for old, new in replacements.items():
        text = text.replace(old, new)
    return text


def latex_shorten(value, width):
    """Shorten long text for table cells while preserving whole words."""
    if pd.isna(value):
        return "—"
    text = " ".join(str(value).split())
    if len(text) <= width:
        return latex_escape(text)
    return latex_escape(textwrap.shorten(text, width=width, placeholder="..."))


def automation_band_summary(scores):
    """Return non-empty automation score bands with boundary-aware binning."""
    rows = []
    for idx, (lower, upper, label) in enumerate(AUTOMATION_BANDS):
        is_last = idx == len(AUTOMATION_BANDS) - 1
        if is_last:
            mask = scores.between(lower, upper, inclusive="both")
        else:
            mask = (scores >= lower) & (scores < upper)
        count = int(mask.sum())
        if count == 0:
            continue
        upper_display = "1.00" if is_last else f"{upper:.2f}"
        rows.append({
            "label": f"{label}\n({lower:.2f}–{upper_display})",
            "midpoint": (lower + min(upper, 1.0)) / 2,
            "count": count,
            "lower": lower,
            "upper": upper,
        })
    return pd.DataFrame(rows)


def write_latex_table(output_path, column_spec, header_row, rows):
    """Write a spaced LaTeX table fragment with wrapped paragraph columns."""
    lines = [
        r"{\small",
        r"\renewcommand{\arraystretch}{1.18}",
        r"\setlength{\tabcolsep}{5pt}",
        rf"\begin{{tabular}}{{{column_spec}}}",
        r"\toprule",
        header_row,
        r"\midrule",
    ]
    lines.extend(rows)
    lines += [r"\bottomrule", r"\end{tabular}", r"}"]
    output_path.write_text("\n".join(lines))


# ═══════════════════════════════════════════════════════════════════════════════
# 1. DATA LOADING & ENRICHMENT
# ═══════════════════════════════════════════════════════════════════════════════

def load_data():
    """Load and enrich workflow_analysis.csv."""
    df = pd.read_csv(CSV_PATH)
    df["username"] = df["username"].str.lower().str.strip()

    # Enrich with participant data
    df["full_name"] = df["username"].map(lambda u: PARTICIPANT_MAP.get(u, ("Unknown", "", ""))[0])
    df["department"] = df["username"].map(lambda u: PARTICIPANT_MAP.get(u, ("", "Unknown", ""))[1])
    df["study_group"] = df["username"].map(lambda u: PARTICIPANT_MAP.get(u, ("", "", "Unknown"))[2])

    # Parse list columns
    df["detected_actions_list"] = df["detected_actions"].apply(safe_parse_list)
    df["app_sequence_list"] = df["app_sequence"].apply(safe_parse_list)

    # Derived features
    df["n_actions"] = df["detected_actions_list"].apply(len)
    df["n_apps"] = df["app_sequence_list"].apply(len)
    df["timestamp_dt"] = pd.to_datetime(df["timestamp"], errors="coerce")
    df["date"] = df["timestamp_dt"].dt.date

    return df


# ═══════════════════════════════════════════════════════════════════════════════
# 2. DATA INTEGRITY AUDIT
# ═══════════════════════════════════════════════════════════════════════════════

def integrity_audit(df):
    """Check data integrity and flag potential Gemini hallucinations."""
    flags = []

    # ── Schema check ──
    expected_cols = [
        "video_id", "username", "timestamp", "machine_id", "task_description",
        "day_of_week", "hour_of_day", "duration_sec", "file_size_mb",
        "workflow_description", "primary_app", "app_sequence", "detected_actions",
        "automation_score", "workflow_category", "sop_step_count",
        "automation_candidate_count", "top_automation_candidate",
        "source_path", "mp4_path", "analysis_md_path", "processed_at",
    ]
    missing_cols = [c for c in expected_cols if c not in df.columns]
    if missing_cols:
        flags.append(f"MISSING COLUMNS: {missing_cols}")

    # ── Null check ──
    for col in ["video_id", "username", "automation_score", "primary_app", "workflow_description"]:
        n_null = df[col].isna().sum()
        if n_null > 0:
            flags.append(f"NULL values in '{col}': {n_null} rows")

    # ── Cross-reference sessions ──
    if SESSIONS_PATH.exists():
        sessions = pd.read_csv(SESSIONS_PATH)
        n_analyzed = (sessions["Status"] == "Analyzed").sum()
        n_rejected = (sessions["Status"] == "Rejected").sum()
        flags.append(f"Sessions cross-ref: {n_analyzed} analyzed, {n_rejected} rejected, {len(sessions)} total")
        if len(df) != n_analyzed:
            flags.append(f"WARNING: analysis CSV has {len(df)} rows but sessions shows {n_analyzed} analyzed")

    # ── Hallucination flags ──
    suspect_rows = df[df["primary_app"].isin(SUSPECT_PRIMARY_APPS)]
    if len(suspect_rows) > 0:
        for _, r in suspect_rows.iterrows():
            flags.append(
                f"SUSPECT primary_app='{r['primary_app']}' for {r['username']}/{r['task_description']} "
                f"(video_id={r['video_id']})"
            )

    # Uniform 0.75 scores on very short recordings
    short_high = df[(df["duration_sec"] < 15) & (df["automation_score"] >= 0.75)]
    if len(short_high) > 0:
        for _, r in short_high.iterrows():
            flags.append(
                f"SHORT+HIGH: {r['duration_sec']}s with score={r['automation_score']} — "
                f"{r['username']}/{r['task_description']} (video_id={r['video_id']})"
            )

    # localutility = pipeline test recordings
    lu = df[df["username"] == "localutility"]
    if len(lu) > 0:
        flags.append(f"PIPELINE TEST: {len(lu)} 'localutility' recordings (exclude from user analysis)")

    # Descriptions mentioning NASDAQ, stock tickers, etc. (likely hallucinated)
    for _, r in df.iterrows():
        if HALLUCINATION_PATTERNS.search(str(r.get("workflow_description", ""))):
            flags.append(
                f"HALLUCINATION? Description mentions financial markets: "
                f"{r['username']}/{r['video_id']}: '{r['workflow_description'][:80]}...'"
            )

    return flags


# ═══════════════════════════════════════════════════════════════════════════════
# 3. FEATURE ENGINEERING
# ═══════════════════════════════════════════════════════════════════════════════

def build_features(df):
    """Build feature matrix for clustering. Returns (X_scaled, feature_names, pca_2d).
    
    Strategy: use PCA to reduce high-dimensional sparse features to ~10 components
    for clustering, then project to 2D for visualization.
    """
    # Exclude localutility
    dfa = df[df["username"] != "localutility"].copy().reset_index(drop=True)

    # ── Numeric features ──
    num_cols = ["duration_sec", "file_size_mb", "automation_score", "sop_step_count",
                "automation_candidate_count", "hour_of_day", "n_actions", "n_apps"]
    X_num = dfa[num_cols].fillna(0).values

    # ── Workflow category one-hot ──
    cat_dummies = pd.get_dummies(dfa["workflow_category"], prefix="cat")
    X_cat = cat_dummies.values

    # ── Detected actions multi-hot ──
    mlb = MultiLabelBinarizer()
    X_actions = mlb.fit_transform(dfa["detected_actions_list"])
    action_names = [f"act_{a}" for a in mlb.classes_]

    # ── Combine ──
    feature_names = list(num_cols) + list(cat_dummies.columns) + action_names
    X = np.hstack([X_num, X_cat, X_actions])

    # ── Scale ──
    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)

    # ── PCA for clustering (retain ~80% variance) ──
    n_pca = min(15, X_scaled.shape[1], X_scaled.shape[0])
    pca_full = PCA(n_components=n_pca, random_state=42)
    X_pca = pca_full.fit_transform(X_scaled)
    cum_var = np.cumsum(pca_full.explained_variance_ratio_)
    n_keep = int(np.searchsorted(cum_var, 0.80)) + 1
    n_keep = max(min(n_keep, len(cum_var)), min(5, len(cum_var)))
    X_cluster = X_pca[:, :n_keep]
    print(f"  → PCA: keeping {n_keep} components ({cum_var[n_keep-1]:.1%} variance)")

    # ── PCA 2D for visualization ──
    pca_2d_model = PCA(n_components=2, random_state=42)
    pca_2d = pca_2d_model.fit_transform(X_scaled)
    explained = pca_2d_model.explained_variance_ratio_

    return dfa, X_cluster, X_scaled, feature_names, pca_2d, explained


# ═══════════════════════════════════════════════════════════════════════════════
# 4. MULTI-METHOD CLUSTERING
# ═══════════════════════════════════════════════════════════════════════════════

def find_optimal_k(X, k_range=range(2, 9)):
    """Elbow method + silhouette analysis for K-Means."""
    inertias, sil_scores = [], []
    for k in k_range:
        km = KMeans(n_clusters=k, n_init=10, random_state=42)
        labels = km.fit_predict(X)
        inertias.append(km.inertia_)
        sil_scores.append(silhouette_score(X, labels))
    return list(k_range), inertias, sil_scores


def cluster_kmeans(X, k):
    """Run K-Means with chosen k."""
    km = KMeans(n_clusters=k, n_init=20, random_state=42)
    labels = km.fit_predict(X)
    sil = silhouette_score(X, labels)
    return labels, sil, km


def find_dbscan_eps(X):
    """Use k-nearest-neighbors distance elbow to find DBSCAN eps."""
    k = min(5, X.shape[0] - 1)
    nn = NearestNeighbors(n_neighbors=k)
    nn.fit(X)
    distances, _ = nn.kneighbors(X)
    kth_dist = np.sort(distances[:, -1])
    # Use the "knee" — steepest gradient change
    diffs = np.diff(kth_dist)
    diffs2 = np.diff(diffs)
    if len(diffs2) > 0:
        knee_idx = np.argmax(diffs2) + 1
        eps = kth_dist[knee_idx]
    else:
        eps = np.median(kth_dist)
    # Clamp to reasonable range
    eps = max(eps, np.percentile(kth_dist, 25))
    return eps, kth_dist


def cluster_dbscan(X):
    """Density-based clustering — finds natural groupings and noise."""
    eps, kth_dist = find_dbscan_eps(X)
    # Try a few eps values around the knee and pick best silhouette
    best_labels, best_sil, best_eps = None, -1, eps
    for eps_mult in [0.7, 0.85, 1.0, 1.15, 1.3]:
        trial_eps = eps * eps_mult
        db = DBSCAN(eps=trial_eps, min_samples=3)
        trial_labels = db.fit_predict(X)
        n_clusters = len(set(trial_labels) - {-1})
        if n_clusters >= 2:
            # Silhouette only on non-noise points
            mask = trial_labels != -1
            if mask.sum() >= n_clusters + 1:
                s = silhouette_score(X[mask], trial_labels[mask])
                if s > best_sil:
                    best_sil = s
                    best_labels = trial_labels
                    best_eps = trial_eps
    if best_labels is None:
        # Fallback: loosen params
        db = DBSCAN(eps=eps * 1.5, min_samples=2)
        best_labels = db.fit_predict(X)
        best_eps = eps * 1.5
        n_clusters = len(set(best_labels) - {-1})
        if n_clusters >= 2:
            mask = best_labels != -1
            best_sil = silhouette_score(X[mask], best_labels[mask]) if mask.sum() > n_clusters else -1
    return best_labels, best_sil, best_eps, kth_dist


def cluster_hierarchical(X, method="ward"):
    """Agglomerative clustering with dendrogram analysis."""
    Z = linkage(X, method=method)
    # Find best cut by silhouette across k=2..8
    best_k, best_sil, best_labels = 2, -1, None
    for k in range(2, min(9, X.shape[0])):
        labels_k = fcluster(Z, t=k, criterion="maxclust")
        s = silhouette_score(X, labels_k)
        if s > best_sil:
            best_sil = s
            best_k = k
            best_labels = labels_k
    if best_labels is None:
        best_labels = fcluster(Z, t=best_k, criterion="maxclust")
    # Convert 1-indexed to 0-indexed
    best_labels = best_labels - 1
    return best_labels, best_sil, best_k, Z


def cluster_gmm(X, k_range=range(2, 7)):
    """Gaussian Mixture Model — soft clustering with BIC selection."""
    bics, aics = [], []
    models = []
    for k in k_range:
        gmm = GaussianMixture(n_components=k, covariance_type="diag",
                              n_init=3, max_iter=200, random_state=42)
        gmm.fit(X)
        bics.append(gmm.bic(X))
        aics.append(gmm.aic(X))
        models.append(gmm)
    # Select by BIC (lower is better)
    best_idx = np.argmin(bics)
    best_gmm = models[best_idx]
    best_k = list(k_range)[best_idx]
    labels = best_gmm.predict(X)
    probas = best_gmm.predict_proba(X)
    sil = silhouette_score(X, labels) if len(set(labels)) > 1 else -1
    return labels, sil, best_k, probas, best_gmm, list(k_range), bics, aics


def build_consensus(labels_dict, n_samples):
    """Build consensus clusters from multiple methods using co-association matrix.
    
    Points frequently placed together across methods get high affinity.
    Final grouping via hierarchical clustering on the co-association matrix.
    """
    coassoc = np.zeros((n_samples, n_samples))
    n_methods = 0
    for method_name, labels in labels_dict.items():
        if labels is None:
            continue
        n_methods += 1
        for i in range(n_samples):
            if labels[i] == -1:  # noise in DBSCAN
                continue
            for j in range(i, n_samples):
                if labels[j] == -1:
                    continue
                if labels[i] == labels[j]:
                    coassoc[i, j] += 1
                    coassoc[j, i] += 1
    if n_methods > 0:
        coassoc /= n_methods
    
    # Convert co-association to distance
    dist_matrix = 1.0 - coassoc
    np.fill_diagonal(dist_matrix, 0)
    # Cluster the distance matrix
    condensed = pdist(dist_matrix)
    condensed = np.clip(condensed, 0, None)  # numerical safety
    Z = linkage(condensed, method="average")
    
    # Find best cut
    best_k, best_sil, best_labels = 3, -1, None
    for k in range(2, min(8, n_samples)):
        labels_k = fcluster(Z, t=k, criterion="maxclust") - 1
        if len(set(labels_k)) > 1:
            s = silhouette_score(dist_matrix, labels_k, metric="precomputed")
            if s > best_sil:
                best_sil = s
                best_k = k
                best_labels = labels_k
    if best_labels is None:
        best_labels = fcluster(Z, t=3, criterion="maxclust") - 1
    return best_labels, best_sil, best_k, coassoc


# ═══════════════════════════════════════════════════════════════════════════════
# 5. CLUSTER INTERPRETATION
# ═══════════════════════════════════════════════════════════════════════════════

def interpret_clusters(dfa, labels):
    """Generate interpretive labels for each cluster based on dominant features."""
    dfa = dfa.copy()
    dfa["cluster"] = labels

    summaries = {}
    for c in sorted(dfa["cluster"].unique()):
        subset = dfa[dfa["cluster"] == c]
        top_cat = subset["workflow_category"].mode().iloc[0] if len(subset) > 0 else "unknown"
        avg_score = subset["automation_score"].mean()
        avg_sop = subset["sop_step_count"].mean()
        top_app = subset["primary_app"].mode().iloc[0] if len(subset) > 0 else "unknown"
        n = len(subset)

        # Collect all actions
        all_actions = []
        for acts in subset["detected_actions_list"]:
            all_actions.extend(acts)
        top_actions = [a for a, _ in Counter(all_actions).most_common(3)]

        summaries[c] = {
            "n": n,
            "top_category": top_cat,
            "avg_score": avg_score,
            "avg_sop": avg_sop,
            "top_app": top_app,
            "top_actions": top_actions,
            "users": list(subset["username"].unique()),
            "departments": list(subset["department"].unique()),
        }
    return summaries


# ═══════════════════════════════════════════════════════════════════════════════
# 6. VISUALIZATIONS
# ═══════════════════════════════════════════════════════════════════════════════

def fig_cluster_map(dfa, pca_2d, labels, explained):
    """Fig 1: 2D PCA cluster scatter."""
    fig, ax = plt.subplots(figsize=(5.5, 4))
    for c in sorted(set(labels)):
        mask = labels == c
        ax.scatter(pca_2d[mask, 0], pca_2d[mask, 1],
                   c=[PALETTE[c % len(PALETTE)]], label=f"Cluster {c}",
                   s=40, alpha=0.75, edgecolors="white", linewidth=0.5)
    ax.set_xlabel(f"PC1 ({explained[0]:.1%} var.)")
    ax.set_ylabel(f"PC2 ({explained[1]:.1%} var.)")
    ax.set_title("Workflow Clusters (PCA Projection)")
    ax.legend(loc="best", framealpha=0.9)
    ax.grid(True, alpha=0.2)
    fig.savefig(FIGS / "fig1_cluster_map.pdf")
    plt.close(fig)


def fig_automation_distribution(df):
    """Fig 2: Automation score histogram with density."""
    dfa = df[df["username"] != "localutility"]
    fig, ax = plt.subplots(figsize=(4.5, 3))
    bins = [0, 0.3, 0.5, 0.7, 0.85, 1.0]
    bin_labels = ["Low\n(0–0.3)", "Moderate\n(0.3–0.5)", "Medium\n(0.5–0.7)",
                  "High\n(0.7–0.85)", "Very High\n(0.85–1.0)"]
    counts, _, patches = ax.hist(dfa["automation_score"], bins=bins,
                                 edgecolor="white", linewidth=0.8, color=PALETTE[1], alpha=0.85)
    # Add count labels
    for patch, count in zip(patches, counts):
        if count > 0:
            ax.text(patch.get_x() + patch.get_width() / 2, count + 0.3,
                    f"{int(count)}", ha="center", va="bottom", fontsize=8, fontweight="bold")
    ax.set_xticks([(bins[i] + bins[i+1]) / 2 for i in range(len(bins)-1)])
    ax.set_xticklabels(bin_labels, fontsize=7)
    ax.set_ylabel("Number of Workflows")
    ax.set_title("Automation Score Distribution")
    ax.set_ylim(0, max(counts) + 3)
    fig.savefig(FIGS / "fig2_automation_dist.pdf")
    plt.close(fig)


def fig_user_category_heatmap(df):
    """Fig 3: Users × workflow categories heatmap."""
    dfa = df[df["username"] != "localutility"]
    pivot = dfa.groupby(["full_name", "workflow_category"]).size().unstack(fill_value=0)
    # Sort by total recordings
    pivot = pivot.loc[pivot.sum(axis=1).sort_values(ascending=True).index]

    fig, ax = plt.subplots(figsize=(6, 4.5))
    sns.heatmap(pivot, annot=True, fmt="d", cmap="YlOrRd", linewidths=0.5,
                ax=ax, cbar_kws={"label": "Count"})
    ax.set_xlabel("Workflow Category")
    ax.set_ylabel("")
    ax.set_title("User × Category Activity Matrix")
    plt.xticks(rotation=35, ha="right")
    fig.savefig(FIGS / "fig3_user_category_heatmap.pdf")
    plt.close(fig)


def fig_sop_vs_score(df):
    """Fig 4: SOP complexity vs automation score scatter."""
    dfa = df[df["username"] != "localutility"]
    fig, ax = plt.subplots(figsize=(4.5, 3.5))

    # Size by duration, color by category
    categories = dfa["workflow_category"].unique()
    cat_colors = {cat: PALETTE[i % len(PALETTE)] for i, cat in enumerate(sorted(categories))}

    for cat in sorted(categories):
        mask = dfa["workflow_category"] == cat
        subset = dfa[mask]
        ax.scatter(subset["sop_step_count"], subset["automation_score"],
                   s=np.clip(subset["duration_sec"] / 8, 10, 120),
                   c=[cat_colors[cat]], label=cat, alpha=0.7, edgecolors="gray", linewidth=0.3)

    # Regression line
    z = np.polyfit(dfa["sop_step_count"], dfa["automation_score"], 1)
    p = np.poly1d(z)
    x_line = np.linspace(dfa["sop_step_count"].min(), dfa["sop_step_count"].max(), 100)
    ax.plot(x_line, p(x_line), "--", color="gray", alpha=0.6, linewidth=1)

    ax.set_xlabel("SOP Step Count")
    ax.set_ylabel("Automation Score")
    ax.set_title("Complexity vs. Automation Potential")
    ax.legend(loc="upper left", fontsize=5, ncol=2, framealpha=0.8)
    ax.grid(True, alpha=0.15)
    fig.savefig(FIGS / "fig4_sop_vs_score.pdf")
    plt.close(fig)


def fig_app_frequency(df):
    """Fig 5: Top applications bar chart."""
    dfa = df[df["username"] != "localutility"]
    app_counts = dfa["primary_app"].value_counts().head(12)

    # Average automation score per app
    app_scores = dfa.groupby("primary_app")["automation_score"].mean()

    fig, ax = plt.subplots(figsize=(5, 3.5))
    colors = [plt.cm.RdYlGn(app_scores.get(app, 0.5)) for app in app_counts.index]
    bars = ax.barh(range(len(app_counts)), app_counts.values, color=colors, edgecolor="white")

    ax.set_yticks(range(len(app_counts)))
    ax.set_yticklabels(app_counts.index, fontsize=7)
    ax.set_xlabel("Number of Workflows")
    ax.set_title("Primary Applications (colored by avg. automation score)")
    ax.invert_yaxis()

    # Add score annotations
    for i, (app, count) in enumerate(app_counts.items()):
        score = app_scores.get(app, 0)
        ax.text(count + 0.2, i, f"{score:.2f}", va="center", fontsize=6, color="gray")

    fig.savefig(FIGS / "fig5_app_frequency.pdf")
    plt.close(fig)


def fig_recording_timeline(df):
    """Fig 6: Recording timeline scatter by user."""
    dfa = df[df["username"] != "localutility"].copy()
    dfa["date_dt"] = pd.to_datetime(dfa["date"])

    # Sort users by first recording date
    user_order = dfa.groupby("full_name")["date_dt"].min().sort_values().index.tolist()
    user_y = {u: i for i, u in enumerate(user_order)}

    fig, ax = plt.subplots(figsize=(5.5, 4))

    dept_colors = {
        "Project Accounting": PALETTE[0],
        "General Accounting": PALETTE[1],
        "PM": PALETTE[2],
        "VP/Exec": PALETTE[3],
        "VDC": PALETTE[4],
        "OOC": PALETTE[5],
        "Unknown": PALETTE[6],
        "IT (Pipeline)": PALETTE[7],
    }

    for _, r in dfa.iterrows():
        y = user_y.get(r["full_name"], 0)
        c = dept_colors.get(r["department"], "gray")
        size = np.clip(r["duration_sec"] / 5, 8, 60)
        ax.scatter(r["date_dt"], y, s=size, c=[c], alpha=0.7,
                   edgecolors="white", linewidth=0.3)

    ax.set_yticks(range(len(user_order)))
    ax.set_yticklabels(user_order, fontsize=6)
    ax.set_xlabel("Date")
    ax.set_title("Recording Timeline by User")

    # Legend for departments
    from matplotlib.lines import Line2D
    handles = [Line2D([0], [0], marker="o", color="w", markerfacecolor=c, markersize=6, label=d)
               for d, c in dept_colors.items() if d in dfa["department"].values]
    ax.legend(handles=handles, loc="upper left", fontsize=5, ncol=2, framealpha=0.8)
    ax.grid(True, alpha=0.15, axis="x")
    fig.savefig(FIGS / "fig6_timeline.pdf")
    plt.close(fig)


def fig_action_cooccurrence(df):
    """Fig 7: Detected actions co-occurrence matrix."""
    dfa = df[df["username"] != "localutility"]

    # Count co-occurrences
    all_actions = set()
    for acts in dfa["detected_actions_list"]:
        all_actions.update(acts)

    # Filter to actions appearing in 3+ workflows
    action_counts = Counter()
    for acts in dfa["detected_actions_list"]:
        for a in acts:
            action_counts[a] += 1
    frequent_actions = sorted([a for a, c in action_counts.items() if c >= 3])

    n = len(frequent_actions)
    cooc = np.zeros((n, n), dtype=int)
    act_idx = {a: i for i, a in enumerate(frequent_actions)}

    for acts in dfa["detected_actions_list"]:
        present = [a for a in acts if a in act_idx]
        for i, a in enumerate(present):
            for b in present[i:]:
                cooc[act_idx[a], act_idx[b]] += 1
                if a != b:
                    cooc[act_idx[b], act_idx[a]] += 1

    fig, ax = plt.subplots(figsize=(6, 5))
    # Clean labels
    clean_labels = [a.replace("_", " ").replace("document review", "doc review")
                    for a in frequent_actions]
    mask = np.triu(np.ones_like(cooc, dtype=bool), k=1)
    sns.heatmap(cooc, mask=mask, annot=True, fmt="d", cmap="Blues",
                xticklabels=clean_labels, yticklabels=clean_labels,
                ax=ax, linewidths=0.5, cbar_kws={"label": "Co-occurrences"})
    plt.xticks(rotation=45, ha="right", fontsize=6)
    plt.yticks(fontsize=6)
    ax.set_title("Action Co-occurrence Matrix")
    fig.savefig(FIGS / "fig7_action_cooccurrence.pdf")
    plt.close(fig)


def fig_department_profile(df):
    """Fig 8: Department-level aggregated radar/bar comparison."""
    dfa = df[~df["username"].isin(["localutility"])].copy()

    dept_stats = dfa.groupby("department").agg(
        n_workflows=("video_id", "count"),
        avg_score=("automation_score", "mean"),
        avg_sop=("sop_step_count", "mean"),
        avg_duration=("duration_sec", "mean"),
        n_users=("username", "nunique"),
    ).reset_index()
    dept_stats = dept_stats[dept_stats["department"] != "IT (Pipeline)"]
    dept_stats = dept_stats.sort_values("n_workflows", ascending=True)

    fig, axes = plt.subplots(1, 3, figsize=(7, 3.5), sharey=True)

    axes[0].barh(dept_stats["department"], dept_stats["n_workflows"], color=PALETTE[0])
    axes[0].set_xlabel("Workflows")
    axes[0].set_title("Volume")

    axes[1].barh(dept_stats["department"], dept_stats["avg_score"], color=PALETTE[1])
    axes[1].set_xlabel("Avg Score")
    axes[1].set_title("Automation Potential")
    axes[1].set_xlim(0, 1)

    axes[2].barh(dept_stats["department"], dept_stats["avg_sop"], color=PALETTE[2])
    axes[2].set_xlabel("Avg Steps")
    axes[2].set_title("SOP Complexity")

    fig.suptitle("Department Profiles", fontsize=10, fontweight="bold")
    fig.tight_layout()
    fig.savefig(FIGS / "fig8_department_profiles.pdf")
    plt.close(fig)


def fig_elbow_silhouette(X, k_range, inertias, sil_scores):
    """Fig 9: Elbow plot + silhouette scores."""
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(6, 2.8))

    ax1.plot(k_range, inertias, "o-", color=PALETTE[0], markersize=5, linewidth=1.5)
    ax1.set_xlabel("k (number of clusters)")
    ax1.set_ylabel("Inertia")
    ax1.set_title("Elbow Method")
    ax1.grid(True, alpha=0.2)

    ax2.plot(k_range, sil_scores, "s-", color=PALETTE[2], markersize=5, linewidth=1.5)
    ax2.set_xlabel("k (number of clusters)")
    ax2.set_ylabel("Silhouette Score")
    ax2.set_title("Silhouette Analysis")
    ax2.grid(True, alpha=0.2)

    best_k = k_range[np.argmax(sil_scores)]
    ax2.axvline(best_k, ls="--", color="red", alpha=0.5, label=f"Best k={best_k}")
    ax2.legend()

    fig.tight_layout()
    fig.savefig(FIGS / "fig9_elbow_silhouette.pdf")
    plt.close(fig)


def fig_category_breakdown(df):
    """Fig 10: Workflow category pie/donut chart."""
    dfa = df[df["username"] != "localutility"]
    cats = dfa["workflow_category"].value_counts()

    fig, ax = plt.subplots(figsize=(4, 3.5))
    wedges, texts, autotexts = ax.pie(
        cats.values, labels=cats.index, autopct="%1.0f%%",
        colors=PALETTE[:len(cats)], pctdistance=0.8,
        wedgeprops=dict(width=0.5, edgecolor="white"),
        textprops={"fontsize": 7},
    )
    for t in autotexts:
        t.set_fontsize(6)
    ax.set_title("Workflow Category Distribution")
    fig.savefig(FIGS / "fig10_category_breakdown.pdf")
    plt.close(fig)


def fig_dendrogram(Z, dfa):
    """Fig 11: Hierarchical clustering dendrogram."""
    fig, ax = plt.subplots(figsize=(7, 4.5))
    # Use task descriptions as labels (truncated)
    labels_text = [f"{r['full_name'][:12]}:{r['task_description'][:18]}"
                   for _, r in dfa.iterrows()]
    dendrogram(Z, ax=ax, labels=labels_text, leaf_rotation=90, leaf_font_size=4,
               color_threshold=0.7 * max(Z[:, 2]),
               above_threshold_color="gray")
    ax.set_ylabel("Distance")
    ax.set_title("Hierarchical Clustering Dendrogram (Ward Linkage)")
    ax.tick_params(axis="x", labelsize=4)
    fig.savefig(FIGS / "fig11_dendrogram.pdf")
    plt.close(fig)


def fig_dbscan_map(dfa, pca_2d, db_labels, explained):
    """Fig 12: DBSCAN cluster map highlighting noise points."""
    fig, ax = plt.subplots(figsize=(5.5, 4))
    unique_labels = sorted(set(db_labels))
    for c in unique_labels:
        mask = db_labels == c
        if c == -1:
            ax.scatter(pca_2d[mask, 0], pca_2d[mask, 1],
                       c="gray", marker="x", s=30, alpha=0.5, label="Noise")
        else:
            ax.scatter(pca_2d[mask, 0], pca_2d[mask, 1],
                       c=[PALETTE[c % len(PALETTE)]], label=f"Cluster {c}",
                       s=45, alpha=0.75, edgecolors="white", linewidth=0.5)
    ax.set_xlabel(f"PC1 ({explained[0]:.1%} var.)")
    ax.set_ylabel(f"PC2 ({explained[1]:.1%} var.)")
    n_noise = (db_labels == -1).sum()
    n_clust = len(set(db_labels) - {-1})
    ax.set_title(f"DBSCAN Clusters ({n_clust} clusters, {n_noise} noise)")
    ax.legend(loc="best", framealpha=0.9, fontsize=7)
    ax.grid(True, alpha=0.2)
    fig.savefig(FIGS / "fig12_dbscan_map.pdf")
    plt.close(fig)


def fig_gmm_probabilities(dfa, pca_2d, gmm_probas, gmm_labels, explained):
    """Fig 13: GMM soft assignment — max probability as opacity, colored by cluster."""
    fig, ax = plt.subplots(figsize=(5.5, 4))
    max_prob = gmm_probas.max(axis=1)
    for c in sorted(set(gmm_labels)):
        mask = gmm_labels == c
        sc = ax.scatter(pca_2d[mask, 0], pca_2d[mask, 1],
                        c=[PALETTE[c % len(PALETTE)]], s=45,
                        alpha=max_prob[mask] * 0.8 + 0.2,
                        edgecolors="white", linewidth=0.5,
                        label=f"GMM {c} (n={mask.sum()})")
    ax.set_xlabel(f"PC1 ({explained[0]:.1%} var.)")
    ax.set_ylabel(f"PC2 ({explained[1]:.1%} var.)")
    ax.set_title("GMM Soft Clustering (opacity = assignment confidence)")
    ax.legend(loc="best", framealpha=0.9, fontsize=7)
    ax.grid(True, alpha=0.2)
    fig.savefig(FIGS / "fig13_gmm_probabilities.pdf")
    plt.close(fig)


def fig_gmm_bic_aic(k_range, bics, aics):
    """Fig 14: GMM model selection — BIC/AIC curves."""
    fig, ax = plt.subplots(figsize=(4.5, 3))
    ax.plot(k_range, bics, "o-", color=PALETTE[0], label="BIC", markersize=5)
    ax.plot(k_range, aics, "s--", color=PALETTE[2], label="AIC", markersize=5)
    best_k = k_range[np.argmin(bics)]
    ax.axvline(best_k, ls=":", color="red", alpha=0.5, label=f"Best k={best_k} (BIC)")
    ax.set_xlabel("Number of Components")
    ax.set_ylabel("Information Criterion")
    ax.set_title("GMM Model Selection")
    ax.legend(fontsize=7)
    ax.grid(True, alpha=0.2)
    fig.savefig(FIGS / "fig14_gmm_bic_aic.pdf")
    plt.close(fig)


def fig_consensus_coassoc(coassoc, consensus_labels, dfa):
    """Fig 15: Co-association matrix from consensus clustering."""
    # Sort by consensus label for block-diagonal structure
    order = np.argsort(consensus_labels)
    coassoc_sorted = coassoc[np.ix_(order, order)]
    sorted_labels = consensus_labels[order]

    fig, ax = plt.subplots(figsize=(6, 5))
    im = ax.imshow(coassoc_sorted, cmap="YlOrRd", vmin=0, vmax=1, aspect="auto")
    plt.colorbar(im, ax=ax, label="Co-association Frequency")

    # Draw cluster boundaries
    boundaries = np.where(np.diff(sorted_labels))[0] + 0.5
    for b in boundaries:
        ax.axhline(b, color="black", linewidth=0.8, alpha=0.7)
        ax.axvline(b, color="black", linewidth=0.8, alpha=0.7)

    ax.set_title("Consensus Co-Association Matrix")
    ax.set_xlabel("Workflow Index (sorted by cluster)")
    ax.set_ylabel("Workflow Index (sorted by cluster)")
    fig.savefig(FIGS / "fig15_consensus_coassoc.pdf")
    plt.close(fig)


def fig_method_comparison(dfa, pca_2d, results_dict, explained):
    """Fig 16: Side-by-side comparison of all clustering methods."""
    methods = list(results_dict.keys())
    n_methods = len(methods)
    fig, axes = plt.subplots(1, n_methods, figsize=(4 * n_methods, 3.5), squeeze=False)
    axes = axes[0]

    for ax, method_name in zip(axes, methods):
        labels = results_dict[method_name]["labels"]
        unique = sorted(set(labels))
        for c in unique:
            mask = labels == c
            if c == -1:
                ax.scatter(pca_2d[mask, 0], pca_2d[mask, 1],
                           c="gray", marker="x", s=20, alpha=0.5, label="Noise")
            else:
                ax.scatter(pca_2d[mask, 0], pca_2d[mask, 1],
                           c=[PALETTE[c % len(PALETTE)]], s=30, alpha=0.7,
                           edgecolors="white", linewidth=0.3, label=f"C{c}")
        sil = results_dict[method_name].get("sil", -1)
        k = results_dict[method_name].get("k", "?")
        ax.set_title(f"{method_name}\nk={k}, sil={sil:.3f}" if sil > -1
                     else f"{method_name}\nk={k}", fontsize=8)
        ax.set_xlabel(f"PC1 ({explained[0]:.1%})", fontsize=7)
        ax.legend(fontsize=5, loc="best", framealpha=0.7)
        ax.grid(True, alpha=0.15)

    axes[0].set_ylabel(f"PC2 ({explained[1]:.1%})", fontsize=7)
    fig.suptitle("Clustering Method Comparison (PCA Projection)", fontsize=10, fontweight="bold")
    fig.tight_layout()
    fig.savefig(FIGS / "fig16_method_comparison.pdf")
    plt.close(fig)


def fig_consensus_cluster_profiles(dfa, consensus_labels):
    """Fig 17: Radar-style profile comparison of consensus clusters."""
    dfa = dfa.copy()
    dfa["cluster"] = consensus_labels

    metrics = ["automation_score", "sop_step_count", "duration_sec", "n_actions", "n_apps"]
    metric_labels = ["Automation\\nScore", "SOP\\nSteps", "Duration\\n(s)", "N Actions", "N Apps"]

    # Normalize each metric to 0..1 range for comparison
    normed = {}
    for m in metrics:
        mn, mx = dfa[m].min(), dfa[m].max()
        rng = mx - mn if mx != mn else 1
        normed[m] = (dfa[m] - mn) / rng

    n_clusters = len(set(consensus_labels))
    fig, axes = plt.subplots(1, n_clusters, figsize=(3.5 * n_clusters, 3), squeeze=False)
    axes = axes[0]

    for c, ax in zip(sorted(set(consensus_labels)), axes):
        mask = dfa["cluster"] == c
        means = [normed[m][mask].mean() for m in metrics]
        x_pos = np.arange(len(metrics))
        bars = ax.bar(x_pos, means, color=PALETTE[c % len(PALETTE)], alpha=0.8, edgecolor="white")
        ax.set_xticks(x_pos)
        ax.set_xticklabels(metric_labels, fontsize=6)
        ax.set_ylim(0, 1.1)
        ax.set_title(f"Cluster {c} (n={mask.sum()})", fontsize=8)
        ax.grid(True, alpha=0.15, axis="y")
        # Add raw mean annotations
        for bar, m in zip(bars, metrics):
            raw_mean = dfa.loc[mask, m].mean()
            ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.03,
                    f"{raw_mean:.1f}", ha="center", fontsize=5, color="gray")

    fig.suptitle("Consensus Cluster Profiles (normalized)", fontsize=10, fontweight="bold")
    fig.tight_layout()
    fig.savefig(FIGS / "fig17_consensus_profiles.pdf")
    plt.close(fig)


# ═══════════════════════════════════════════════════════════════════════════════
# 7. GENERATE DATA TABLES FOR LATEX
# ═══════════════════════════════════════════════════════════════════════════════

def generate_latex_tables(df, dfa_clustered, cluster_summaries):
    """Generate .tex table fragments for direct inclusion."""
    tables_dir = FIGS.parent / "tables"
    tables_dir.mkdir(exist_ok=True)

    # ── Table 1: User participation ──
    dfa = df[df["username"] != "localutility"]
    user_stats = dfa.groupby(["full_name", "department"]).agg(
        n=("video_id", "count"),
        avg_score=("automation_score", "mean"),
        avg_sop=("sop_step_count", "mean"),
        total_min=("duration_sec", "sum"),
        top_app=("primary_app", lambda x: x.mode().iloc[0] if len(x) > 0 else "—"),
    ).reset_index()
    user_stats["total_min"] = (user_stats["total_min"] / 60).round(1)
    user_stats = user_stats.sort_values("n", ascending=False)

    lines = [
        r"\begin{tabular}{llrrrrl}",
        r"\toprule",
        r"\textbf{Participant} & \textbf{Dept.} & \textbf{N} & \textbf{Avg Score} & \textbf{Avg SOP} & \textbf{Min.} & \textbf{Top App} \\",
        r"\midrule",
    ]
    for _, r in user_stats.iterrows():
        dept_short = r["department"][:12]
        lines.append(
            f"{r['full_name']} & {dept_short} & {r['n']} & {r['avg_score']:.2f} & "
            f"{r['avg_sop']:.0f} & {r['total_min']} & {r['top_app']} \\\\"
        )
    lines += [r"\bottomrule", r"\end{tabular}"]
    (tables_dir / "tab_participants.tex").write_text("\n".join(lines))

    # ── Table 2: Cluster summary ──
    lines = [
        r"\begin{tabular}{clrrll}",
        r"\toprule",
        r"\textbf{Cluster} & \textbf{Category} & \textbf{N} & \textbf{Avg Score} & \textbf{Top App} & \textbf{Top Actions} \\",
        r"\midrule",
    ]
    for c, s in sorted(cluster_summaries.items()):
        actions_str = ", ".join(s["top_actions"][:3])
        lines.append(
            f"{c} & {s['top_category']} & {s['n']} & {s['avg_score']:.2f} & "
            f"{s['top_app']} & {actions_str} \\\\"
        )
    lines += [r"\bottomrule", r"\end{tabular}"]
    (tables_dir / "tab_clusters.tex").write_text("\n".join(lines))

    # ── Table 3: Top automation candidates ──
    top_auto = dfa.nlargest(15, "automation_score")[
        ["full_name", "task_description", "primary_app", "automation_score",
         "sop_step_count", "top_automation_candidate"]
    ].copy()
    top_auto["task_description"] = top_auto["task_description"].str[:30]
    top_auto["top_automation_candidate"] = top_auto["top_automation_candidate"].str[:30]

    lines = [
        r"\begin{tabular}{llrlrl}",
        r"\toprule",
        r"\textbf{User} & \textbf{Task} & \textbf{Score} & \textbf{App} & \textbf{SOP} & \textbf{Top Candidate} \\",
        r"\midrule",
    ]
    for _, r in top_auto.iterrows():
        tac = r["top_automation_candidate"] if pd.notna(r["top_automation_candidate"]) else "—"
        lines.append(
            f"{r['full_name']} & {r['task_description']} & {r['automation_score']:.2f} & "
            f"{r['primary_app']} & {r['sop_step_count']:.0f} & {tac} \\\\"
        )
    lines += [r"\bottomrule", r"\end{tabular}"]
    (tables_dir / "tab_top_automation.tex").write_text("\n".join(lines))

    # ── Table 4: Deep-dive target workflows ──
    # High score + high SOP = best candidates for tool-building
    dfa_scored = dfa.copy()
    dfa_scored["impact_score"] = dfa_scored["automation_score"] * np.log1p(dfa_scored["sop_step_count"])
    top_impact = dfa_scored.nlargest(10, "impact_score")[
        ["full_name", "department", "task_description", "automation_score",
         "sop_step_count", "workflow_category", "primary_app"]
    ].copy()
    top_impact["task_description"] = top_impact["task_description"].str[:35]

    lines = [
        r"\begin{tabular}{lllrrl}",
        r"\toprule",
        r"\textbf{User} & \textbf{Dept.} & \textbf{Task} & \textbf{Score} & \textbf{Steps} & \textbf{Category} \\",
        r"\midrule",
    ]
    for _, r in top_impact.iterrows():
        lines.append(
            f"{r['full_name']} & {r['department'][:10]} & {r['task_description']} & "
            f"{r['automation_score']:.2f} & {r['sop_step_count']:.0f} & {r['workflow_category']} \\\\"
        )
    lines += [r"\bottomrule", r"\end{tabular}"]
    (tables_dir / "tab_deep_dive.tex").write_text("\n".join(lines))

    print(f"  → Generated 4 table fragments in {tables_dir}")


# ═══════════════════════════════════════════════════════════════════════════════
# 8. MAIN
# ═══════════════════════════════════════════════════════════════════════════════

def main():
    print("=" * 60)
    print("Bulley & Andrews — Workflow Study Analysis Pipeline")
    print("=" * 60)

    # ── Load ──
    print("\n[1/8] Loading data...")
    df = load_data()
    print(f"  → {len(df)} workflows, {df['username'].nunique()} users, "
          f"{df['department'].nunique()} departments")

    # ── Integrity ──
    print("\n[2/8] Running integrity audit...")
    flags = integrity_audit(df)
    for f in flags:
        print(f"  ⚑ {f}")

    # ── Features ──
    print("\n[3/8] Building feature matrix...")
    dfa, X_cluster, X_full, feature_names, pca_2d, explained = build_features(df)
    print(f"  → {X_cluster.shape[0]} workflows × {X_cluster.shape[1]} clustering features "
          f"(from {len(feature_names)} original)")
    print(f"  → PCA 2D explained variance: PC1={explained[0]:.1%}, PC2={explained[1]:.1%}")

    # ── Multi-Method Clustering ──
    print("\n[4/8] Multi-method clustering...")
    results = {}

    # 4a. K-Means with elbow analysis
    print("\n  ── K-Means ──")
    k_range, inertias, sil_scores = find_optimal_k(X_cluster)
    best_sil_km = max(sil_scores)
    viable = [(k, s) for k, s in zip(k_range, sil_scores) if s >= best_sil_km * 0.85 and 3 <= k <= 6]
    if viable:
        km_k = max(viable, key=lambda x: x[1])[0]
    else:
        km_k = k_range[np.argmax(sil_scores)]
    km_labels, km_sil, km_model = cluster_kmeans(X_cluster, km_k)
    results["K-Means"] = {"labels": km_labels, "sil": km_sil, "k": km_k}
    print(f"  → K-Means: k={km_k}, silhouette={km_sil:.3f}")

    # 4b. DBSCAN
    print("\n  ── DBSCAN ──")
    db_labels, db_sil, db_eps, db_knn_dist = cluster_dbscan(X_cluster)
    n_db_clusters = len(set(db_labels) - {-1})
    n_db_noise = (db_labels == -1).sum()
    results["DBSCAN"] = {"labels": db_labels, "sil": db_sil, "k": n_db_clusters}
    print(f"  → DBSCAN: {n_db_clusters} clusters, {n_db_noise} noise points, "
          f"eps={db_eps:.2f}, silhouette={db_sil:.3f}")

    # 4c. Hierarchical (Ward)
    print("\n  ── Hierarchical (Ward) ──")
    hier_labels, hier_sil, hier_k, Z = cluster_hierarchical(X_cluster)
    results["Hierarchical"] = {"labels": hier_labels, "sil": hier_sil, "k": hier_k}
    print(f"  → Hierarchical: k={hier_k}, silhouette={hier_sil:.3f}")

    # 4d. Gaussian Mixture Model
    print("\n  ── GMM ──")
    gmm_labels, gmm_sil, gmm_k, gmm_probas, gmm_model, gmm_k_range, gmm_bics, gmm_aics = \
        cluster_gmm(X_cluster)
    results["GMM"] = {"labels": gmm_labels, "sil": gmm_sil, "k": gmm_k}
    print(f"  → GMM: k={gmm_k} (BIC-selected), silhouette={gmm_sil:.3f}")

    # 4e. Consensus
    print("\n  ── Consensus ──")
    labels_for_consensus = {
        "K-Means": km_labels,
        "Hierarchical": hier_labels,
        "GMM": gmm_labels,
        "DBSCAN": db_labels,
    }
    consensus_labels, consensus_sil, consensus_k, coassoc = \
        build_consensus(labels_for_consensus, len(dfa))
    results["Consensus"] = {"labels": consensus_labels, "sil": consensus_sil, "k": consensus_k}
    dfa["cluster"] = consensus_labels
    print(f"  → Consensus: k={consensus_k}, silhouette={consensus_sil:.3f}")

    # Summary table
    print("\n  ┌─────────────────┬────┬───────────┐")
    print("  │ Method          │  k │ Silhouette│")
    print("  ├─────────────────┼────┼───────────┤")
    for name, r in results.items():
        sil_str = f"{r['sil']:.3f}" if r['sil'] > -1 else "  N/A"
        print(f"  │ {name:<15s} │ {r['k']:>2} │ {sil_str:>9s} │")
    print("  └─────────────────┴────┴───────────┘")

    # ── Interpret consensus clusters ──
    print("\n[5/8] Interpreting consensus clusters...")
    summaries = interpret_clusters(dfa, consensus_labels)
    for c, s in sorted(summaries.items()):
        print(f"  Cluster {c}: n={s['n']}, cat={s['top_category']}, "
              f"avg_score={s['avg_score']:.2f}, app={s['top_app']}, "
              f"actions={s['top_actions'][:3]}")
        depts = ", ".join(sorted(set(s["departments"])))
        print(f"           depts=[{depts}]")

    # ── Visualizations ──
    print("\n[6/8] Generating figures...")

    # Original figures (1–10)
    fig_cluster_map(dfa, pca_2d, consensus_labels, explained)
    print("  → fig1_cluster_map.pdf (consensus)")
    fig_automation_distribution(df)
    print("  → fig2_automation_dist.pdf")
    fig_user_category_heatmap(df)
    print("  → fig3_user_category_heatmap.pdf")
    fig_sop_vs_score(df)
    print("  → fig4_sop_vs_score.pdf")
    fig_app_frequency(df)
    print("  → fig5_app_frequency.pdf")
    fig_recording_timeline(df)
    print("  → fig6_timeline.pdf")
    fig_action_cooccurrence(df)
    print("  → fig7_action_cooccurrence.pdf")
    fig_department_profile(df)
    print("  → fig8_department_profiles.pdf")
    fig_elbow_silhouette(X_cluster, k_range, inertias, sil_scores)
    print("  → fig9_elbow_silhouette.pdf")
    fig_category_breakdown(df)
    print("  → fig10_category_breakdown.pdf")

    # New multi-method figures (11–17)
    fig_dendrogram(Z, dfa)
    print("  → fig11_dendrogram.pdf")
    fig_dbscan_map(dfa, pca_2d, db_labels, explained)
    print("  → fig12_dbscan_map.pdf")
    fig_gmm_probabilities(dfa, pca_2d, gmm_probas, gmm_labels, explained)
    print("  → fig13_gmm_probabilities.pdf")
    fig_gmm_bic_aic(gmm_k_range, gmm_bics, gmm_aics)
    print("  → fig14_gmm_bic_aic.pdf")
    fig_consensus_coassoc(coassoc, consensus_labels, dfa)
    print("  → fig15_consensus_coassoc.pdf")
    fig_method_comparison(dfa, pca_2d, results, explained)
    print("  → fig16_method_comparison.pdf")
    fig_consensus_cluster_profiles(dfa, consensus_labels)
    print("  → fig17_consensus_profiles.pdf")

    # ── LaTeX tables ──
    print("\n[7/8] Generating LaTeX table fragments...")
    generate_latex_tables(df, dfa, summaries)

    # ── Method comparison table for LaTeX ──
    print("\n[8/8] Generating clustering comparison table...")
    tables_dir = FIGS.parent / "tables"
    lines = [
        r"\begin{tabular}{lrrp{4.5cm}}",
        r"\toprule",
        r"\textbf{Method} & \textbf{k} & \textbf{Silhouette} & \textbf{Notes} \\",
        r"\midrule",
    ]
    method_notes = {
        "K-Means": "Centroid-based; assumes spherical clusters",
        "DBSCAN": f"{n_db_noise} noise points identified as outliers",
        "Hierarchical": "Ward linkage; see dendrogram (Fig.~11)",
        "GMM": "Soft assignments; BIC-selected components",
        "Consensus": "Co-association of all methods; final labels",
    }
    for name, r in results.items():
        sil_str = f"{r['sil']:.3f}" if r['sil'] > -1 else "N/A"
        note = method_notes.get(name, "")
        lines.append(f"{name} & {r['k']} & {sil_str} & {note} \\\\")
    lines += [r"\bottomrule", r"\end{tabular}"]
    (tables_dir / "tab_clustering_comparison.tex").write_text("\n".join(lines))
    print("  → tab_clustering_comparison.tex")

    # ── Summary stats for report ──
    dfa_clean = df[df["username"] != "localutility"]
    print("\n" + "=" * 60)
    print("SUMMARY STATISTICS")
    print("=" * 60)
    print(f"  Total workflows analyzed:     {len(dfa_clean)}")
    print(f"  Unique participants:          {dfa_clean['full_name'].nunique()}")
    print(f"  Departments represented:      {dfa_clean[dfa_clean['department'] != 'Unknown']['department'].nunique()}")
    print(f"  Date range:                   {dfa_clean['date'].min()} → {dfa_clean['date'].max()}")
    print(f"  Total recording time:         {dfa_clean['duration_sec'].sum() / 3600:.1f} hours")
    print(f"  Avg recording length:         {dfa_clean['duration_sec'].mean():.0f}s ({dfa_clean['duration_sec'].mean()/60:.1f} min)")
    print(f"  Avg automation score:         {dfa_clean['automation_score'].mean():.2f}")
    print(f"  Workflows ≥ 0.7 score:        {(dfa_clean['automation_score'] >= 0.7).sum()} ({(dfa_clean['automation_score'] >= 0.7).mean():.0%})")
    print(f"  Avg SOP complexity:           {dfa_clean['sop_step_count'].mean():.1f} steps")
    print(f"  Most common app:              {dfa_clean['primary_app'].mode().iloc[0]}")
    print(f"  Most common category:         {dfa_clean['workflow_category'].mode().iloc[0]}")

    print("\n  CLUSTERING RESULTS:")
    for name, r in results.items():
        sil_str = f"{r['sil']:.3f}" if r['sil'] > -1 else "N/A"
        marker = " ★" if name == "Consensus" else ""
        print(f"    {name:<15s}: k={r['k']}, silhouette={sil_str}{marker}")

    print(f"\n✓ All outputs in: {FIGS}")
    print(f"✓ Table fragments in: {FIGS.parent / 'tables'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
