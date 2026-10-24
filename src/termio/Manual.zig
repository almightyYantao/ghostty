//! Manual is a termio backend where the embedder owns the pty (or any
//! other byte transport). Ghostty does not spawn a child process, does not
//! read or write a file descriptor, and does not inject shell integration.
//!
//! Data flow:
//!
//!   - Child output: the embedder calls `feed` (any thread). Bytes are copied
//!     into a pending buffer and parsed by a dedicated "io-feed" thread through
//!     `Termio.processOutput`, which is the same lock + parse path the exec
//!     read thread uses. A dedicated thread (rather than the caller's thread)
//!     is required because parsing can block on the app mailbox, which only
//!     the embedder's main thread drains; parsing on the main thread could
//!     deadlock.
//!
//!   - Bytes for the child (key encodings, pastes, query replies, mouse and
//!     focus reports, ...): everything that would be written to the pty is
//!     handed to `write_cb` from the termio IO thread.
//!
//!   - Grid size changes: reported via `resize_cb`, deduplicated, from the
//!     thread that resizes the terminal (IO thread, or the caller of
//!     ghostty_surface_new for the initial size) while the terminal lock is
//!     held, so a SIGWINCH redraw fed back afterwards is parsed against the
//!     new size (same ordering guarantee as the exec backend).
//!
//!   - Exit: the embedder calls `exited` (any thread). It is delivered after
//!     all previously fed bytes are parsed and produces the normal
//!     child_exited surface message.
//!
//!   - Snapshots: `restore` (a terminal snapshot through READY) and
//!     `restoreHistory` (whole history records after it) go through the same
//!     queue as fed bytes, so they apply exactly between the bytes fed before
//!     and after them. This is how an embedder whose pty lives in another
//!     process (a session agent) attaches: restore the agent's snapshot, then
//!     feed the output that followed the snapshot cut.
//!
//! Callbacks must not block for long and must not call back into the
//! ghostty_surface_* API synchronously (the terminal lock may be held).
const Manual = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

const log = std.log.scoped(.io_manual);

pub const WriteFn = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void;
pub const ResizeFn = *const fn (?*anyopaque, u16, u16, u32, u32) callconv(.c) void;

pub const Config = struct {
    userdata: ?*anyopaque = null,
    write_cb: ?WriteFn = null,
    resize_cb: ?ResizeFn = null,
};

/// Heap allocated so its address is stable: the Backend union holding us
/// is copied by value into Termio.
shared: *Shared,

const Shared = struct {
    alloc: Allocator,
    config: Config,

    /// Protects everything below.
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,

    /// Work fed but not yet done, in order: bytes to parse and snapshot
    /// pieces to apply. Consecutive feeds coalesce into one bytes item.
    pending: std.ArrayList(Item) = .empty,

    /// Exit code reported by the embedder, delivered after pending bytes.
    exit_code: ?u32 = null,
    quit: bool = false,

    /// Set once the exit was delivered; writes are dropped afterwards,
    /// matching the exec backend.
    exited: std.atomic.Value(bool) = .init(false),

    start: std.Io.Timestamp,
    feed_thread: ?std.Thread = null,

    /// Last size reported to resize_cb (deduplication). Only touched by
    /// the resizing thread, which is serialized by the terminal lock.
    last_size: ?[4]u32 = null,
};

/// One unit of queued work for the feed thread.
const Item = union(enum) {
    bytes: std.ArrayList(u8),
    /// A snapshot from its envelope through READY (owned).
    restore: []u8,
    /// Whole snapshot records after READY (owned).
    history: []u8,

    fn deinit(self: *Item, alloc: Allocator) void {
        switch (self.*) {
            .bytes => |*b| b.deinit(alloc),
            .restore, .history => |b| alloc.free(b),
        }
    }
};

pub fn init(alloc: Allocator, cfg: Config) !Manual {
    const shared = try alloc.create(Shared);
    shared.* = .{
        .alloc = alloc,
        .config = cfg,
        .start = .now(global.io(), .awake),
    };
    return .{ .shared = shared };
}

pub fn deinit(self: *Manual) void {
    const s = self.shared;
    // threadExit joins the feed thread; if the IO thread never started
    // there is no thread to join.
    for (s.pending.items) |*item| item.deinit(s.alloc);
    s.pending.deinit(s.alloc);
    s.alloc.destroy(s);
}

pub fn initTerminal(self: *Manual, term: *terminal.Terminal) void {
    // Report the initial size so the embedder can size its pty before
    // starting the child.
    self.resize(.{
        .columns = term.cols,
        .rows = term.rows,
    }, .{
        .width = term.width_px,
        .height = term.height_px,
    }) catch unreachable;
}

pub fn threadEnter(
    self: *Manual,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;
    const s = self.shared;
    s.feed_thread = try std.Thread.spawn(.{}, feedMain, .{ s, io, td.surface_mailbox });
    s.feed_thread.?.setName(global.io(), "io-feed") catch {};
    td.backend = .{ .manual = .{} };
}

pub fn threadExit(self: *Manual, td: *termio.Termio.ThreadData) void {
    _ = td;
    const s = self.shared;
    {
        s.mutex.lockUncancelable(global.io());
        defer s.mutex.unlock(global.io());
        s.quit = true;
        s.cond.signal(global.io());
    }
    if (s.feed_thread) |t| t.join();
    s.feed_thread = null;
}

pub fn focusGained(
    self: *Manual,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    // No termios polling: password-input detection is the embedder's job.
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *Manual,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    const s = self.shared;
    const size: [4]u32 = .{
        grid_size.columns,
        grid_size.rows,
        screen_size.width,
        screen_size.height,
    };
    if (s.last_size) |last| if (std.mem.eql(u32, &last, &size)) return;
    s.last_size = size;

    const cb = s.config.resize_cb orelse return;
    cb(
        s.config.userdata,
        grid_size.columns,
        grid_size.rows,
        screen_size.width,
        screen_size.height,
    );
}

pub fn queueWrite(
    self: *Manual,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = td;
    const s = self.shared;
    if (s.exited.load(.acquire)) return;
    const cb = s.config.write_cb orelse return;
    if (data.len == 0) return;

    if (!linefeed or std.mem.indexOfScalar(u8, data, '\r') == null) {
        cb(s.config.userdata, data.ptr, data.len);
        return;
    }

    // Linefeed mode (LNM): \r becomes \r\n, as in the exec backend.
    var buf: std.ArrayList(u8) = try .initCapacity(alloc, data.len + 16);
    defer buf.deinit(alloc);
    for (data) |ch| {
        try buf.append(alloc, ch);
        if (ch == '\r') try buf.append(alloc, '\n');
    }
    cb(s.config.userdata, buf.items.ptr, buf.items.len);
}

pub fn childExitedAbnormally(
    self: *Manual,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

pub fn getProcessInfo(self: *Manual, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    // The embedder owns the process; it can answer these itself.
    _ = self;
    return null;
}

/// Queue child output for parsing. Thread-safe, never blocks on parsing.
pub fn feed(self: *Manual, data: []const u8) void {
    if (data.len == 0) return;
    const s = self.shared;
    s.mutex.lockUncancelable(global.io());
    defer s.mutex.unlock(global.io());
    if (s.exit_code != null or s.quit) return;
    appendBytes(s, data) catch |err| {
        log.err("dropping {d} fed bytes err={}", .{ data.len, err });
        return;
    };
    s.cond.signal(global.io());
}

fn appendBytes(s: *Shared, data: []const u8) !void {
    if (s.pending.items.len > 0) {
        const last = &s.pending.items[s.pending.items.len - 1];
        if (last.* == .bytes) return last.bytes.appendSlice(s.alloc, data);
    }
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(s.alloc);
    try bytes.appendSlice(s.alloc, data);
    try s.pending.append(s.alloc, .{ .bytes = bytes });
}

/// Queue a snapshot (envelope through READY) to replace the terminal's
/// state, in order with fed bytes. Thread-safe.
pub fn restore(self: *Manual, data: []const u8) void {
    self.queueSnapshot(.restore, data);
}

/// Queue whole snapshot history records (after READY) to prepend to the
/// scrollback restored by `restore`, in order with fed bytes. Thread-safe.
pub fn restoreHistory(self: *Manual, data: []const u8) void {
    self.queueSnapshot(.history, data);
}

fn queueSnapshot(self: *Manual, comptime kind: std.meta.Tag(Item), data: []const u8) void {
    if (data.len == 0) return;
    const s = self.shared;
    const copy = s.alloc.dupe(u8, data) catch |err| {
        log.err("dropping {d}-byte snapshot piece err={}", .{ data.len, err });
        return;
    };
    s.mutex.lockUncancelable(global.io());
    defer s.mutex.unlock(global.io());
    if (s.exit_code != null or s.quit) {
        s.alloc.free(copy);
        return;
    }
    s.pending.append(s.alloc, @unionInit(Item, @tagName(kind), copy)) catch |err| {
        log.err("dropping {d}-byte snapshot piece err={}", .{ data.len, err });
        s.alloc.free(copy);
        return;
    };
    s.cond.signal(global.io());
}

/// Report that the child exited. Thread-safe. Only the first call counts.
pub fn exited(self: *Manual, exit_code: u32) void {
    const s = self.shared;
    s.mutex.lockUncancelable(global.io());
    defer s.mutex.unlock(global.io());
    if (s.exit_code != null) return;
    s.exit_code = exit_code;
    s.cond.signal(global.io());
}

fn feedMain(
    s: *Shared,
    io: *termio.Termio,
    surface_mailbox: @import("../apprt.zig").surface.Mailbox,
) void {
    // Double buffer: work through one while the embedder appends to the other.
    var local: std.ArrayList(Item) = .empty;
    defer {
        for (local.items) |*item| item.deinit(s.alloc);
        local.deinit(s.alloc);
    }
    var exit_sent = false;

    s.mutex.lockUncancelable(global.io());
    defer s.mutex.unlock(global.io());
    while (true) {
        while (!s.quit and s.pending.items.len == 0 and
            (s.exit_code == null or exit_sent))
        {
            s.cond.waitUncancelable(global.io(), &s.mutex);
        }
        if (s.quit) return;

        if (s.pending.items.len > 0) {
            std.mem.swap(std.ArrayList(Item), &local, &s.pending);
            s.mutex.unlock(global.io());
            for (local.items) |*item| {
                switch (item.*) {
                    .bytes => |b| io.processOutput(b.items),
                    .restore => |b| io.restoreSnapshot(b),
                    .history => |b| io.restoreSnapshotHistory(b),
                }
                item.deinit(s.alloc);
            }
            local.clearRetainingCapacity();
            s.mutex.lockUncancelable(global.io());
            continue;
        }

        if (s.exit_code) |code| if (!exit_sent) {
            exit_sent = true;
            s.exited.store(true, .release);
            const runtime_ms: u64 = @intCast(@max(
                0,
                s.start.untilNow(global.io(), .awake).toMilliseconds(),
            ));
            s.mutex.unlock(global.io());
            log.debug("embedder reported exit status={} runtime={}ms", .{ code, runtime_ms });
            _ = surface_mailbox.push(.{ .child_exited = .{
                .exit_code = code,
                .runtime_ms = runtime_ms,
            } }, .{ .forever = {} });
            s.mutex.lockUncancelable(global.io());
        };
    }
}

/// Termio thread data for the manual backend (all state lives in Shared).
pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};
