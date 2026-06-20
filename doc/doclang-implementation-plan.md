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
5. **Run `stack build` and `stack test pandoc:test-pandoc --ta='-p doclang'`
   after every meaningful change.**
6. **Commit DocLang logic changes separately** from upstream merges.
