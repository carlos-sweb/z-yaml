# Z-YAML

[![Zig Version](https://img.shields.io/badge/zig-0.17.0-orange.svg)](https://ziglang.org/)
[![API docs](https://img.shields.io/badge/API-Zig_docs-blue.svg)](https://carlos-sweb.github.io/z-yaml/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A **pure-Zig, dependency-free YAML *subset*** parser/stringifier over [z-value](https://github.com/carlos-sweb/z-value)'s `JSValue`, in Zig 0.17.0, part of the [z-*](https://github.com/carlos-sweb) micro-library ecosystem.

## Why a subset, and why not bind libyaml

Full YAML 1.2 is one of the largest config-format grammars in common use — indentation-sensitive block *and* flow styles, five-plus scalar forms (plain, single/double-quoted, literal `|`, folded `>`, each with its own escaping/folding rules), anchors/aliases/merge keys, tags, multi-document streams, and a surprisingly deep 1.1-vs-1.2 implicit-typing history (the "Norway problem" — `country: NO` parsing as boolean `false` under 1.1). Binding a C library like `libyaml` would get full conformance for free, but it would be the ecosystem's first non-Zig dependency and would break both the pure-Zig build and self-contained-binary story ([z-run](https://github.com/carlos-sweb/z-run)'s `-Dscript` embedding) unless vendored and compiled by `zig build` itself.

This repo instead covers the **subset that shows up in the large majority of real-world config files** — deliberately narrowed, and documented as such, rather than silently wrong on the parts it doesn't support. See "Scope" below for the exact boundary, and `src/zyaml.zig`'s module doc comment for the authoritative list.

## Scope

**Supported:**
- Block mappings (`key: value`, nested by indentation) and sequences (`- item`, nested by indentation), including the very common "sequence of mappings" shape (`- name: foo\n  age: 3`).
- Flow collections (`{a: 1, b: 2}`, `[1, 2, 3]`), JSON-style, on a single logical line.
- Scalars: plain, `'single-quoted'`, `"double-quoted"` (same escapes as JSON: `\n \t \" \\ \uXXXX`, including surrogate pairs).
- Implicit typing — YAML 1.2 **core** schema, not 1.1: `~`/`null`/empty → `null`, `true`/`false` (any of `true`/`True`/`TRUE`) → boolean, an int/float-looking plain scalar → number (via [z-number](https://github.com/carlos-sweb/z-number)), everything else → string. Quoted scalars are **always** strings, never re-typed (`"42"` stays the string `"42"`).
- `#` comments (outside quotes), blank lines, and a single `---` document-start marker (only the first document in a stream is parsed).

**Explicitly NOT supported** (a parse error, never silently misinterpreted data, never a crash):
- Anchors `&`/aliases `*`/merge keys `<<`, tags (`!!str`, custom `!foo`).
- Literal `|` and folded `>` block scalars.
- Multi-document streams (beyond skipping to the first `---`).
- Complex mapping keys (`? ... : ...`), `%YAML`/`%TAG` directives.
- YAML 1.1 quirks: `yes`/`no`/`on`/`off` as booleans, sexagesimal numbers.
- Tab-indentation (a real YAML restriction, enforced here too).

**One documented 1.1-vs-1.2 divergence, verified against PyYAML:** an exponent's sign is optional here (`1e10`, `1.5e10` parse as numbers), matching JSON/JS number-literal syntax and YAML 1.2's core schema. PyYAML's 1.1-based resolver requires an explicit `+`/`-` after `e`/`E` (`1.5e10` resolves to a *string* in PyYAML; `1.5e+10` to a float in both). Everything else was cross-checked byte-for-byte against PyYAML's `safe_load` + `json.dumps`, including a docker-compose-shaped config.

## Design

- **`parse(allocator, text) YamlError!JSValue`** — a two-layer parser: a line-based block layer (indentation → nested mappings/sequences) delegates to a JSON-shaped flow-value parser for `{...}`/`[...]` and quoted scalars. The returned tree is a normal `JSValue` tree — free it with one top-level `.deinit()`, same as z-json's `parse()`.
- **`stringify(allocator, value) YamlError![]u8`** — writes block-style YAML (2-space indent); a string is quoted only when needed to round-trip unambiguously (a string that looks like a number/bool/null, starts with a YAML indicator character, or contains a `key:`-shaped colon gets quoted).
- **`YamlError`**: `TabIndentation`, `UnsupportedBlockScalar`, `UnsupportedFeature`, `UnexpectedToken`, `UnexpectedEnd`, `UnterminatedString`, `InvalidEscape`, `BadIndentation`, `OutOfMemory`.

## Usage

```zig
const zyaml = @import("zyaml");

var doc = try zyaml.parse(allocator,
    \\name: app
    \\server:
    \\  host: localhost
    \\  port: 8080
    \\tags:
    \\  - web
    \\  - prod
);
defer doc.deinit();
// doc.object.value.get("server").?.object.value.get("port").?.number == 8080

const out = try zyaml.stringify(allocator, doc);
defer allocator.free(out);
```

## Dependencies and validation

Requires Zig 0.17.0 or newer. `zvalue` and `znumber` are downloaded from
GitHub release `v0.1.0`, with URLs and package hashes pinned in `build.zig.zon`.
All transitive dependencies are fetched from GitHub; sibling checkouts and
symlink setup are no longer required.

```sh
zig build test --summary all
```

The reviewed `z-value` contract preserves `newString`, `newArray`, `newObject`
and explicit `retain`/`deinit` ownership. Constructors clean up their own
payloads on allocation failure, and `deinit` releases nested values iteratively.
Raw container APIs still leave ownership with the caller on error; the parser's
private `setOwned` helper follows that convention and releases replaced values.
The new `JSValue.objectSet` wrapper instead consumes its argument even on error;
it must not be combined with a caller's `errdefer` for the same reference.

## Roadmap

- **v2**: literal `|` / folded `>` block scalars with basic chomping, multi-document streams (return an array of documents).
- **v3 (optional)**: anchors/aliases/merge keys — the real jump toward full conformance.

## License

MIT

## API documentation

[Browse the generated Zig API documentation](https://carlos-sweb.github.io/z-yaml/).

Generate the same documentation locally with Zig 0.17.0:

```sh
zig build docs
python3 -m http.server 8000 --directory zig-out/docs
```

Open `http://localhost:8000/` to browse it. GitHub Actions runs the tests,
generates the native Zig docs, and publishes `zig-out/docs` to GitHub Pages
automatically on every push to `master`. Pull requests also validate tests
and documentation generation.
