#!/usr/bin/env python3
"""Tenpo content importer — builds the shipped SQLite curriculum DB (§4.7, §5, §9 Phase 1.3).

This script produces (or fills) the `content_item` / `item_link` tables that the iOS
app (GRDB/SQLite) opens read-only. The output schema is byte-for-byte the one created
by the Swift migration in
`ios/Packages/TenpoKit/Sources/Persistence/DatabaseManager.swift` (migration id
"v1_schema"). A fresh DB built here also writes GRDB's `grdb_migrations` marker so the
app treats the file as already-migrated and does not try to recreate the tables.

Standard library only. No third-party packages are required for `--seed` (the default,
app-shipping path). Optional real-source importers use only `json` and
`xml.etree.ElementTree`, also stdlib.

--------------------------------------------------------------------------------
DATA SOURCES, DOWNLOAD URLS, AND LICENSES  (surfaced on the app's Licenses screen, §8.3)
--------------------------------------------------------------------------------
* jmdict-simplified (vocab)
    What:    JMdict Japanese-English dictionary, JSON build.
    URL:     https://github.com/scriptin/jmdict-simplified  (releases: jmdict-eng-*.json)
    Upstream:https://www.edrdg.org/jmdict/edict_doc.html
    License: JMdict/EDICT is the property of the Electronic Dictionary Research and
             Development Group (EDRDG), used under the Group's licence (CC BY-SA 4.0
             framework). Attribution + link to the EDRDG project pages required.
             --> content_item.source = "JMdict", license = "EDRDG - CC BY-SA 4.0"

* KANJIDIC2 (kanji)
    What:    Kanji dictionary (readings, meanings, stroke counts), XML.
    URL:     https://www.edrdg.org/kanjidic/kanjidic2.xml.gz
    License: EDRDG, CC BY-SA 4.0 framework (as JMdict above).
             --> source = "KANJIDIC2", license = "EDRDG - CC BY-SA 4.0"

* Kanjium accents.txt (pitch accent)
    What:    ~124k word pitch-accent database (mora-position notation).
    URL:     https://github.com/mifunetoshiro/kanjium  (data/source_files/accents.txt)
    License: Pitch-accent notation provided by Uros O. through his free database;
             see the Kanjium README plus its upstream EDRDG attributions.
             --> attached to vocab payloads under payload.pitch (no row of its own)

* Kanjium frequency lists (frequency_rank)
    What:    Novel / Wikipedia frequency-ordered word lists.
    URL:     https://github.com/mifunetoshiro/kanjium
    License: as Kanjium above.
             --> sets content_item.frequency_rank on matching vocab

* Tatoeba (example sentences)
    What:    Crowd-sourced example sentences.
    URL:     https://tatoeba.org/en/downloads  (sentences.csv: id<TAB>lang<TAB>text)
    License: CC BY 2.0 FR. Attribute Tatoeba.org.
             --> kind=sentence, source = "Tatoeba", license = "CC BY 2.0 FR"

The committed starter curriculum under tools/seed/ (loaded by --seed) is authored
in-house for Tenpo and ships under the app's own terms
(source = "Tenpo seed", license = "Proprietary - Tenpo"); it is deliberately NOT
derived from the CC BY-SA dictionary data so the share-alike obligation stays scoped
to real imported dictionary tables (§8.3).

--------------------------------------------------------------------------------
USAGE
--------------------------------------------------------------------------------
    # Default path the app uses today — no downloads needed:
    python3 tools/import_content.py --seed --out tools/build/tenpo_seed.sqlite

    # Real sources (any subset; absent files are skipped with a log line):
    python3 tools/import_content.py --out tools/build/tenpo_full.sqlite \\
        --jmdict data/jmdict-eng.json \\
        --kanjidic data/kanjidic2.xml \\
        --kanjium-accents data/accents.txt \\
        --kanjium-freq data/freq_novels.txt \\
        --tatoeba data/jpn_sentences.tsv --tatoeba-band N5 --tatoeba-limit 200

    # --seed and real sources can be combined; run is idempotent (re-running is safe).
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sqlite3
import sys
from pathlib import Path
from typing import Any, Iterable

log = logging.getLogger("import_content")

LANGUAGE = "ja"
GRDB_MIGRATION_ID = "v1_schema"

SEED_SOURCE = "Tenpo seed"
SEED_LICENSE = "Proprietary - Tenpo"

# --------------------------------------------------------------------------------
# Schema  (mirrors DatabaseManager.migrator "v1_schema" exactly; IF NOT EXISTS so this
# is safe both for a fresh importer-built DB and for an app-created DB passed via --out)
# --------------------------------------------------------------------------------

SCHEMA_STATEMENTS: list[str] = [
    """
    CREATE TABLE IF NOT EXISTS content_item (
      id TEXT PRIMARY KEY,
      language TEXT NOT NULL,
      kind TEXT NOT NULL,
      payload TEXT NOT NULL,
      band TEXT,
      frequency_rank INTEGER,
      source TEXT,
      license TEXT
    );
    """,
    """
    CREATE TABLE IF NOT EXISTS item_link (
      from_id TEXT NOT NULL,
      to_id TEXT NOT NULL,
      relation TEXT NOT NULL,
      PRIMARY KEY (from_id, to_id, relation)
    );
    """,
    """
    CREATE TABLE IF NOT EXISTS skill_state (
      item_id TEXT NOT NULL,
      dimension TEXT NOT NULL,
      stability REAL,
      difficulty REAL,
      due DATETIME,
      last_review DATETIME,
      reps INTEGER NOT NULL DEFAULT 0,
      lapses INTEGER NOT NULL DEFAULT 0,
      suspended BOOLEAN NOT NULL DEFAULT FALSE,
      PRIMARY KEY (item_id, dimension)
    );
    """,
    """
    CREATE TABLE IF NOT EXISTS review_event (
      id TEXT PRIMARY KEY,
      item_id TEXT NOT NULL,
      dimension TEXT NOT NULL,
      grade INTEGER NOT NULL,
      mode_id TEXT,
      session_id TEXT,
      latency_ms INTEGER,
      at DATETIME NOT NULL
    );
    """,
    """
    CREATE TABLE IF NOT EXISTS error_event (
      id TEXT PRIMARY KEY,
      session_id TEXT,
      item_id TEXT,
      category TEXT NOT NULL,
      surface TEXT,
      expected TEXT,
      severity TEXT,
      at DATETIME NOT NULL
    );
    """,
    """
    CREATE TABLE IF NOT EXISTS session (
      id TEXT PRIMARY KEY,
      mode_id TEXT NOT NULL,
      scenario_id TEXT,
      started_at DATETIME NOT NULL,
      ended_at DATETIME,
      status TEXT,
      score TEXT,
      cost_usd REAL,
      pipeline TEXT
    );
    """,
    """
    CREATE TABLE IF NOT EXISTS transcript_turn (
      session_id TEXT NOT NULL,
      seq INTEGER NOT NULL,
      role TEXT NOT NULL,
      text TEXT,
      audio_ref TEXT,
      director_json TEXT,
      at DATETIME NOT NULL,
      PRIMARY KEY (session_id, seq)
    );
    """,
    "CREATE INDEX IF NOT EXISTS idx_skill_state_due ON skill_state(due) WHERE suspended = FALSE;",
    "CREATE INDEX IF NOT EXISTS idx_review_event_item ON review_event(item_id, dimension);",
    "CREATE INDEX IF NOT EXISTS idx_error_event_session ON error_event(session_id);",
    "CREATE INDEX IF NOT EXISTS idx_content_item_kind_band ON content_item(kind, band);",
    "CREATE INDEX IF NOT EXISTS idx_session_status ON session(status);",
]


def ensure_schema(conn: sqlite3.Connection) -> None:
    """Create the full v1 schema if absent, and record GRDB's migration marker so the
    iOS app opens the file without trying to re-run its migration."""
    for stmt in SCHEMA_STATEMENTS:
        conn.execute(stmt)
    # GRDB DatabaseMigrator bookkeeping table + our one migration id.
    conn.execute(
        "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);"
    )
    conn.execute(
        "INSERT OR IGNORE INTO grdb_migrations (identifier) VALUES (?);",
        (GRDB_MIGRATION_ID,),
    )
    conn.commit()


# --------------------------------------------------------------------------------
# Low-level upserts (idempotent by primary key)
# --------------------------------------------------------------------------------


def upsert_content_item(
    conn: sqlite3.Connection,
    *,
    item_id: str,
    kind: str,
    payload: dict[str, Any],
    band: str | None = None,
    frequency_rank: int | None = None,
    source: str | None = None,
    license_: str | None = None,
) -> None:
    conn.execute(
        """
        INSERT INTO content_item (id, language, kind, payload, band, frequency_rank, source, license)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          language=excluded.language, kind=excluded.kind, payload=excluded.payload,
          band=excluded.band, frequency_rank=excluded.frequency_rank,
          source=excluded.source, license=excluded.license;
        """,
        (
            item_id,
            LANGUAGE,
            kind,
            json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
            band,
            frequency_rank,
            source,
            license_,
        ),
    )


def upsert_link(conn: sqlite3.Connection, from_id: str, to_id: str, relation: str) -> None:
    if from_id == to_id:
        return
    conn.execute(
        "INSERT OR IGNORE INTO item_link (from_id, to_id, relation) VALUES (?, ?, ?);",
        (from_id, to_id, relation),
    )


def existing_ids(conn: sqlite3.Connection, kind: str | None = None) -> set[str]:
    if kind is None:
        rows = conn.execute("SELECT id FROM content_item;")
    else:
        rows = conn.execute("SELECT id FROM content_item WHERE kind = ?;", (kind,))
    return {r[0] for r in rows}


def update_payload(conn: sqlite3.Connection, item_id: str, mutate) -> bool:
    row = conn.execute("SELECT payload FROM content_item WHERE id = ?;", (item_id,)).fetchone()
    if row is None:
        return False
    payload = json.loads(row[0])
    mutate(payload)
    conn.execute(
        "UPDATE content_item SET payload = ? WHERE id = ?;",
        (json.dumps(payload, ensure_ascii=False, separators=(",", ":")), item_id),
    )
    return True


# --------------------------------------------------------------------------------
# Seed loader (committed tools/seed/*.json — the default app path)
# --------------------------------------------------------------------------------


def _load_seed_file(seed_dir: Path, name: str) -> list[dict[str, Any]]:
    path = seed_dir / name
    if not path.exists():
        log.warning("seed file missing, skipping: %s", path)
        return []
    with path.open(encoding="utf-8") as fh:
        data = json.load(fh)
    return data.get("items", [])


# CJK ideograph ranges (unified + extension A + compat) for kanji detection in strings.
def _is_kanji(ch: str) -> bool:
    cp = ord(ch)
    return (
        0x4E00 <= cp <= 0x9FFF
        or 0x3400 <= cp <= 0x4DBF
        or 0xF900 <= cp <= 0xFAFF
    )


def import_seed(conn: sqlite3.Connection, seed_dir: Path) -> None:
    log.info("loading committed seed curriculum from %s", seed_dir)

    vocab = _load_seed_file(seed_dir, "vocab_n5.json")
    kanji = _load_seed_file(seed_dir, "kanji_n5.json")
    grammar = _load_seed_file(seed_dir, "grammar_n5.json")
    sentences = _load_seed_file(seed_dir, "sentences_n5.json")
    cloze = _load_seed_file(seed_dir, "cloze_n5.json")
    scenarios = _load_seed_file(seed_dir, "scenarios_n5.json")
    lessons = _load_seed_file(seed_dir, "lessons_n5.json")
    patterns = _load_seed_file(seed_dir, "patterns_n5.json")

    # --- kanji ---
    kanji_by_literal: dict[str, str] = {}
    for k in kanji:
        payload = {
            "literal": k["literal"],
            "meanings": k.get("meanings", []),
            "on": k.get("on", []),
            "kun": k.get("kun", []),
            "strokes": k.get("strokes"),
        }
        upsert_content_item(
            conn, item_id=k["id"], kind="kanji", payload=payload,
            band=k.get("band"), frequency_rank=k.get("frequency_rank"),
            source=SEED_SOURCE, license_=SEED_LICENSE,
        )
        kanji_by_literal[k["literal"]] = k["id"]

    # --- vocab (+ vocab->kanji "contains" links) ---
    vocab_index: list[tuple[str, str]] = []  # (lemma, id) for sentence linking
    for v in vocab:
        payload = {
            "lemma": v["lemma"],
            "kana": v.get("kana"),
            "romaji": v.get("romaji"),
            "glosses": v.get("glosses", []),
            "pos": v.get("pos"),
        }
        upsert_content_item(
            conn, item_id=v["id"], kind="vocab", payload=payload,
            band=v.get("band"), frequency_rank=v.get("frequency_rank"),
            source=SEED_SOURCE, license_=SEED_LICENSE,
        )
        vocab_index.append((v["lemma"], v["id"]))
        # a word "contains" each seed kanji that appears in its written form
        for ch in set(v["lemma"]):
            if _is_kanji(ch) and ch in kanji_by_literal:
                upsert_link(conn, v["id"], kanji_by_literal[ch], "contains")

    # --- grammar ---
    for g in grammar:
        payload = {
            "name": g["name"],
            "slug": g["id"].split(":", 1)[-1],
            "explanation": g.get("explanation", ""),
            "examples": g.get("examples", []),
        }
        upsert_content_item(
            conn, item_id=g["id"], kind="grammar", payload=payload,
            band=g.get("band"), source=SEED_SOURCE, license_=SEED_LICENSE,
        )

    # --- sentences (+ sentence->vocab "uses" links) ---
    for s in sentences:
        payload = {
            "ja": s["ja"],
            "reading": s.get("reading"),
            "en": s.get("en"),
        }
        upsert_content_item(
            conn, item_id=s["id"], kind="sentence", payload=payload,
            band=s.get("band"), source=SEED_SOURCE, license_=SEED_LICENSE,
        )
        for lemma, vid in vocab_index:
            if lemma and lemma in s["ja"]:
                upsert_link(conn, s["id"], vid, "uses")

    # --- cloze sentences (kind=sentence, id=cloze:*; carry prompt/answer payload) ---
    for c in cloze:
        payload = {
            "prompt": c["prompt"],
            "answer": c["answer"],
            "hint": c.get("hint"),
            "full": c.get("full"),
            "en": c.get("en"),
        }
        upsert_content_item(
            conn, item_id=c["id"], kind="sentence", payload=payload,
            band=c.get("band"), source=SEED_SOURCE, license_=SEED_LICENSE,
        )

    # --- scenarios (+ scenario->target "uses" links) ---
    for sc in scenarios:
        upsert_content_item(
            conn, item_id=sc["id"], kind="scenario", payload=sc,
            band=sc.get("band"), source=SEED_SOURCE, license_=SEED_LICENSE,
        )
        for goal in sc.get("goals", []):
            for target in goal.get("target_items", []):
                upsert_link(conn, sc["id"], target, "uses")

    # --- patterns (productive rules; pattern-level SRS rows, flavor C) ---
    for pattern in patterns:
        upsert_content_item(
            conn, item_id=pattern["id"], kind="pattern", payload=pattern,
            band=pattern.get("band"), source=SEED_SOURCE, license_=SEED_LICENSE,
        )

    # --- lessons (guided voice scripts; steps reference vocab via item_ref) ---
    for lesson in lessons:
        upsert_content_item(
            conn, item_id=lesson["id"], kind="lesson", payload=lesson,
            band=lesson.get("band"), source=SEED_SOURCE, license_=SEED_LICENSE,
        )
        if lesson.get("scenario_ref"):
            upsert_link(conn, lesson["id"], lesson["scenario_ref"], "uses")
        for step in lesson.get("steps", []):
            for ref in [step.get("item_ref")] + list(step.get("item_refs", [])):
                if ref:
                    upsert_link(conn, lesson["id"], ref, "uses")

    conn.commit()
    # Prune scenario->target links whose target isn't in the DB (keep the graph clean).
    all_ids = existing_ids(conn)
    dangling = [
        (f, t, r)
        for (f, t, r) in conn.execute(
            "SELECT from_id, to_id, relation FROM item_link;"
        ).fetchall()
        if t not in all_ids
    ]
    for f, t, r in dangling:
        conn.execute(
            "DELETE FROM item_link WHERE from_id=? AND to_id=? AND relation=?;", (f, t, r)
        )
    if dangling:
        log.info("pruned %d item_link rows pointing at absent targets", len(dangling))
    conn.commit()
    log.info(
        "seed loaded: %d vocab, %d kanji, %d grammar, %d sentence (+%d cloze), %d scenario, %d lesson",
        len(vocab), len(kanji), len(grammar), len(sentences), len(cloze), len(scenarios), len(lessons),
    )


# --------------------------------------------------------------------------------
# Real-source importers (optional; each skips gracefully when its file is absent)
# --------------------------------------------------------------------------------


def import_jmdict(conn: sqlite3.Connection, path: Path, limit: int | None) -> None:
    if not path.exists():
        log.info("jmdict-simplified not present (%s) — skipping vocab import", path)
        return
    log.info("importing jmdict-simplified vocab from %s", path)
    with path.open(encoding="utf-8") as fh:
        data = json.load(fh)
    words = data.get("words", [])
    kanji_ids = existing_ids(conn, "kanji")
    count = 0
    for w in words:
        if limit is not None and count >= limit:
            break
        kanji_forms = [k["text"] for k in w.get("kanji", []) if k.get("text")]
        kana_forms = [k["text"] for k in w.get("kana", []) if k.get("text")]
        lemma = kanji_forms[0] if kanji_forms else (kana_forms[0] if kana_forms else None)
        if not lemma:
            continue
        glosses: list[str] = []
        pos: list[str] = []
        for sense in w.get("sense", []):
            glosses.extend(g["text"] for g in sense.get("gloss", []) if g.get("text"))
            pos.extend(sense.get("partOfSpeech", []))
        payload = {
            "lemma": lemma,
            "kana": kana_forms[0] if kana_forms else None,
            "kana_forms": kana_forms,
            "kanji_forms": kanji_forms,
            "glosses": glosses,
            "pos": sorted(set(pos)),
        }
        item_id = f"vocab:{lemma}"
        upsert_content_item(
            conn, item_id=item_id, kind="vocab", payload=payload,
            source="JMdict", license_="EDRDG - CC BY-SA 4.0",
        )
        for ch in set(lemma):
            kid = f"kanji:{ch}"
            if _is_kanji(ch) and kid in kanji_ids:
                upsert_link(conn, item_id, kid, "contains")
        count += 1
    conn.commit()
    log.info("jmdict: imported %d vocab entries", count)


def import_kanjidic(conn: sqlite3.Connection, path: Path, limit: int | None) -> None:
    if not path.exists():
        log.info("KANJIDIC2 not present (%s) — skipping kanji import", path)
        return
    import xml.etree.ElementTree as ET

    log.info("importing KANJIDIC2 kanji from %s", path)
    count = 0
    for _event, elem in ET.iterparse(str(path), events=("end",)):
        if elem.tag != "character":
            continue
        if limit is not None and count >= limit:
            elem.clear()
            break
        literal_el = elem.find("literal")
        if literal_el is None or not literal_el.text:
            elem.clear()
            continue
        literal = literal_el.text
        strokes_el = elem.find("./misc/stroke_count")
        strokes = int(strokes_el.text) if strokes_el is not None and strokes_el.text else None
        on: list[str] = []
        kun: list[str] = []
        meanings: list[str] = []
        for reading in elem.findall("./reading_meaning/rmgroup/reading"):
            if reading.get("r_type") == "ja_on" and reading.text:
                on.append(reading.text)
            elif reading.get("r_type") == "ja_kun" and reading.text:
                kun.append(reading.text)
        for meaning in elem.findall("./reading_meaning/rmgroup/meaning"):
            if meaning.get("m_lang") is None and meaning.text:  # default = English
                meanings.append(meaning.text)
        payload = {"literal": literal, "meanings": meanings, "on": on, "kun": kun, "strokes": strokes}
        upsert_content_item(
            conn, item_id=f"kanji:{literal}", kind="kanji", payload=payload,
            source="KANJIDIC2", license_="EDRDG - CC BY-SA 4.0",
        )
        count += 1
        elem.clear()
    conn.commit()
    log.info("kanjidic: imported %d kanji", count)


def import_kanjium_accents(conn: sqlite3.Connection, path: Path) -> None:
    if not path.exists():
        log.info("Kanjium accents.txt not present (%s) — skipping pitch attach", path)
        return
    log.info("attaching Kanjium pitch accents from %s", path)
    # Build reading/lemma -> vocab id maps from what's already in the DB.
    by_lemma: dict[str, str] = {}
    by_kana: dict[str, str] = {}
    for vid, payload_json in conn.execute(
        "SELECT id, payload FROM content_item WHERE kind='vocab';"
    ).fetchall():
        p = json.loads(payload_json)
        if p.get("lemma"):
            by_lemma.setdefault(p["lemma"], vid)
        if p.get("kana"):
            by_kana.setdefault(p["kana"], vid)
    attached = 0
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            term, reading, accent = parts[0], parts[1], parts[2]
            vid = by_lemma.get(term) or by_kana.get(reading) or by_kana.get(term)
            if not vid:
                continue
            positions = [int(x) for x in accent.replace(" ", "").split(",") if x.lstrip("-").isdigit()]
            if update_payload(conn, vid, lambda p: p.__setitem__("pitch", positions)):
                attached += 1
    conn.commit()
    log.info("kanjium accents: attached pitch to %d vocab entries", attached)


def import_kanjium_freq(conn: sqlite3.Connection, path: Path) -> None:
    if not path.exists():
        log.info("Kanjium frequency list not present (%s) — skipping rank assign", path)
        return
    log.info("assigning frequency_rank from %s", path)
    by_lemma: dict[str, str] = {}
    by_kana: dict[str, str] = {}
    for vid, payload_json in conn.execute(
        "SELECT id, payload FROM content_item WHERE kind='vocab';"
    ).fetchall():
        p = json.loads(payload_json)
        if p.get("lemma"):
            by_lemma.setdefault(p["lemma"], vid)
        if p.get("kana"):
            by_kana.setdefault(p["kana"], vid)
    ranked = 0
    with path.open(encoding="utf-8") as fh:
        for i, line in enumerate(fh, start=1):
            parts = line.rstrip("\n").split("\t")
            if not parts or not parts[0]:
                continue
            word = parts[0]
            rank = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else i
            vid = by_lemma.get(word) or by_kana.get(word)
            if not vid:
                continue
            conn.execute(
                "UPDATE content_item SET frequency_rank = ? WHERE id = ?;", (rank, vid)
            )
            ranked += 1
    conn.commit()
    log.info("kanjium freq: set frequency_rank on %d vocab entries", ranked)


def import_tatoeba(
    conn: sqlite3.Connection, path: Path, band: str | None, limit: int | None, max_len: int
) -> None:
    if not path.exists():
        log.info("Tatoeba sentences not present (%s) — skipping sentence import", path)
        return
    log.info("importing Tatoeba sentences from %s (band=%s)", path, band)
    count = 0
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            # Accept both "id<TAB>lang<TAB>text" (sentences.csv) and bare "text".
            if len(parts) >= 3:
                lang, text = parts[1], parts[2]
                if lang not in ("jpn", "ja"):
                    continue
            else:
                text = parts[0]
            if not text or len(text) > max_len:
                continue
            if limit is not None and count >= limit:
                break
            item_id = f"sentence:tatoeba_{count + 1}"
            upsert_content_item(
                conn, item_id=item_id, kind="sentence",
                payload={"ja": text, "reading": None, "en": None},
                band=band, source="Tatoeba", license_="CC BY 2.0 FR",
            )
            count += 1
    conn.commit()
    log.info("tatoeba: imported %d sentences", count)


# --------------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------------


def report_counts(conn: sqlite3.Connection) -> dict[str, int]:
    rows = conn.execute(
        "SELECT kind, COUNT(*) FROM content_item GROUP BY kind ORDER BY kind;"
    ).fetchall()
    counts = {kind: n for kind, n in rows}
    total = sum(counts.values())
    links = conn.execute("SELECT COUNT(*) FROM item_link;").fetchone()[0]
    link_rows = conn.execute(
        "SELECT relation, COUNT(*) FROM item_link GROUP BY relation ORDER BY relation;"
    ).fetchall()

    log.info("---- content_item row counts by kind ----")
    for kind in ("vocab", "grammar", "kanji", "sentence", "scenario"):
        log.info("  %-9s %d", kind, counts.get(kind, 0))
    log.info("  %-9s %d", "TOTAL", total)
    log.info("---- item_link rows: %d ----", links)
    for relation, n in link_rows:
        log.info("  %-11s %d", relation, n)
    return counts


# --------------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="import_content.py",
        description="Build the Tenpo curriculum SQLite DB (content_item / item_link).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  python3 tools/import_content.py --seed --out tools/build/tenpo_seed.sqlite\n"
            "  python3 tools/import_content.py --out tools/build/full.sqlite \\\n"
            "      --jmdict data/jmdict-eng.json --kanjidic data/kanjidic2.xml \\\n"
            "      --kanjium-accents data/accents.txt --tatoeba data/jpn_sentences.tsv\n"
        ),
    )
    p.add_argument("--out", required=True, help="Output SQLite path (created if absent).")
    p.add_argument("--seed", action="store_true", help="Load committed tools/seed/*.json (default app path).")
    p.add_argument("--seed-dir", default=None, help="Seed directory (default: tools/seed next to this script).")

    p.add_argument("--jmdict", default=None, help="jmdict-simplified JSON (vocab).")
    p.add_argument("--jmdict-limit", type=int, default=None, help="Cap JMdict entries imported.")
    p.add_argument("--kanjidic", default=None, help="KANJIDIC2 XML (kanji).")
    p.add_argument("--kanjidic-limit", type=int, default=None, help="Cap KANJIDIC2 entries imported.")
    p.add_argument("--kanjium-accents", default=None, help="Kanjium accents.txt (pitch).")
    p.add_argument("--kanjium-freq", default=None, help="Kanjium frequency list (frequency_rank).")
    p.add_argument("--tatoeba", default=None, help="Tatoeba sentences (id<TAB>lang<TAB>text).")
    p.add_argument("--tatoeba-band", default=None, help="Band tag applied to imported Tatoeba sentences.")
    p.add_argument("--tatoeba-limit", type=int, default=None, help="Cap Tatoeba sentences imported.")
    p.add_argument("--tatoeba-max-len", type=int, default=40, help="Skip Tatoeba sentences longer than this (chars).")

    p.add_argument("-v", "--verbose", action="store_true", help="Debug logging.")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(message)s",
    )

    script_dir = Path(__file__).resolve().parent
    seed_dir = Path(args.seed_dir) if args.seed_dir else (script_dir / "seed")

    did_any_source = any(
        [args.seed, args.jmdict, args.kanjidic, args.kanjium_accents, args.kanjium_freq, args.tatoeba]
    )
    if not did_any_source:
        log.error("Nothing to import. Pass --seed and/or a real-source flag (see --help).")
        return 2

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(str(out_path))
    try:
        conn.execute("PRAGMA foreign_keys = OFF;")
        ensure_schema(conn)

        if args.seed:
            import_seed(conn, seed_dir)
        # Real sources (kanji before jmdict so vocab->kanji links resolve; accents/freq last).
        if args.kanjidic:
            import_kanjidic(conn, Path(args.kanjidic), args.kanjidic_limit)
        if args.jmdict:
            import_jmdict(conn, Path(args.jmdict), args.jmdict_limit)
        if args.tatoeba:
            import_tatoeba(conn, Path(args.tatoeba), args.tatoeba_band, args.tatoeba_limit, args.tatoeba_max_len)
        if args.kanjium_accents:
            import_kanjium_accents(conn, Path(args.kanjium_accents))
        if args.kanjium_freq:
            import_kanjium_freq(conn, Path(args.kanjium_freq))

        counts = report_counts(conn)
        if sum(counts.values()) == 0:
            log.warning("No content_item rows were written.")
    finally:
        conn.close()

    log.info("wrote %s", out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
