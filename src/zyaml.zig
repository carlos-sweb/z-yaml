//! A pure-Zig, dependency-free YAML **subset** parser/stringifier over
//! z-value's `JSValue` -- the same target type z-json builds, so YAML and
//! JSON documents interoperate freely once parsed.
//!
//! This is NOT a YAML 1.2-conformant implementation. Full YAML (anchors,
//! aliases, merge keys, tags, multi-document streams, folded/literal block
//! scalars with chomping indicators, the 1.1 boolean zoo) is a much bigger
//! project (see sibling libraries' open issue trackers for how deep that
//! rabbit hole goes). This covers the subset that shows up in the vast
//! majority of real-world config files:
//!
//! - Block mappings (`key: value`, nested by indentation) and sequences
//!   (`- item`, nested by indentation), including the common
//!   "sequence of mappings" shape (`- name: foo\n  age: 3`).
//! - Flow collections (`{a: 1, b: 2}`, `[1, 2, 3]`), JSON-style, on a
//!   single logical line (multi-line flow is out of scope).
//! - Scalars: plain, `'single-quoted'`, `"double-quoted"` (with the same
//!   escapes JSON uses: \n \t \" \\ \uXXXX).
//! - Implicit typing (YAML 1.2 *core* schema, not 1.1): `~`/`null`/empty
//!   -> null, `true`/`false` (and Title/UPPER case) -> boolean, an
//!   int/float-looking plain scalar -> number, everything else -> string.
//!   Quoted scalars are ALWAYS strings, never re-typed.
//! - `#` comments (outside quotes), blank lines, and a single `---`
//!   document-start / `...` document-end marker pair (only the first
//!   document is parsed -- see `parse`'s doc comment).
//!
//! Explicitly NOT supported (documented, not silently wrong): anchors `&`/
//! aliases `*`/merge keys `<<`, tags (`!!str`, custom `!foo`), literal `|`
//! and folded `>` block scalars, multi-document streams (beyond skipping
//! to the first `---`), complex mapping keys (`? ... : ...`), YAML 1.1
//! quirks (`yes`/`no`/`on`/`off`, sexagesimal numbers), `%YAML`/`%TAG`
//! directives, and tab-indentation (a real YAML restriction, kept here).
//! A construct that falls outside this subset is a parse error, never
//! silently misinterpreted data and never a crash.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const znumber = @import("znumber");
const JSValue = zvalue.JSValue;

pub const YamlError = error{
    /// A line mixes tabs into its leading indentation -- YAML forbids tabs
    /// for indentation (unlike inside flow collections/quoted strings).
    TabIndentation,
    /// A block scalar (`|`/`>`) was encountered -- deferred to a future
    /// version (see the module doc comment).
    UnsupportedBlockScalar,
    /// An anchor/alias/merge-key/tag marker was encountered -- deferred.
    UnsupportedFeature,
    UnexpectedToken,
    UnexpectedEnd,
    UnterminatedString,
    InvalidEscape,
    /// A block mapping/sequence's indentation doesn't line up with any
    /// enclosing level.
    BadIndentation,
    OutOfMemory,
};

// ============================================================================
// Implicit scalar typing (YAML 1.2 core schema, narrowed)
// ============================================================================

fn eqlAny(s: []const u8, comptime options: []const []const u8) bool {
    inline for (options) |o| {
        if (std.mem.eql(u8, s, o)) return true;
    }
    return false;
}

/// Strict numeric-scalar check: `[-+]?(\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?`,
/// requiring at least one digit and the ENTIRE string to match (a plain
/// scalar like "1,2,3" or "3.14abc" is a string, not a number). `.inf`/
/// `.nan` are not recognized (deferred; see module doc comment).
///
/// Cross-checked against PyYAML (YAML 1.1): everything here agrees with it
/// EXCEPT one intentional, documented divergence -- an exponent's sign is
/// OPTIONAL here (`1e10`, `1.5e10`), matching JSON/JS number-literal syntax
/// and YAML 1.2's core schema, whereas PyYAML's 1.1-based resolver requires
/// an explicit `+`/`-` after `e`/`E` (`1.5e10` resolves to a STRING in
/// PyYAML, `1.5e+10` to a float). This module targets 1.2 core, not 1.1.
fn looksLikeNumber(s: []const u8) bool {
    var i: usize = 0;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) i += 1;
    var saw_digit = false;
    var saw_dot = false;
    while (i < s.len) {
        const c = s[i];
        if (c >= '0' and c <= '9') {
            saw_digit = true;
            i += 1;
        } else if (c == '.' and !saw_dot) {
            saw_dot = true;
            i += 1;
        } else if ((c == 'e' or c == 'E') and saw_digit) {
            i += 1;
            if (i < s.len and (s[i] == '-' or s[i] == '+')) i += 1;
            const exp_start = i;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
            if (i == exp_start) return false; // exponent needs >= 1 digit
            return i == s.len and saw_digit;
        } else {
            return false;
        }
    }
    return saw_digit and i == s.len;
}

/// Types a PLAIN (unquoted) scalar per the core schema. Quoted scalars
/// never go through this -- they're always strings (handled by the
/// caller before reaching here).
fn classifyPlainScalar(allocator: Allocator, raw: []const u8) YamlError!JSValue {
    if (raw.len == 0 or eqlAny(raw, &.{ "~", "null", "Null", "NULL" })) return JSValue.NULL;
    if (eqlAny(raw, &.{ "true", "True", "TRUE" })) return JSValue.fromBool(true);
    if (eqlAny(raw, &.{ "false", "False", "FALSE" })) return JSValue.fromBool(false);
    if (looksLikeNumber(raw)) {
        // Already validated as a well-formed number by looksLikeNumber
        // above, so znumber's (JS-flavored, trailing-garbage-tolerant)
        // parseFloat is safe here -- there's no garbage left to tolerate.
        return JSValue.fromNumber(znumber.ParsingMethods.parseFloat(raw));
    }
    return JSValue.newString(allocator, raw);
}

// ============================================================================
// Shared scalar-text helpers (quoting, escapes, comment/colon scanning)
// ============================================================================

/// Decodes a double-quoted scalar's body (between the quotes), same escape
/// set as JSON: \" \\ \/ \b \f \n \r \t \uXXXX (surrogate pairs combined).
/// Returns the decoded string and how many bytes of `s` (starting at the
/// opening quote) were consumed.
fn parseDoubleQuoted(allocator: Allocator, s: []const u8) YamlError!struct { value: []u8, consumed: usize } {
    std.debug.assert(s.len > 0 and s[0] == '"');
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = 1;
    while (true) {
        if (i >= s.len) return YamlError.UnterminatedString;
        const c = s[i];
        if (c == '"') {
            i += 1;
            break;
        }
        if (c != '\\') {
            try buf.append(allocator, c);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= s.len) return YamlError.UnterminatedString;
        switch (s[i]) {
            '"' => {
                try buf.append(allocator, '"');
                i += 1;
            },
            '\\' => {
                try buf.append(allocator, '\\');
                i += 1;
            },
            '/' => {
                try buf.append(allocator, '/');
                i += 1;
            },
            'b' => {
                try buf.append(allocator, 0x08);
                i += 1;
            },
            'f' => {
                try buf.append(allocator, 0x0C);
                i += 1;
            },
            'n' => {
                try buf.append(allocator, '\n');
                i += 1;
            },
            'r' => {
                try buf.append(allocator, '\r');
                i += 1;
            },
            't' => {
                try buf.append(allocator, '\t');
                i += 1;
            },
            'u' => {
                i += 1;
                if (i + 4 > s.len) return YamlError.UnterminatedString;
                const first = std.fmt.parseInt(u16, s[i .. i + 4], 16) catch return YamlError.InvalidEscape;
                i += 4;
                var cp: u21 = first;
                if (first >= 0xD800 and first <= 0xDBFF and i + 6 <= s.len and s[i] == '\\' and s[i + 1] == 'u') {
                    const second = std.fmt.parseInt(u16, s[i + 2 .. i + 6], 16) catch 0;
                    if (second >= 0xDC00 and second <= 0xDFFF) {
                        cp = 0x10000 + (@as(u21, first - 0xD800) << 10) + (@as(u21, second - 0xDC00));
                        i += 6;
                    }
                }
                var enc_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &enc_buf) catch return YamlError.InvalidEscape;
                try buf.appendSlice(allocator, enc_buf[0..len]);
            },
            else => return YamlError.InvalidEscape,
        }
    }
    return .{ .value = try buf.toOwnedSlice(allocator), .consumed = i };
}

/// Decodes a single-quoted scalar's body: YAML's only escape inside `'...'`
/// is `''` -> a literal `'`; everything else is verbatim (no `\n`/`\t`
/// escapes here, that's what double-quotes are for).
fn parseSingleQuoted(allocator: Allocator, s: []const u8) YamlError!struct { value: []u8, consumed: usize } {
    std.debug.assert(s.len > 0 and s[0] == '\'');
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = 1;
    while (true) {
        if (i >= s.len) return YamlError.UnterminatedString;
        if (s[i] == '\'') {
            if (i + 1 < s.len and s[i + 1] == '\'') {
                try buf.append(allocator, '\'');
                i += 2;
                continue;
            }
            i += 1;
            break;
        }
        try buf.append(allocator, s[i]);
        i += 1;
    }
    return .{ .value = try buf.toOwnedSlice(allocator), .consumed = i };
}

/// Strips a trailing `# comment` from a line, respecting quotes (a `#`
/// inside `'...'`/`"..."` is data, not a comment). A comment must be at
/// the start of the (trimmed) line or preceded by whitespace, matching
/// YAML's rule that `#` mid-word is not a comment marker (`http://x#y`
/// stays intact). Returns the comment-free slice (a suffix trim of the
/// original -- no copy).
fn stripComment(line: []const u8) []const u8 {
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_single) {
            if (c == '\'') in_single = false;
            continue;
        }
        if (in_double) {
            if (c == '\\') {
                i += 1; // skip the escaped char (may be past a `"`)
            } else if (c == '"') in_double = false;
            continue;
        }
        switch (c) {
            '\'' => in_single = true,
            '"' => in_double = true,
            '#' => {
                if (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t') return line[0..i];
            },
            else => {},
        }
    }
    return line;
}

/// Finds the colon that separates a mapping key from its value at nesting
/// depth 0, outside quotes: `:` followed by whitespace or end-of-string.
/// Used for both block (`key: value`) and flow (`{key: value}`) mappings.
fn findMappingColon(s: []const u8) ?usize {
    var i: usize = 0;
    var depth: i32 = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '\'' => {
                i += 1;
                while (i < s.len and s[i] != '\'') i += 1;
                if (i < s.len) i += 1;
                continue;
            },
            '"' => {
                i += 1;
                while (i < s.len and s[i] != '"') : (i += 1) {
                    if (s[i] == '\\') i += 1;
                }
                if (i < s.len) i += 1;
                continue;
            },
            '{', '[' => depth += 1,
            '}', ']' => depth -= 1,
            ':' => {
                if (depth == 0 and (i + 1 == s.len or s[i + 1] == ' ' or s[i + 1] == '\t')) return i;
            },
            else => {},
        }
        i += 1;
    }
    return null;
}

fn trimSpaces(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

// ============================================================================
// Scalar/flow value parsing (self-contained: consumes the WHOLE input it's
// given -- flow collections are restricted to a single logical line, see
// the module doc comment)
// ============================================================================

const FlowResult = struct { value: JSValue, consumed: usize };

/// Parses one flow-context value (used inside `{}`/`[]`, and as the return
/// path for a bare `{...}`/`[...]` appearing as a whole scalar/value).
fn parseFlowValue(allocator: Allocator, s: []const u8) YamlError!FlowResult {
    const trimmed_start = blk: {
        var i: usize = 0;
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        break :blk i;
    };
    const t = s[trimmed_start..];
    if (t.len == 0) return YamlError.UnexpectedEnd;
    switch (t[0]) {
        '{' => {
            var obj = try JSValue.newObject(allocator);
            errdefer obj.deinit();
            var i: usize = 1;
            skipFlowSpace(t, &i);
            if (i < t.len and t[i] == '}') return .{ .value = obj, .consumed = trimmed_start + i + 1 };
            while (true) {
                skipFlowSpace(t, &i);
                if (i >= t.len) return YamlError.UnexpectedEnd;
                const key_r = try parseFlowScalarText(allocator, t[i..]);
                defer allocator.free(key_r.text);
                i += key_r.consumed;
                skipFlowSpace(t, &i);
                if (i >= t.len or t[i] != ':') return YamlError.UnexpectedToken;
                i += 1;
                skipFlowSpace(t, &i);
                const val = try parseFlowValue(allocator, t[i..]);
                errdefer val.value.deinit();
                i += val.consumed;
                obj.object.value.set(key_r.text, val.value) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => unreachable, // a freshly-created object is never sealed/frozen
                };
                skipFlowSpace(t, &i);
                if (i >= t.len) return YamlError.UnexpectedEnd;
                if (t[i] == ',') {
                    i += 1;
                    continue;
                }
                if (t[i] == '}') {
                    i += 1;
                    break;
                }
                return YamlError.UnexpectedToken;
            }
            return .{ .value = obj, .consumed = trimmed_start + i };
        },
        '[' => {
            var arr = try JSValue.newArray(allocator);
            errdefer arr.deinit();
            var i: usize = 1;
            skipFlowSpace(t, &i);
            if (i < t.len and t[i] == ']') return .{ .value = arr, .consumed = trimmed_start + i + 1 };
            while (true) {
                skipFlowSpace(t, &i);
                const val = try parseFlowValue(allocator, t[i..]);
                errdefer val.value.deinit();
                i += val.consumed;
                _ = try arr.array.value.push(val.value);
                skipFlowSpace(t, &i);
                if (i >= t.len) return YamlError.UnexpectedEnd;
                if (t[i] == ',') {
                    i += 1;
                    continue;
                }
                if (t[i] == ']') {
                    i += 1;
                    break;
                }
                return YamlError.UnexpectedToken;
            }
            return .{ .value = arr, .consumed = trimmed_start + i };
        },
        else => {
            const r = try parseFlowScalarText(allocator, t);
            defer allocator.free(r.text);
            const value = if (r.quoted) try JSValue.newString(allocator, r.text) else try classifyPlainScalar(allocator, r.text);
            return .{ .value = value, .consumed = trimmed_start + r.consumed };
        },
    }
}

fn skipFlowSpace(s: []const u8, i: *usize) void {
    while (i.* < s.len and (s[i.*] == ' ' or s[i.*] == '\t' or s[i.*] == '\n' or s[i.*] == '\r')) i.* += 1;
}

/// A scalar's raw text inside a flow context (or a mapping key): quoted
/// forms decode fully; a plain form runs until `,`, `]`, `}`, or a
/// mapping-separating `:`.
fn parseFlowScalarText(allocator: Allocator, s: []const u8) YamlError!struct { text: []u8, consumed: usize, quoted: bool } {
    if (s.len == 0) return YamlError.UnexpectedEnd;
    if (s[0] == '"') {
        const r = try parseDoubleQuoted(allocator, s);
        return .{ .text = r.value, .consumed = r.consumed, .quoted = true };
    }
    if (s[0] == '\'') {
        const r = try parseSingleQuoted(allocator, s);
        return .{ .text = r.value, .consumed = r.consumed, .quoted = true };
    }
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == ',' or c == ']' or c == '}') break;
        if (c == ':' and (i + 1 == s.len or s[i + 1] == ' ' or s[i + 1] == '\t' or s[i + 1] == ',' or s[i + 1] == ']' or s[i + 1] == '}')) break;
        i += 1;
    }
    const raw = trimSpaces(s[0..i]);
    return .{ .text = try allocator.dupe(u8, raw), .consumed = i, .quoted = false };
}

/// Parses a value that's either a flow collection, a quoted scalar, or a
/// plain scalar occupying the ENTIRE (already trimmed) text -- the shape a
/// block mapping's value or a sequence item's inline text takes. Trailing
/// garbage after a quoted/flow form is an error (e.g. `"a" garbage`).
fn parseWholeValue(allocator: Allocator, text: []const u8) YamlError!JSValue {
    if (text.len == 0) return JSValue.NULL;
    if (text[0] == '{' or text[0] == '[') {
        const r = try parseFlowValue(allocator, text);
        errdefer r.value.deinit();
        if (trimSpaces(text[r.consumed..]).len != 0) return YamlError.UnexpectedToken;
        return r.value;
    }
    if (text[0] == '"') {
        const r = try parseDoubleQuoted(allocator, text);
        defer allocator.free(r.value);
        if (trimSpaces(text[r.consumed..]).len != 0) return YamlError.UnexpectedToken;
        return JSValue.newString(allocator, r.value);
    }
    if (text[0] == '\'') {
        const r = try parseSingleQuoted(allocator, text);
        defer allocator.free(r.value);
        if (trimSpaces(text[r.consumed..]).len != 0) return YamlError.UnexpectedToken;
        return JSValue.newString(allocator, r.value);
    }
    if (text[0] == '|' or text[0] == '>') return YamlError.UnsupportedBlockScalar;
    if (text[0] == '&' or text[0] == '*' or text[0] == '!') return YamlError.UnsupportedFeature;
    return classifyPlainScalar(allocator, text);
}

/// A key's raw string form (quoted keys decode; plain keys are used
/// verbatim -- object keys are always strings, so a plain key's implicit
/// type, if any, is ignored, matching "object keys are strings" semantics).
fn parseKeyText(allocator: Allocator, text: []const u8) YamlError![]u8 {
    if (text.len == 0) return allocator.dupe(u8, "");
    if (text[0] == '"') {
        const r = try parseDoubleQuoted(allocator, text);
        if (trimSpaces(text[r.consumed..]).len != 0) {
            allocator.free(r.value);
            return YamlError.UnexpectedToken;
        }
        return r.value;
    }
    if (text[0] == '\'') {
        const r = try parseSingleQuoted(allocator, text);
        if (trimSpaces(text[r.consumed..]).len != 0) {
            allocator.free(r.value);
            return YamlError.UnexpectedToken;
        }
        return r.value;
    }
    return allocator.dupe(u8, text);
}

// ============================================================================
// Block layer: logical lines -> nested mappings/sequences by indentation
// ============================================================================

const Line = struct { indent: usize, text: []const u8 };

/// Splits `input` into logical lines: comment-stripped, right-trimmed,
/// blank/comment-only lines dropped, tab-indentation rejected. Stops at a
/// line that is exactly `...` (document end) or a second `---` (next
/// document's start) -- `parse()` only returns the first document (see its
/// doc comment). Slices point INTO `input` (no copies), except where a
/// comment was stripped (still just a shorter suffix, still no copy).
fn splitLines(input: []const u8) YamlError![]Line {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(std.heap.page_allocator);
    var it = std.mem.splitScalar(u8, input, '\n');
    var seen_doc_start = false;
    while (it.next()) |raw_line_cr| {
        const raw_line = if (raw_line_cr.len > 0 and raw_line_cr[raw_line_cr.len - 1] == '\r') raw_line_cr[0 .. raw_line_cr.len - 1] else raw_line_cr;
        var indent: usize = 0;
        while (indent < raw_line.len and (raw_line[indent] == ' ' or raw_line[indent] == '\t')) : (indent += 1) {
            if (raw_line[indent] == '\t') return YamlError.TabIndentation;
        }
        const after_indent = raw_line[indent..];
        const trimmed = trimSpaces(stripComment(after_indent));
        if (trimmed.len == 0) continue; // blank or comment-only
        if (std.mem.eql(u8, trimmed, "...")) break;
        if (std.mem.eql(u8, trimmed, "---")) {
            if (seen_doc_start) break; // second '---' -> next document, stop
            seen_doc_start = true;
            continue;
        }
        try lines.append(std.heap.page_allocator, .{ .indent = indent, .text = trimmed });
    }
    return lines.toOwnedSlice(std.heap.page_allocator);
}

fn startsWithDash(text: []const u8) bool {
    return text.len > 0 and text[0] == '-' and (text.len == 1 or text[1] == ' ' or text[1] == '\t');
}

/// True when `text` has a top-level, unquoted `key: value`/`key:` shape
/// (a block-mapping key line), as opposed to a bare scalar/flow value.
fn looksLikeMappingKeyLine(text: []const u8) bool {
    return findMappingColon(text) != null;
}

const BlockParser = struct {
    allocator: Allocator,
    lines: []const Line,
    idx: usize,

    /// Parses whatever sits at `lines[idx]` as long as its indent is >=
    /// `min_indent`: a sequence, a mapping, or (falling through) a single
    /// scalar/flow line. Indent < min_indent (or end of input) means an
    /// EMPTY node (`key:` with nothing under it) -> null, matching YAML.
    fn parseNode(self: *BlockParser, min_indent: usize) YamlError!JSValue {
        if (self.idx >= self.lines.len or self.lines[self.idx].indent < min_indent) return JSValue.NULL;
        const line = self.lines[self.idx];
        if (startsWithDash(line.text)) return self.parseSequence(line.indent);
        if (looksLikeMappingKeyLine(line.text)) return self.parseMapping(line.indent);
        self.idx += 1;
        return parseWholeValue(self.allocator, line.text);
    }

    fn parseSequence(self: *BlockParser, indent: usize) YamlError!JSValue {
        var arr = try JSValue.newArray(self.allocator);
        errdefer arr.deinit();
        while (self.idx < self.lines.len and self.lines[self.idx].indent == indent and startsWithDash(self.lines[self.idx].text)) {
            const line = self.lines[self.idx];
            const rest = trimSpaces(line.text[1..]);
            self.idx += 1;
            if (rest.len == 0) {
                // "- " alone: the item is a nested block at greater indent.
                const item = try self.parseNode(indent + 1);
                errdefer item.deinit();
                _ = try arr.array.value.push(item);
                continue;
            }
            // "- key: value" (sequence of mappings, ubiquitous in real
            // configs): the rest of THIS line is the mapping's first
            // entry; further entries continue on following lines aligned
            // to where that first key started (indent + 2, "- ").
            if (looksLikeMappingKeyLine(rest)) {
                const item = try self.parseMappingWithFirst(indent + 2, rest);
                errdefer item.deinit();
                _ = try arr.array.value.push(item);
                continue;
            }
            const item = try parseWholeValue(self.allocator, rest);
            errdefer item.deinit();
            _ = try arr.array.value.push(item);
        }
        return arr;
    }

    fn parseMapping(self: *BlockParser, indent: usize) YamlError!JSValue {
        var obj = try JSValue.newObject(self.allocator);
        errdefer obj.deinit();
        try self.parseMappingBody(indent, &obj);
        return obj;
    }

    /// Like `parseMapping`, but the FIRST key/value is already at hand
    /// (`first_line_rest`, the text after a sequence dash) rather than at
    /// `lines[idx]` -- used by `parseSequence`'s "- key: value" case.
    fn parseMappingWithFirst(self: *BlockParser, indent: usize, first_line_rest: []const u8) YamlError!JSValue {
        var obj = try JSValue.newObject(self.allocator);
        errdefer obj.deinit();
        try self.parseOneEntry(indent, first_line_rest, &obj);
        try self.parseMappingBody(indent, &obj);
        return obj;
    }

    fn parseMappingBody(self: *BlockParser, indent: usize, obj: *JSValue) YamlError!void {
        while (self.idx < self.lines.len and self.lines[self.idx].indent == indent and looksLikeMappingKeyLine(self.lines[self.idx].text) and !startsWithDash(self.lines[self.idx].text)) {
            const text = self.lines[self.idx].text;
            self.idx += 1;
            try self.parseOneEntry(indent, text, obj);
        }
    }

    /// Parses ONE `key: value` (or `key:` + nested block) line into `obj`.
    /// Does not itself advance `self.idx` for the key line (the caller
    /// already did, or it's a synthetic dash-derived line); DOES advance
    /// it when recursing into a nested block value.
    fn parseOneEntry(self: *BlockParser, indent: usize, text: []const u8, obj: *JSValue) YamlError!void {
        const colon = findMappingColon(text) orelse return YamlError.UnexpectedToken;
        const key_text = trimSpaces(text[0..colon]);
        const key = try parseKeyText(self.allocator, key_text);
        defer self.allocator.free(key);
        const value_text = trimSpaces(text[colon + 1 ..]);
        const value = if (value_text.len == 0)
            try self.parseNode(indent + 1)
        else
            try parseWholeValue(self.allocator, value_text);
        errdefer value.deinit();
        obj.object.value.set(key, value) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable, // a freshly-created object is never sealed/frozen
        };
    }
};

/// Parses a YAML document (the SUBSET described in this module's doc
/// comment) into a `JSValue` tree, freeable with one top-level `.deinit()`
/// like any other `JSValue` tree. Only the FIRST `---`-delimited document
/// in a multi-document stream is parsed (a real limitation, documented --
/// full multi-document support is future work).
pub fn parse(allocator: Allocator, text: []const u8) YamlError!JSValue {
    const lines = try splitLines(text);
    defer std.heap.page_allocator.free(lines);
    if (lines.len == 0) return JSValue.NULL;
    var bp = BlockParser{ .allocator = allocator, .lines = lines, .idx = 0 };
    const value = try bp.parseNode(0);
    errdefer value.deinit();
    if (bp.idx != lines.len) return YamlError.BadIndentation;
    return value;
}

// ============================================================================
// Stringify: JSValue -> block-style YAML
// ============================================================================

/// True when a plain (unquoted) scalar would round-trip unambiguously --
/// i.e. it wouldn't itself be re-typed as null/bool/number, doesn't start
/// with a YAML indicator character, and has no embedded structure-breaking
/// punctuation (`:`+space, ` #`) or leading/trailing space.
fn canBeUnquoted(s: []const u8) bool {
    if (s.len == 0) return false;
    if (eqlAny(s, &.{ "~", "null", "Null", "NULL", "true", "True", "TRUE", "false", "False", "FALSE" })) return false;
    if (looksLikeNumber(s)) return false;
    if (s[0] == ' ' or s[s.len - 1] == ' ') return false;
    switch (s[0]) {
        '-', '?', ':', ',', '[', ']', '{', '}', '#', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`' => return false,
        else => {},
    }
    if (findMappingColon(s) != null) return false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\n' or s[i] == '\t') return false;
        if (s[i] == '#' and i > 0 and s[i - 1] == ' ') return false;
    }
    return true;
}

fn writeScalarKeyOrFlowString(allocator: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    if (canBeUnquoted(s)) {
        try buf.appendSlice(allocator, s);
        return;
    }
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

fn writeScalar(allocator: Allocator, buf: *std.ArrayList(u8), value: JSValue) YamlError!void {
    switch (value) {
        .@"undefined", .@"null", .symbol, .function => try buf.appendSlice(allocator, "null"),
        .boolean => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .number => |n| {
            if (std.math.isNan(n) or std.math.isInf(n)) {
                try buf.appendSlice(allocator, "null");
            } else {
                const s = znumber.FormattingMethods.toString(n, allocator, null) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => unreachable,
                };
                defer allocator.free(s);
                try buf.appendSlice(allocator, s);
            }
        },
        .string => |box| try writeScalarKeyOrFlowString(allocator, buf, box.value.data),
        .date => |box| {
            const iso = box.value.toISOString(allocator) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return buf.appendSlice(allocator, "null"),
            };
            defer allocator.free(iso);
            try writeScalarKeyOrFlowString(allocator, buf, iso);
        },
        else => unreachable, // arrays/objects are never routed here
    }
}

fn isScalar(value: JSValue) bool {
    return switch (value) {
        .array, .object => false,
        else => true,
    };
}

fn writeIndent(allocator: Allocator, buf: *std.ArrayList(u8), depth: usize) !void {
    try buf.appendNTimes(allocator, ' ', depth * 2);
}

fn writeBlock(allocator: Allocator, buf: *std.ArrayList(u8), value: JSValue, depth: usize) YamlError!void {
    switch (value) {
        .array => |box| {
            const items = box.value.toSlice();
            if (items.len == 0) {
                try buf.appendSlice(allocator, "[]\n");
                return;
            }
            for (items) |item| {
                try writeIndent(allocator, buf, depth);
                try buf.appendSlice(allocator, "- ");
                if (isScalar(item)) {
                    try writeScalar(allocator, buf, item);
                    try buf.append(allocator, '\n');
                } else {
                    // A nested container starts right after "- " (no extra
                    // newline/indent line -- e.g. "- name: foo").
                    try writeBlockInline(allocator, buf, item, depth + 1);
                }
            }
        },
        .object => |box| {
            const keys = try box.value.keys(allocator);
            defer allocator.free(keys);
            if (keys.len == 0) {
                try buf.appendSlice(allocator, "{}\n");
                return;
            }
            for (keys) |key| {
                if (key.len > 0 and key[0] == 0) continue; // internal symbol-key encoding
                try writeIndent(allocator, buf, depth);
                try writeScalarKeyOrFlowString(allocator, buf, key);
                try buf.appendSlice(allocator, ":");
                const v = box.value.get(key).?;
                if (isScalar(v)) {
                    try buf.append(allocator, ' ');
                    try writeScalar(allocator, buf, v);
                    try buf.append(allocator, '\n');
                } else {
                    try buf.append(allocator, '\n');
                    try writeBlock(allocator, buf, v, depth + 1);
                }
            }
        },
        else => {
            try writeScalar(allocator, buf, value);
            try buf.append(allocator, '\n');
        },
    }
}

/// Writes a nested container as the value of a sequence dash: the
/// container's first line shares the "- " prefix already written; the
/// rest lines up at `depth` (which already accounts for the extra indent).
fn writeBlockInline(allocator: Allocator, buf: *std.ArrayList(u8), value: JSValue, depth: usize) YamlError!void {
    switch (value) {
        .object => |box| {
            const keys = try box.value.keys(allocator);
            defer allocator.free(keys);
            if (keys.len == 0) {
                try buf.appendSlice(allocator, "{}\n");
                return;
            }
            for (keys, 0..) |key, i| {
                if (key.len > 0 and key[0] == 0) continue;
                if (i != 0) try writeIndent(allocator, buf, depth);
                try writeScalarKeyOrFlowString(allocator, buf, key);
                try buf.appendSlice(allocator, ":");
                const v = box.value.get(key).?;
                if (isScalar(v)) {
                    try buf.append(allocator, ' ');
                    try writeScalar(allocator, buf, v);
                    try buf.append(allocator, '\n');
                } else {
                    try buf.append(allocator, '\n');
                    try writeBlock(allocator, buf, v, depth + 1);
                }
            }
        },
        .array => try writeBlock(allocator, buf, value, depth),
        else => unreachable,
    }
}

/// Serializes a `JSValue` to block-style YAML (2-space indent). The
/// inverse of `parse` for everything in this module's subset -- a value
/// built by `parse` round-trips through `stringify`+`parse` unchanged,
/// modulo comments/formatting (which YAML doesn't preserve either way).
pub fn stringify(allocator: Allocator, value: JSValue) YamlError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try writeBlock(allocator, &buf, value, 0);
    return buf.toOwnedSlice(allocator);
}
