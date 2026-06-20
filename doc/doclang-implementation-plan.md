# DocLang Implementation Plan

## Merge Strategy

We fork pandoc to add rich DocLang support. To keep upstream merges simple, we
never touch `pandoc-types` and minimize changes to shared pandoc files.

### Files we touch once and never again (low conflict risk):

| File | Change |
|---|---|
| `src/Text/Pandoc/Writers.hs` | Add `writeDocLang` import, export, and `("doclang", ...)` entry |
| `src/Text/Pandoc/Extensions.hs` | Add `getDefaultExtensions "doclang"` and `getAll "doclang"` |
| `pandoc.cabal` | Add module and template data-file |
| `test/Tests/Old.hs` | Add `"doclang"` to test group |

### Files that may conflict on upstream merge:

- `MANUAL.txt` — upstream edits frequently; we add a format entry and link.
- `src/Text/Pandoc/Writers/Shared.hs` — we add `isSimpleContent`; occasionally
  touched upstream.

### Files where all DocLang logic lives (no upstream conflict):

- `src/Text/Pandoc/Readers/DocLang.hs`
- `src/Text/Pandoc/Writers/DocLang.hs`
- `data/templates/default.doclang`
- `test/writer.doclang`
- `test/tables.doclang`

## Encoding DocLang Extras in the Pandoc AST

We store DocLang-specific data on existing AST fields — **no changes to
pandoc-types**.

### Attr key-value pairs

Pandoc's `Attr :: (Text, [Text], [(Text, Text)])` has a freeform key-value
list. We use it to carry DocLang element-head properties through the AST:

| DocLang feature | Attr kv-pair |
|---|---|
| `<location>` | `("x1","60"), ("y1","260"), ("x2","440"), ("y2","270")` |
| `<label value="Python"/>` | `("label","Python")` |
| `<thread thread_id="42"/>` | `("thread","42")` |
| `<layer value="1"/>` | `("layer","1")` |
| `<marker>text</marker>` | `("marker","text")` |
| `<checkbox class="selected"/>` | `("checkbox","selected")` |
| `<href uri="..."/>` | `("href","...")` |
| Colspan/rowspan in cells | `("colspan","2")`, `("rowspan","3")` |
| `<caption>` (element head) | `("caption","...")` |

Every existing pandoc reader/writer ignores unknown kv-pairs — zero
regressions.

### Div/Span classes for structural wrappers

| DocLang | AST node | Class |
|---|---|---|
| `<field_region>` | `Div` | `"field_region"` |
| `<field_item>` | `Div` | `"field_item"` |
| `<field_heading>` | `Header` | `"field_heading"` |
| `<key>` | `Span` | `"key"` |
| `<value>` | `Span` | `"value"` / `"value:fillable"` |
| `<hint>` | `Span` | `"hint"` |
| `<group>` | `Div` | `"group"` |
| `<page_header>` | `Div` | `"page_header"` |
| `<page_footer>` | `Div` | `"page_footer"` |

### RawInline / RawBlock for unmappable constructs

Only for things with no AST equivalent. Format `"doclang"`:

- `<custom>...</custom>` — arbitrary metadata
- `<page_break/>` — when it carries continuation markers
- `<field_region>` boundary markers (minimize raw blocks — prefer Div)

## Implementation Order

### Phase 1: Baseline semantic subset (done)

Reader and Writer handle all standard block/inline types. Tests pass. This is
the current state of `feature/doclang`.

### Phase 2: Element heads

- **Reader**: Parse `<label>`, `<location>`, `<thread>`, `<layer>`, `<href>`,
  `<caption>`, `<custom>` from element heads and store as `Attr` kv-pairs on
  the generated AST nodes.
- **Writer**: Read `Attr` kv-pairs from AST nodes and emit the corresponding
  element-head elements.

### Phase 3: Rich OTSL tables

- Add support for `<lcel>` (colspan), `<ucel>` (rowspan), `<xcel>` (cross
  span), `<rhed>` (row header), `<corn>` (corner cell).
- Use `(colspan,N)` / `(rowspan,N)` kv-pairs on cell attributes.
- Emit `<srow/>` for section-row headers.

### Phase 4: Lists with markers

- **Reader**: Parse `<marker>` and `<checkbox>` in list items; store marker
  text and checkbox state in `Attr` kv-pairs.
- **Writer**: Emit `<marker>` and `<checkbox>` from `Attr` kv-pairs.

### Phase 5: Fields / forms

- **Reader**: Recognize `<field_region>` → `Div class="field_region"` with
  nested `<field_item>` → `Div class="field_item"`, `<key>` → `Span
  class="key"`, `<value>` → `Span class="value"`.
- **Writer**: Emit field elements from `Div`/`Span` with matching classes.

### Phase 6: Layout and pages

- Map `<page_break/>` to `HorizontalRule` with `Attr` marker (so it
  round-trips).
- Handle `<thread>` for cross-page content threading.
- Support `<default_resolution>` in template.

### Phase 7: Polish

- `<handwriting>`, `<rtl>` formatting elements.
- `<index>` structure.
- Full golden test coverage for all phase 2-6 features.
- Performance benchmarking.

## Agent Instructions

When working on this codebase, you must:

1. **Read this document first** before making any changes to the DocLang
   reader or writer.
2. **Never modify pandoc-types.** All DocLang-specific data must live in
   `Attr` kv-pairs, `Div`/`Span` classes, or `RawBlock`/`RawInline` with
   format `"doclang"`.
3. **Never touch shared files** (`Writers.hs`, `Readers.hs`,
   `Extensions.hs`, `pandoc.cabal`, `Tests/Old.hs`) except as listed in the
   merge strategy above. If an addition is needed, add at the end of the
   existing list to minimize diff.
4. **Keep the Writer and Reader symmetric** — if the Writer emits something,
   the Reader must parse it and vice versa.
5. **Build with `-Werror` to catch CI failures early.** The CI pipeline uses
   `--ghc-option=-Werror`. Always run:
   ```
   stack build --fast --ghc-options='-Werror'
   ```
   before committing. A plain `stack build` may succeed while CI fails.
6. **Run doclang tests after every change:**
   ```
   stack test pandoc:test-pandoc --ta='-p doclang'
   ```
7. **Validate against official DocLang XSD/Schematron after every meaningful change:**
   ```
   bash test/validate-doclang.sh
   ```
   Requires Python `doclang` package (`pip install doclang`).
8. **Commit DocLang logic changes separately** from upstream merges.

## Work Tracker

Status legend: `[ ]` = not started, `[~]` = in progress, `[x]` = done.

### Phase 1: Baseline semantic subset (done)

| Status | Item |
|--------|------|
| [x] | Writer: text, heading, list, table, code, formula, picture, footnote |
| [x] | Reader: same elements |
| [x] | XML safety: escaping, CDATA, namespace |
| [x] | Template with head metadata |
| [x] | Ordered list `class="ordered"` attribute |
| [x] | `<page_break/>` for `HorizontalRule` and round-trip |
| [x] | Block `<formula>` → `DisplayMath`, inline → `InlineMath` |
| [x] | `<picture class>` attribute round-trip |
| [x] | `<head>` whitespace-tolerant parsing |
| [x] | CI: build with `-Werror`, no unused imports, no shadowing |
| [x] | Test suite: 8 golden tests (writer basic, tables, formulas, pictures, lists, code, pagebreak, reader) |
| [x] | Official XSD/Schematron validation passing for all output |

### Phase 2: Element heads (via Attr kv-pairs)

| Status | Priority | Item | Notes |
|--------|----------|------|-------|
| [ ] | High | `<label>` round-trip | Store in Attr classes/kv, emit in element head |
| [ ] | High | `<location>` round-trip | Store as x1,y1,x2,y2 kv-pairs |
| [ ] | Medium | `<thread>` round-trip | thread_id as kv-pair |
| [ ] | Medium | `<layer>` round-trip | layer value as kv-pair |
| [ ] | Medium | `<caption>` in element heads | Already handled in tables/figures, generalize |
| [ ] | Low | `<custom>` round-trip | Custom metadata as RawBlock |
| [ ] | Medium | `<href>` in element heads | Currently inline `text (url)`, move to element head |
| [ ] | Low | `<xref>` round-trip | Cross-reference by thread_id |

### Phase 3: Rich lists

| Status | Priority | Item | Notes |
|--------|----------|------|-------|
| [ ] | Medium | `<marker>` round-trip | Store marker text in Attr kv-pairs |
| [ ] | Medium | `<checkbox>` round-trip | Store selected/unselected in Attr classes |
| [ ] | Low | List markers from Pandax AST | Pandoc has no marker concept, use RawBlock |

### Phase 4: Rich OTSL tables

| Status | Priority | Item | Notes |
|--------|----------|------|-------|
| [ ] | Medium | `<srow/>` support | Section row headers in OTSL |
| [ ] | Medium | `<lcel/>` (colspan) | Use `(colspan,N)` kv-pairs on cells |
| [ ] | Medium | `<ucel/>` (rowspan) | Use `(rowspan,N)` kv-pairs on cells |
| [ ] | Low | `<rhed/>` (row header) | Row-header cells |
| [ ] | Low | `<corn/>` (corner cell) | Corner cell in header |
| [ ] | Low | `<xcel/>` (cross span) | Combined colspan+rowspan |
| [ ] | Medium | `<caption>` extraction in reader | Extract caption from table element head |
| [ ] | Medium | `<footnote>` block content in reader | Currently only parses inline |

### Phase 5: Fields / forms

| Status | Priority | Item | Notes |
|--------|----------|------|-------|
| [ ] | Low | `<field_region>` | Map to `Div class="field_region"` |
| [ ] | Low | `<field_item>` | Map to `Div class="field_item"` |
| [ ] | Low | `<key>`, `<value>`, `<field_heading>` | Map to `Span` with classes |
| [ ] | Low | `<hint>` | Map to `Span class="hint"` |

### Phase 6: Layout and pages

| Status | Priority | Item | Notes |
|--------|----------|------|-------|
| [ ] | Low | `<page_break/>` only as direct child | Currently emitted for HR anywhere |
| [ ] | Low | `<page_header>`, `<page_footer>` | Template-level elements |
| [ ] | Low | `<default_resolution>` in template | Document head |
| [ ] | Low | `<thread>` for cross-page content | Multi-page document support |
| [ ] | Low | `<group>` container element | Div-like grouping |

### Phase 7: Polish

| Status | Priority | Item | Notes |
|--------|----------|------|-------|
| [ ] | Low | `<handwriting>` formatting | Span with handwriting class |
| [ ] | Low | `<rtl>` formatting | Right-to-left text |
| [ ] | Low | `<index>` structure | OTSL-based index |
| [ ] | Low | `<tabular>` chart data | Structured chart data inside picture |
| [ ] | Low | `<smallcaps>` → unwrap | Spec has no smallcaps, currently unwrapped OK |

### CI / QA

| Status | Priority | Item | Notes |
|--------|----------|------|-------|
| [ ] | High | Auto-run `validate-doclang.sh` in CI | Integrate into GitHub Actions |
| [ ] | Medium | Round-trip property test | Random DocLang → read → write → validate |
| [ ] | Low | Fuzz testing | Generate random AST, write, validate |
