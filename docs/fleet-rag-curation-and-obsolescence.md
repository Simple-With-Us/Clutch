# Fleet RAG Curation, Reranking & Lesson Obsolescence Protocol

## Executive Summary

This document establishes the fleet standard for curating, reranking, and retiring shared agent memory in `fleet-recall` (corpus `fleet-agents`).  As upstream frameworks, compilers, and SDKs evolve, legacy workarounds can degrade agent output.  This protocol provides exact criteria for **retiring obsolete lessons** and tuning the retrieval pipeline with hybrid search and cross-encoder reranking.

---

## 1. The Obsolescence Standard (Protocol 6-3)

A lesson in `fleet-agents` **must be retired** when:
> **An upstream framework, SDK, compiler, or toolchain release totally eliminates the underlying source of, or likely potential for, the problem described in the lesson.**

### Failure Mode of Uncurated Memory
If an agent searches for a problem (e.g. "SwiftUI ScrollView keyboard avoidance jump" or "Electron updater permission strip") and retrieves a 2-year-old workaround for a bug that Apple or upstream fixed natively in iOS 17+, the agent will waste tokens implementing fragile shims that are no longer necessary and may conflict with modern APIs.

### Metadata Schema for Lesson Lifecycle

Every lesson contributed to Fleet Recall carries lifecycle metadata:

```json
{
  "id": "22373b9d-fdd1-5eb0-83d2-cade76f76b79",
  "app": "clutch",
  "category": "lesson",
  "title": "Context image sanitization for multimodal-to-reasoning model switching",
  "status": "active",
  "created_at": "2026-09-28T14:57:37Z",
  "target_versions": {
    "deepseek_harness": ">=0.1.5",
    "ios": ">=17.0"
  },
  "obsolescence": {
    "status": "active",
    "retired_at": null,
    "eliminated_in": null,
    "elimination_proof": null,
    "superseded_by": null
  }
}
```

When an upstream release eliminates the bug:
1. Update `obsolescence.status` &rarr; `"retired"`.
2. Populate `eliminated_in` &rarr; `"iOS 17.4"` or `"dsh >= 0.2.0"`.
3. Populate `elimination_proof` &rarr; Reference the upstream release notes or commit.
4. Populate `superseded_by` &rarr; ID of the modern lesson replacing it.

---

## 2. Retrieval Pipeline: Hybrid Search + Cross-Encoder Reranking

```
User Query
   │
   ├──────────────────────────────┬──────────────────────────────┐
   ▼                              ▼                              ▼
Dense Vector Search            Sparse BM25 Search             Metadata Filter
(Semantic Intent Embeddings)   (Exact symbols, files, IDs)   (status != 'retired')
   │                              │                              │
   └──────────────────────────────┴──────────────────────────────┘
                                  │
                                  ▼
                   Reciprocal Rank Fusion (RRF)
                         (Top 20 candidates)
                                  │
                                  ▼
                     Cross-Encoder Reranker
                   (Cohere Rerank / BGE-Reranker)
                                  │
                                  ▼
                     Top 3–5 High-Precision Hits
```

### Why Vector Search Alone Fails
Vector search (cosine similarity on embedding vectors) frequently matches conceptually related topics while missing exact symbol constraints (such as `mcpServers: true`, `ClutchWindow.swift`, or specific flags).

### Two-Stage Retrieval
1. **Candidate Retrieval (RRF):** Dense search retrieves semantic context; sparse BM25 matches exact variable, file, and error identifiers.  Combined via Reciprocal Rank Fusion.
2. **Cross-Encoder Scoring:** The top 20 candidates pass through a cross-encoder model that scores deep query-passage interactions, filtering out false positives and outdated snippets.

---

## 3. Operational Rules for Agents

- **Check Before Re-Deriving:** Run `recall "<query>"` before writing substantial boilerplate or complex workarounds.
- **Retire Upstream Fixes Promptly:** When you verify that an upstream version has natively resolved an issue, mark the older lesson as retired via `recall update <id> --status retired --eliminated-in "<version>"`.
- **Minimal, High-Density Contributions:** Store actionable rules, gotchas, and architectural decisions.  Never dump conversational chat transcripts or raw build logs into the corpus.
