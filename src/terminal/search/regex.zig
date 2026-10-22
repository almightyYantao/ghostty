//! Regular expression matching for terminal search (Wireline fork).
//!
//! The sliding window feeds this one logical (soft-wrap joined) line at a
//! time, in screen order, and maps the returned byte ranges back to cells.
//! Matches never span hard line breaks and zero-length matches are dropped
//! because a highlight cannot represent them.
const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("terminal_options");

/// Whether regex search is available in this build. libghostty-vt is built
/// without Oniguruma; there every pattern behaves like an invalid one.
pub const enabled = build_options.oniguruma;

/// A match as a half-open byte range `[start, end)` into the line.
pub const Range = struct { start: usize, end: usize };

/// Upper bound of matches reported for a single logical line. Keeps a
/// pathological pattern on a huge unwrapped line from flooding results.
pub const max_matches_per_line = 4096;

/// Oniguruma retry budget per search call (backtracking steps, not bytes).
/// Exceeding it ends matching for the line instead of hanging the search
/// thread on catastrophic patterns like `(a*)*b`.
const retry_limit = 1_000_000;

pub const Matcher = if (enabled) OniMatcher else NoMatcher;

const NoMatcher = struct {
    pub fn init(pattern: []const u8, case_sensitive: bool) ?NoMatcher {
        _ = pattern;
        _ = case_sensitive;
        return null;
    }

    pub fn deinit(self: *NoMatcher) void {
        _ = self;
    }

    pub fn findAll(
        self: *NoMatcher,
        alloc: Allocator,
        line: []const u8,
        out: *std.ArrayList(Range),
    ) Allocator.Error!void {
        _ = self;
        _ = alloc;
        _ = line;
        _ = out;
    }
};

const OniMatcher = struct {
    const oni = @import("oniguruma");

    regex: oni.Regex,
    region: oni.Region,
    param: oni.MatchParam,

    /// Compile `pattern` (Oniguruma/Ruby syntax, UTF-8). Returns null when
    /// the pattern is invalid or resources can't be allocated; callers
    /// treat that as a search with no matches.
    pub fn init(pattern: []const u8, case_sensitive: bool) ?OniMatcher {
        var regex = oni.Regex.init(
            pattern,
            .{ .ignorecase = !case_sensitive },
            oni.Encoding.utf8,
            oni.Syntax.default,
            null,
        ) catch return null;

        var param = oni.MatchParam.init() catch {
            regex.deinit();
            return null;
        };
        param.setRetryLimitInSearch(retry_limit) catch {};

        return .{ .regex = regex, .region = .{}, .param = param };
    }

    pub fn deinit(self: *OniMatcher) void {
        self.region.deinit();
        self.param.deinit();
        self.regex.deinit();
    }

    /// Append all non-empty, non-overlapping matches in `line` to `out` in
    /// order, at most `max_matches_per_line`. Matching errors (retry limit,
    /// invalid UTF-8 handling) end the line silently.
    pub fn findAll(
        self: *OniMatcher,
        alloc: Allocator,
        line: []const u8,
        out: *std.ArrayList(Range),
    ) Allocator.Error!void {
        var found: usize = 0;
        var pos: usize = 0;
        while (pos <= line.len and found < max_matches_per_line) {
            _ = self.regex.searchAdvancedWithParam(
                line,
                pos,
                line.len,
                &self.region,
                .{},
                &self.param,
            ) catch return;

            const start: usize = @intCast(self.region.starts()[0]);
            const end: usize = @intCast(self.region.ends()[0]);
            if (end > start) {
                try out.append(alloc, .{ .start = start, .end = end });
                found += 1;
                pos = end;
                continue;
            }

            // Empty match: step over one code point so `a*` or `^` can't
            // spin in place.
            if (start >= line.len) return;
            pos = start + (std.unicode.utf8ByteSequenceLength(line[start]) catch 1);
        }
    }
};

fn testFind(pattern: []const u8, case_sensitive: bool, line: []const u8) !?[]const Range {
    const alloc = std.testing.allocator;
    var m = Matcher.init(pattern, case_sensitive) orelse return null;
    defer m.deinit();
    var out: std.ArrayList(Range) = .empty;
    errdefer out.deinit(alloc);
    try m.findAll(alloc, line, &out);
    return try out.toOwnedSlice(alloc);
}

fn expectRanges(expected: []const Range, actual: ?[]const Range) !void {
    const got = actual orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(Range, expected, got);
}

test "regex matcher: multiple matches per line" {
    if (comptime !enabled) return error.SkipZigTest;
    try @import("oniguruma").testing.ensureInit();
    try expectRanges(&.{
        .{ .start = 0, .end = 8 },
        .{ .start = 9, .end = 16 },
    }, try testFind("ne+dle\\d", true, "neeedle1 needle2 needle"));
}

test "regex matcher: case flag" {
    if (comptime !enabled) return error.SkipZigTest;
    try @import("oniguruma").testing.ensureInit();
    try expectRanges(&.{.{ .start = 4, .end = 8 }}, try testFind("Foo.", true, "foo1Foo2"));
    try expectRanges(&.{
        .{ .start = 0, .end = 4 },
        .{ .start = 4, .end = 8 },
    }, try testFind("Foo.", false, "foo1Foo2"));
    // Inline option overrides the flag.
    try expectRanges(&.{
        .{ .start = 0, .end = 4 },
        .{ .start = 4, .end = 8 },
    }, try testFind("(?i)Foo.", true, "foo1Foo2"));
}

test "regex matcher: invalid pattern" {
    if (comptime !enabled) return error.SkipZigTest;
    try @import("oniguruma").testing.ensureInit();
    try std.testing.expect(try testFind("(unclosed", false, "x") == null);
    try std.testing.expect(try testFind("[z-a]", false, "x") == null);
}

test "regex matcher: empty matches are skipped and terminate" {
    if (comptime !enabled) return error.SkipZigTest;
    try @import("oniguruma").testing.ensureInit();
    try expectRanges(&.{
        .{ .start = 1, .end = 3 },
        .{ .start = 6, .end = 7 },
    }, try testFind("a*", true, "baab\xc3\xa9ab"));
    try expectRanges(&.{}, try testFind("^", true, "abc"));
    try expectRanges(&.{}, try testFind("$", true, ""));
    try expectRanges(&.{}, try testFind("\\b", true, "a b c"));
}

test "regex matcher: unicode" {
    if (comptime !enabled) return error.SkipZigTest;
    try @import("oniguruma").testing.ensureInit();
    // "héllo wörld": é and ö are two bytes each.
    try expectRanges(&.{
        .{ .start = 0, .end = 6 },
        .{ .start = 7, .end = 13 },
    }, try testFind("\\w+", true, "h\xc3\xa9llo w\xc3\xb6rld"));
    // Unicode case folding when case-insensitive.
    try expectRanges(&.{.{ .start = 0, .end = 5 }}, try testFind("\xc3\xa9t\xc3\xa9", false, "\xc3\x89t\xc3\x89"));
}

test "regex matcher: catastrophic pattern is bounded" {
    if (comptime !enabled) return error.SkipZigTest;
    try @import("oniguruma").testing.ensureInit();
    const line: [64]u8 = @splat('a');
    const got = try testFind("(a*)*b", true, &line);
    defer if (got) |g| std.testing.allocator.free(g);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(usize, 0), got.?.len);
}

// Sliding window / screen search integration tests.

const terminal = @import("../main.zig");
const point = terminal.point;
const PageList = terminal.PageList;
const Screen = terminal.Screen;
const Terminal = terminal.Terminal;
const sliding_window = @import("sliding_window.zig");
const SlidingWindow = sliding_window.SlidingWindow;
const ScreenSearch = @import("screen.zig").ScreenSearch;

fn testWindow(
    direction: anytype,
    pattern: []const u8,
    case_sensitive: bool,
) !SlidingWindow {
    try @import("oniguruma").testing.ensureInit();
    sliding_window.use_regex = true;
    defer sliding_window.use_regex = false;
    sliding_window.case_sensitive = case_sensitive;
    defer sliding_window.case_sensitive = false;
    return .init(std.testing.allocator, direction, pattern);
}

/// Expect the next window match to span active points (x0,y0)..(x1,y1).
fn expectNext(w: *SlidingWindow, pages: *const PageList, x0: u16, y0: u32, x1: u16, y1: u32) !void {
    const h = w.next() orelse return error.TestExpectedMatch;
    const sel = h.untracked();
    try std.testing.expectEqual(point.Point{ .active = .{ .x = x0, .y = y0 } }, pages.pointFromPin(.active, sel.start).?);
    try std.testing.expectEqual(point.Point{ .active = .{ .x = x1, .y = y1 } }, pages.pointFromPin(.active, sel.end).?);
}

fn testTerminal(cols: u16, text: []const u8) !Terminal {
    var t: Terminal = try .init(std.testing.io, std.testing.allocator, .{ .cols = cols, .rows = 5 });
    errdefer t.deinit(std.testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(text);
    return t;
}

const wrapped_text = "abc neeedle7 x\r\nneedle\r\nNEEDLE9 needle3";

test "regex window: soft-wrapped line, forward" {
    if (comptime !enabled) return error.SkipZigTest;
    var t = try testTerminal(10, wrapped_text);
    defer t.deinit(std.testing.allocator);
    const pages = &t.screens.active.pages;

    var w = try testWindow(.forward, "ne+dle\\d", false);
    defer w.deinit();
    _ = try w.append(pages.pages.first.?);
    try expectNext(&w, pages, 4, 0, 1, 1); // "neeedl|e7" across the wrap
    try expectNext(&w, pages, 0, 3, 6, 3); // NEEDLE9
    try expectNext(&w, pages, 8, 3, 4, 4); // "ne|edle3" across the wrap
    try std.testing.expect(w.next() == null);
    try std.testing.expect(w.next() == null);
}

test "regex window: soft-wrapped line, reverse" {
    if (comptime !enabled) return error.SkipZigTest;
    var t = try testTerminal(10, wrapped_text);
    defer t.deinit(std.testing.allocator);
    const pages = &t.screens.active.pages;

    var w = try testWindow(.reverse, "ne+dle\\d", false);
    defer w.deinit();
    _ = try w.append(pages.pages.first.?);
    try expectNext(&w, pages, 8, 3, 4, 4);
    try expectNext(&w, pages, 0, 3, 6, 3);
    try expectNext(&w, pages, 4, 0, 1, 1);
    try std.testing.expect(w.next() == null);
}

test "regex window: case sensitive" {
    if (comptime !enabled) return error.SkipZigTest;
    var t = try testTerminal(10, wrapped_text);
    defer t.deinit(std.testing.allocator);
    const pages = &t.screens.active.pages;

    var w = try testWindow(.forward, "ne+dle\\d", true);
    defer w.deinit();
    _ = try w.append(pages.pages.first.?);
    try expectNext(&w, pages, 4, 0, 1, 1);
    try expectNext(&w, pages, 8, 3, 4, 4);
    try std.testing.expect(w.next() == null);
}

test "regex window: multiple matches per line and empty matches" {
    if (comptime !enabled) return error.SkipZigTest;
    var t = try testTerminal(20, "aa b aaa\r\n\r\nb");
    defer t.deinit(std.testing.allocator);
    const pages = &t.screens.active.pages;

    inline for (.{ .forward, .reverse }) |dir| {
        var w = try testWindow(dir, "a*", true);
        defer w.deinit();
        _ = try w.append(pages.pages.first.?);
        if (dir == .forward) {
            try expectNext(&w, pages, 0, 0, 1, 0);
            try expectNext(&w, pages, 5, 0, 7, 0);
        } else {
            try expectNext(&w, pages, 5, 0, 7, 0);
            try expectNext(&w, pages, 0, 0, 1, 0);
        }
        try std.testing.expect(w.next() == null);
    }

    inline for (.{ "^", "$", "^$", "x*", "(?=a)" }) |pattern| {
        var w = try testWindow(.forward, pattern, true);
        defer w.deinit();
        _ = try w.append(pages.pages.first.?);
        try std.testing.expect(w.next() == null);
    }
}

test "regex window: invalid pattern never matches" {
    if (comptime !enabled) return error.SkipZigTest;
    var t = try testTerminal(20, "needle1 (\r\n");
    defer t.deinit(std.testing.allocator);
    const pages = &t.screens.active.pages;

    inline for (.{ .forward, .reverse }) |dir| {
        var w = try testWindow(dir, "needle(", false);
        defer w.deinit();
        try std.testing.expect(w.rx.?.matcher == null);
        _ = try w.append(pages.pages.first.?);
        try std.testing.expect(w.next() == null);
    }
}

test "regex window: unicode and wide chars" {
    if (comptime !enabled) return error.SkipZigTest;
    // 日 and 本 are wide (two cells each); é is one cell, two bytes.
    var t = try testTerminal(20, "\xe6\x97\xa5\xe6\x9c\xac n\xc3\xa9edle1 \xc3\x89T\xc3\x89");
    defer t.deinit(std.testing.allocator);
    const pages = &t.screens.active.pages;

    {
        var w = try testWindow(.forward, "n.edle\\d", true);
        defer w.deinit();
        _ = try w.append(pages.pages.first.?);
        try expectNext(&w, pages, 5, 0, 11, 0);
        try std.testing.expect(w.next() == null);
    }
    {
        var w = try testWindow(.reverse, "\xc3\xa9t\xc3\xa9", false);
        defer w.deinit();
        _ = try w.append(pages.pages.first.?);
        try expectNext(&w, pages, 13, 0, 15, 0);
        try std.testing.expect(w.next() == null);
    }
}

test "regex window: match across page boundary" {
    if (comptime !enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var s = try Screen.init(std.testing.io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("hell");
    try s.testWriteString("o, world!");
    const node = s.pages.pages.first.?;
    try std.testing.expect(node.next != null);

    {
        var w = try testWindow(.forward, "hel+o, w\\w+", true);
        defer w.deinit();
        _ = try w.append(node);
        // The line continues on the next page: not complete yet.
        try std.testing.expect(w.next() == null);
        _ = try w.append(node.next.?);
        try expectNext(&w, &s.pages, 76, 22, 7, 23);
        try std.testing.expect(w.next() == null);
    }
    {
        var w = try testWindow(.reverse, "hel+o, w\\w+", true);
        defer w.deinit();
        _ = try w.append(node.next.?);
        try std.testing.expect(w.next() == null);
        _ = try w.append(node);
        try expectNext(&w, &s.pages, 76, 22, 7, 23);
        try std.testing.expect(w.next() == null);
        // Everything matched: the window pruned all pages.
        try std.testing.expectEqual(0, w.meta.len());
    }
}

/// Fill a screen with `lines` lines "line <i> needle<i % 10>" (some
/// soft-wrapped) and return match totals for a literal and regex search.
fn screenTotals(lines: usize, needle: []const u8, use: bool, cs: bool) !usize {
    const alloc = std.testing.allocator;
    try @import("oniguruma").testing.ensureInit();

    var t: Terminal = try .init(std.testing.io, alloc, .{
        .cols = 40,
        .rows = 24,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    var buf: [128]u8 = undefined;
    const dashes: [30]u8 = @splat('-');
    for (0..lines) |i| {
        // Every 7th line is padded so "needle" wraps across rows.
        const pad: []const u8 = if (i % 7 == 0) &dashes else "";
        const nd: []const u8 = if (i % 3 == 0) "NEEDLE" else "needle";
        stream.nextSlice(try std.fmt.bufPrint(&buf, "line {d} {s}{s}{d}\r\n", .{ i, pad, nd, i % 10 }));
    }

    sliding_window.use_regex = use;
    defer sliding_window.use_regex = false;
    sliding_window.case_sensitive = cs;
    defer sliding_window.case_sensitive = false;
    var search: ScreenSearch = try .init(alloc, t.screens.active, needle);
    defer search.deinit();
    try search.searchAll();
    return search.matchesLen();
}

test "regex screen search: totals agree with literal search over scrollback" {
    if (comptime !enabled) return error.SkipZigTest;
    const n = 3000;
    const literal = try screenTotals(n, "needle", false, false);
    try std.testing.expectEqual(n, literal);
    try std.testing.expectEqual(literal, try screenTotals(n, "needle", true, false));
    try std.testing.expectEqual(literal, try screenTotals(n, "ne+dle\\d", true, false));
    // Case-sensitive: every third line is upper case.
    try std.testing.expectEqual(n - n / 3, try screenTotals(n, "needle", true, true));
    try std.testing.expectEqual(try screenTotals(n, "needle", false, true), try screenTotals(n, "needle", true, true));
    // Digit class: i % 10 == 7.
    try std.testing.expectEqual(n / 10, try screenTotals(n, "needle7", true, false));
    try std.testing.expectEqual(n / 10, try screenTotals(n, "needle[7]$", true, false));
    try std.testing.expectEqual(0, try screenTotals(n, "needle(", true, false));
    try std.testing.expectEqual(0, try screenTotals(n, "^", true, false));
}
