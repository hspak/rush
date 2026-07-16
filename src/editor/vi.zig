//! Pure vi editing policy, motion, repeat, macro, and history-pattern helpers.

const std = @import("std");
const edit_buffer = @import("buffer.zig");
const key_mod = @import("key.zig");

const Key = key_mod.Key;
const KeyEvent = key_mod.Event;
const previousGraphemeStart = edit_buffer.previousGraphemeStart;
const nextGraphemeEnd = edit_buffer.nextGraphemeEnd;

pub const max_macro_depth = 16;

pub const ViState = enum {
    insert,
    command,
    replace,
};

pub const ViOperator = enum {
    change,
    delete,
    yank,
};

pub const ViFindDirection = enum {
    forward,
    backward,
};

pub const ViHistoryDirection = enum {
    backward,
    forward,
};

pub const ViFindPlacement = enum {
    on_character,
    before_character,
    after_character,
};

pub const ViFindCommand = struct {
    direction: ViFindDirection,
    placement: ViFindPlacement,
    char: u21,
};

pub const ViPending = union(enum) {
    none,
    operator: struct {
        operator: ViOperator,
        count: usize,
    },
    replace,
    find: struct {
        direction: ViFindDirection,
        placement: ViFindPlacement,
    },
    history_search: ViHistoryDirection,
    alias,
};

pub const ViMotionResult = struct {
    cursor: usize,
    inclusive: bool = false,
};

pub const ViMotionRange = struct {
    start: usize,
    end: usize,
    cursor_after_delete: usize,
};

pub const ViWordKind = enum {
    word,
    bigword,
};

pub const ViInsertPlacement = enum {
    at_cursor,
    after_cursor,
    line_start,
    line_end,
};

pub const ViInsertRepeatCapture = union(enum) {
    insert: struct {
        placement: ViInsertPlacement,
        text_count: usize,
    },
    replace_session,
    change_to_end,
    clear_line_change,
    operator_change: struct {
        motion_command: u21,
        count: usize,
    },
};

pub const ViInputRepeatMode = enum {
    insert,
    replace,
};

pub const ViInputRepeatOp = union(enum) {
    text: []u8,
    key: Key,

    pub fn deinit(self: ViInputRepeatOp, allocator: std.mem.Allocator) void {
        switch (self) {
            .text => |text| allocator.free(text),
            .key => {},
        }
    }

    pub fn changesBuffer(self: ViInputRepeatOp) bool {
        return switch (self) {
            .text => |text| text.len != 0,
            .key => |key| switch (key) {
                .backspace,
                .delete_previous_word,
                .delete_previous_argument,
                .delete_next_argument,
                .delete_to_start,
                => true,
                else => false,
            },
        };
    }
};

pub const ViInputRepeat = struct {
    ops: []ViInputRepeatOp,

    pub fn deinit(self: ViInputRepeat, allocator: std.mem.Allocator) void {
        for (self.ops) |op| op.deinit(allocator);
        allocator.free(self.ops);
    }

    pub fn changesBuffer(self: ViInputRepeat) bool {
        for (self.ops) |op| {
            if (op.changesBuffer()) return true;
        }
        return false;
    }
};

pub const ViRepeat = union(enum) {
    insert: struct {
        placement: ViInsertPlacement,
        input: ViInputRepeat,
        text_count: usize,
    },
    replace: struct {
        text: []u8,
        count: usize,
    },
    replace_session: ViInputRepeat,
    delete_forward: usize,
    delete_backward: usize,
    delete_to_end,
    change_to_end: ViInputRepeat,
    clear_line_delete,
    clear_line_change: ViInputRepeat,
    operator_delete: struct {
        motion_command: u21,
        count: usize,
    },
    operator_change: struct {
        motion_command: u21,
        count: usize,
        input: ViInputRepeat,
    },
    put_after: usize,
    put_before: usize,
    toggle_case: usize,

    pub fn deinit(self: ViRepeat, allocator: std.mem.Allocator) void {
        switch (self) {
            .insert => |repeat| repeat.input.deinit(allocator),
            .replace => |repeat| allocator.free(repeat.text),
            .replace_session => |input| input.deinit(allocator),
            .change_to_end => |input| input.deinit(allocator),
            .clear_line_change => |input| input.deinit(allocator),
            .operator_change => |repeat| repeat.input.deinit(allocator),
            .delete_forward,
            .delete_backward,
            .delete_to_end,
            .clear_line_delete,
            .operator_delete,
            .put_after,
            .put_before,
            .toggle_case,
            => {},
        }
    }
};

pub fn reverseViHistoryDirection(direction: ViHistoryDirection) ViHistoryDirection {
    return switch (direction) {
        .backward => .forward,
        .forward => .backward,
    };
}

pub fn isPortableAlphabetic(codepoint: u21) bool {
    return (codepoint >= 'A' and codepoint <= 'Z') or (codepoint >= 'a' and codepoint <= 'z');
}

pub fn viMacroKeyEvent(bytes: []const u8, index: *usize) ?KeyEvent {
    if (index.* >= bytes.len) return null;
    const start = index.*;
    const byte = bytes[start];
    index.* += 1;
    return switch (byte) {
        '\x1b' => .{ .key = .escape },
        '\r', '\n' => .{ .key = .enter },
        '\x08', '\x7f' => .{ .key = .backspace },
        else => blk: {
            if (byte >= 0x80) index.* = @min(nextCodepointEnd(bytes, start), bytes.len);
            break :blk .{ .key = .text, .text = bytes[start..index.*] };
        },
    };
}

pub fn staticHistoryStart(entry_count: usize, cursor: ?i64) usize {
    const index = cursor orelse return entry_count;
    if (index < 0) return 0;
    return @min(@as(usize, @intCast(index)), entry_count);
}

pub fn viHistoryBigword(line: []const u8, maybe_count: ?usize) ?[]const u8 {
    var last: ?[]const u8 = null;
    var ordinal: usize = 0;
    var index: usize = 0;
    while (index < line.len) {
        while (index < line.len and isAsciiWhitespace(line[index])) index += 1;
        if (index >= line.len) break;
        const start = index;
        while (index < line.len and !isAsciiWhitespace(line[index])) index += 1;
        ordinal += 1;
        const bigword = line[start..index];
        if (maybe_count) |count| {
            if (ordinal == count) return bigword;
        } else {
            last = bigword;
        }
    }
    return last;
}

pub fn viHistoryPatternMatches(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return false;
    if (pattern[0] == '^') return viHistoryPatternMatchesAt(pattern[1..], text, 0, 0);

    var text_index: usize = 0;
    while (true) {
        if (viHistoryPatternMatchesAt(pattern, text, 0, text_index)) return true;
        if (text_index >= text.len) break;
        text_index = nextCodepointEnd(text, text_index);
    }
    return false;
}

pub fn viHistoryPatternMatchesAt(pattern: []const u8, text: []const u8, pattern_index: usize, text_index: usize) bool {
    if (pattern_index == pattern.len) return true;

    switch (pattern[pattern_index]) {
        '\\' => {
            const literal_index = pattern_index + 1;
            if (literal_index >= pattern.len) {
                return text_index < text.len and
                    text[text_index] == '\\' and
                    viHistoryPatternMatchesAt(pattern, text, literal_index, text_index + 1);
            }
            return text_index < text.len and
                text[text_index] == pattern[literal_index] and
                viHistoryPatternMatchesAt(pattern, text, literal_index + 1, text_index + 1);
        },
        '*' => {
            var next_text = text_index;
            while (true) {
                if (viHistoryPatternMatchesAt(pattern, text, pattern_index + 1, next_text)) return true;
                if (next_text >= text.len) break;
                next_text = nextCodepointEnd(text, next_text);
            }
            return false;
        },
        '?' => return text_index < text.len and
            viHistoryPatternMatchesAt(pattern, text, pattern_index + 1, nextCodepointEnd(text, text_index)),
        '[' => {
            if (matchViHistoryPatternBracket(pattern, pattern_index, text, text_index)) |matched| {
                return matched.ok and
                    viHistoryPatternMatchesAt(pattern, text, matched.next_pattern, nextCodepointEnd(text, text_index));
            }
            return text_index < text.len and
                text[text_index] == '[' and
                viHistoryPatternMatchesAt(pattern, text, pattern_index + 1, text_index + 1);
        },
        else => |byte| return text_index < text.len and
            text[text_index] == byte and
            viHistoryPatternMatchesAt(pattern, text, pattern_index + 1, text_index + 1),
    }
}

pub const ViHistoryPatternBracketMatch = struct { ok: bool, next_pattern: usize };

pub fn matchViHistoryPatternBracket(
    pattern: []const u8,
    pattern_index: usize,
    text: []const u8,
    text_index: usize,
) ?ViHistoryPatternBracketMatch {
    if (text_index >= text.len) return .{ .ok = false, .next_pattern = pattern_index + 1 };
    var index = pattern_index + 1;
    if (index >= pattern.len) return null;
    const negated = pattern[index] == '!' or pattern[index] == '^';
    if (negated) index += 1;

    var matched = false;
    var saw_end = false;
    var first_expression = true;
    while (index < pattern.len) : (index += 1) {
        if (pattern[index] == ']' and !first_expression) {
            saw_end = true;
            break;
        }
        first_expression = false;

        if (matchViHistoryPatternBracketCharacterClass(pattern, index, text[text_index])) |class| {
            if (class.ok) matched = true;
            index = class.end_index;
            continue;
        }

        if (index + 2 < pattern.len and pattern[index + 1] == '-' and pattern[index + 2] != ']') {
            const start = pattern[index];
            const end = pattern[index + 2];
            if (start <= text[text_index] and text[text_index] <= end) matched = true;
            index += 2;
            continue;
        }

        if (pattern[index] == '\\' and index + 1 < pattern.len) index += 1;
        if (pattern[index] == text[text_index]) matched = true;
    }
    if (!saw_end) return null;
    return .{ .ok = if (negated) !matched else matched, .next_pattern = index + 1 };
}

pub const ViHistoryPatternBracketClassMatch = struct { ok: bool, end_index: usize };

pub fn matchViHistoryPatternBracketCharacterClass(
    pattern: []const u8,
    index: usize,
    text: u8,
) ?ViHistoryPatternBracketClassMatch {
    if (index + 3 >= pattern.len or pattern[index] != '[' or pattern[index + 1] != ':') return null;
    const name_start = index + 2;
    var name_end = name_start;
    while (name_end + 1 < pattern.len) : (name_end += 1) {
        if (pattern[name_end] == ':' and pattern[name_end + 1] == ']') {
            const ok = bracketCharacterClassMatches(pattern[name_start..name_end], text) orelse return null;
            return .{ .ok = ok, .end_index = name_end + 1 };
        }
    }
    return null;
}

pub fn bracketCharacterClassMatches(class_name: []const u8, text: u8) ?bool {
    if (std.mem.eql(u8, class_name, "alnum")) return std.ascii.isAlphanumeric(text);
    if (std.mem.eql(u8, class_name, "alpha")) return std.ascii.isAlphabetic(text);
    if (std.mem.eql(u8, class_name, "blank")) return text == ' ' or text == '\t';
    if (std.mem.eql(u8, class_name, "cntrl")) return std.ascii.isControl(text);
    if (std.mem.eql(u8, class_name, "digit")) return std.ascii.isDigit(text);
    if (std.mem.eql(u8, class_name, "graph")) return std.ascii.isGraphical(text);
    if (std.mem.eql(u8, class_name, "lower")) return std.ascii.isLower(text);
    if (std.mem.eql(u8, class_name, "print")) return std.ascii.isPrint(text);
    if (std.mem.eql(u8, class_name, "punct")) return std.ascii.isPunctuation(text);
    if (std.mem.eql(u8, class_name, "space")) return std.ascii.isWhitespace(text);
    if (std.mem.eql(u8, class_name, "upper")) return std.ascii.isUpper(text);
    if (std.mem.eql(u8, class_name, "xdigit")) return std.ascii.isHex(text);
    return null;
}

pub fn viMotion(bytes: []const u8, cursor_byte: usize, command: u21, count: usize) ?ViMotionResult {
    if (bytes.len == 0) return .{ .cursor = 0 };
    return switch (command) {
        '0' => .{ .cursor = 0 },
        '^' => .{ .cursor = firstNonBlank(bytes) },
        '$' => if (count == 1) .{ .cursor = lastGraphemeStart(bytes), .inclusive = true } else null,
        'h' => .{ .cursor = previousViCharacter(bytes, cursor_byte, count) },
        'l', ' ' => .{ .cursor = nextViCharacter(bytes, cursor_byte, count) },
        '|' => .{ .cursor = nthViCharacter(bytes, count) },
        'w' => .{ .cursor = nextViWordStartCount(bytes, cursor_byte, count, .word) },
        'W' => .{ .cursor = nextViWordStartCount(bytes, cursor_byte, count, .bigword) },
        'e' => .{ .cursor = nextViWordEndCount(bytes, cursor_byte, count, .word), .inclusive = true },
        'E' => .{ .cursor = nextViWordEndCount(bytes, cursor_byte, count, .bigword), .inclusive = true },
        'b' => .{ .cursor = previousViWordStartCount(bytes, cursor_byte, count, .word) },
        'B' => .{ .cursor = previousViWordStartCount(bytes, cursor_byte, count, .bigword) },
        else => null,
    };
}

pub fn viMotionRange(bytes: []const u8, cursor_byte: usize, motion: ViMotionResult) ViMotionRange {
    if (motion.cursor < cursor_byte) return .{
        .start = motion.cursor,
        .end = cursor_byte,
        .cursor_after_delete = motion.cursor,
    };
    const end = if (motion.inclusive) nextGraphemeEnd(bytes, motion.cursor) else motion.cursor;
    return .{ .start = cursor_byte, .end = end, .cursor_after_delete = cursor_byte };
}

pub fn viOperatorMotionRange(
    bytes: []const u8,
    cursor_byte: usize,
    operator: ViOperator,
    motion_command: u21,
    count: usize,
    motion: ViMotionResult,
) ViMotionRange {
    if (operator == .change and (motion_command == 'w' or motion_command == 'W')) {
        // Change-word ignores exclusive w/W: classic vi uses sticky end-of-word.
        return viChangeWordMotionRange(bytes, cursor_byte, motion_command, count);
    }
    if ((motion_command == 'w' or motion_command == 'W') and
        motion.cursor == lastGraphemeStart(bytes) and
        motion.cursor >= cursor_byte)
    {
        return .{ .start = cursor_byte, .end = bytes.len, .cursor_after_delete = cursor_byte };
    }
    return viMotionRange(bytes, cursor_byte, motion);
}

/// Range for `cw`/`cW`. Does not take a w/W motion: change-word is sticky
/// end-of-word (like ce/cE for the first unit), not exclusive next-word-start.
pub fn viChangeWordMotionRange(
    bytes: []const u8,
    cursor_byte: usize,
    motion_command: u21,
    count: usize,
) ViMotionRange {
    if (bytes.len == 0) return .{ .start = 0, .end = 0, .cursor_after_delete = 0 };
    // On a blank with count 1, only change the whitespace under the cursor so a
    // following run of blanks is not collapsed.
    if (count == 1 and cursor_byte < bytes.len and isAsciiWhitespace(bytes[cursor_byte])) {
        return .{
            .start = cursor_byte,
            .end = nextCodepointEnd(bytes, cursor_byte),
            .cursor_after_delete = cursor_byte,
        };
    }
    const kind: ViWordKind = if (motion_command == 'W') .bigword else .word;
    const end_cursor = changeViWordEndCount(bytes, cursor_byte, count, kind);
    return viMotionRange(bytes, cursor_byte, .{ .cursor = end_cursor, .inclusive = true });
}

/// End of the word under/after `cursor_byte` without advancing when already on
/// the word's last character (the first unit of cw/cW).
pub fn currentViWordEnd(bytes: []const u8, cursor_byte: usize, kind: ViWordKind) usize {
    if (bytes.len == 0) return 0;
    if (cursor_byte >= lastGraphemeStart(bytes)) return lastGraphemeStart(bytes);
    var cursor = cursor_byte;
    if (cursor < bytes.len and isAsciiWhitespace(bytes[cursor])) {
        while (cursor < bytes.len and isAsciiWhitespace(bytes[cursor])) cursor = nextCodepointEnd(bytes, cursor);
        if (cursor >= bytes.len) return lastGraphemeStart(bytes);
    }
    return scanToWordEnd(bytes, cursor, kind);
}

pub fn changeViWordEndCount(bytes: []const u8, cursor_byte: usize, count: usize, kind: ViWordKind) usize {
    var cursor = currentViWordEnd(bytes, cursor_byte, kind);
    var remaining = count - 1;
    while (remaining != 0) : (remaining -= 1) cursor = nextViWordEnd(bytes, cursor, kind);
    return cursor;
}

pub fn multiplyViCounts(a: usize, b: usize) usize {
    if (a != 0 and b > std.math.maxInt(usize) / a) return std.math.maxInt(usize);
    return a * b;
}

pub fn previousViCharacter(bytes: []const u8, cursor_byte: usize, count: usize) usize {
    var cursor = cursor_byte;
    var remaining = count;
    while (remaining != 0 and cursor != 0) : (remaining -= 1) cursor = previousGraphemeStart(bytes, cursor);
    return cursor;
}

pub fn nextViCharacter(bytes: []const u8, cursor_byte: usize, count: usize) usize {
    var cursor = cursor_byte;
    var remaining = count;
    while (remaining != 0 and cursor < lastGraphemeStart(bytes)) : (remaining -= 1) {
        cursor = nextGraphemeEnd(bytes, cursor);
    }
    return @min(cursor, lastGraphemeStart(bytes));
}

pub fn nthViCharacter(bytes: []const u8, count: usize) usize {
    var cursor: usize = 0;
    var remaining = count - 1;
    while (remaining != 0 and cursor < lastGraphemeStart(bytes)) : (remaining -= 1) {
        cursor = nextGraphemeEnd(bytes, cursor);
    }
    return cursor;
}

pub fn lastGraphemeStart(bytes: []const u8) usize {
    return previousGraphemeStart(bytes, bytes.len);
}

pub fn firstNonBlank(bytes: []const u8) usize {
    var cursor: usize = 0;
    while (cursor < bytes.len) : (cursor = nextCodepointEnd(bytes, cursor)) {
        if (!isAsciiWhitespace(bytes[cursor])) return cursor;
    }
    return 0;
}

pub fn nextViWordStartCount(bytes: []const u8, cursor_byte: usize, count: usize, kind: ViWordKind) usize {
    var cursor = cursor_byte;
    var remaining = count;
    while (remaining != 0) : (remaining -= 1) cursor = nextViWordStart(bytes, cursor, kind);
    return cursor;
}

pub fn nextViWordStart(bytes: []const u8, cursor_byte: usize, kind: ViWordKind) usize {
    if (cursor_byte >= lastGraphemeStart(bytes)) return lastGraphemeStart(bytes);
    var cursor = nextCodepointEnd(bytes, cursor_byte);
    if (kind == .bigword) {
        while (cursor < bytes.len and !isAsciiWhitespace(bytes[cursor])) cursor = nextCodepointEnd(bytes, cursor);
    } else if (cursor_byte < bytes.len and !isAsciiWhitespace(bytes[cursor_byte])) {
        const class = viWordClass(bytes[cursor_byte]);
        while (cursor < bytes.len and
            !isAsciiWhitespace(bytes[cursor]) and
            viWordClass(bytes[cursor]) == class) : (cursor = nextCodepointEnd(bytes, cursor))
        {}
    }
    while (cursor < bytes.len and isAsciiWhitespace(bytes[cursor])) cursor = nextCodepointEnd(bytes, cursor);
    return if (cursor >= bytes.len) lastGraphemeStart(bytes) else cursor;
}

pub fn nextViWordEndCount(bytes: []const u8, cursor_byte: usize, count: usize, kind: ViWordKind) usize {
    var cursor = cursor_byte;
    var remaining = count;
    while (remaining != 0) : (remaining -= 1) cursor = nextViWordEnd(bytes, cursor, kind);
    return cursor;
}

pub fn nextViWordEnd(bytes: []const u8, cursor_byte: usize, kind: ViWordKind) usize {
    if (cursor_byte >= lastGraphemeStart(bytes)) return lastGraphemeStart(bytes);
    var cursor = cursor_byte;
    if (cursor < bytes.len and !isAsciiWhitespace(bytes[cursor]) and viAtWordEnd(bytes, cursor, kind)) {
        cursor = nextViWordStart(bytes, cursor, kind);
    } else if (cursor < bytes.len and isAsciiWhitespace(bytes[cursor])) {
        while (cursor < bytes.len and isAsciiWhitespace(bytes[cursor])) cursor = nextCodepointEnd(bytes, cursor);
    }
    if (cursor >= bytes.len) return lastGraphemeStart(bytes);
    return scanToWordEnd(bytes, cursor, kind);
}

/// Advance from a non-blank `cursor` to the last codepoint of its word/bigword.
fn scanToWordEnd(bytes: []const u8, cursor_byte: usize, kind: ViWordKind) usize {
    var cursor = cursor_byte;
    if (kind == .bigword) {
        while (nextCodepointEnd(bytes, cursor) < bytes.len and
            !isAsciiWhitespace(bytes[nextCodepointEnd(bytes, cursor)]))
        {
            cursor = nextCodepointEnd(bytes, cursor);
        }
    } else {
        const class = viWordClass(bytes[cursor]);
        while (nextCodepointEnd(bytes, cursor) < bytes.len and
            !isAsciiWhitespace(bytes[nextCodepointEnd(bytes, cursor)]) and
            viWordClass(bytes[nextCodepointEnd(bytes, cursor)]) == class)
        {
            cursor = nextCodepointEnd(bytes, cursor);
        }
    }
    return cursor;
}

pub fn viAtWordEnd(bytes: []const u8, cursor_byte: usize, kind: ViWordKind) bool {
    const next = nextCodepointEnd(bytes, cursor_byte);
    if (next >= bytes.len) return true;
    if (isAsciiWhitespace(bytes[next])) return true;
    if (kind == .bigword) return false;
    return viWordClass(bytes[cursor_byte]) != viWordClass(bytes[next]);
}

pub fn previousViWordStartCount(bytes: []const u8, cursor_byte: usize, count: usize, kind: ViWordKind) usize {
    var cursor = cursor_byte;
    var remaining = count;
    while (remaining != 0) : (remaining -= 1) cursor = previousViWordStart(bytes, cursor, kind);
    return cursor;
}

pub fn previousViWordStart(bytes: []const u8, cursor_byte: usize, kind: ViWordKind) usize {
    if (cursor_byte == 0) return 0;
    var cursor = previousCodepointStart(bytes, cursor_byte);
    while (cursor != 0 and isAsciiWhitespace(bytes[cursor])) cursor = previousCodepointStart(bytes, cursor);
    if (kind == .bigword) {
        while (cursor != 0) {
            const previous = previousCodepointStart(bytes, cursor);
            if (isAsciiWhitespace(bytes[previous])) break;
            cursor = previous;
        }
    } else {
        const class = viWordClass(bytes[cursor]);
        while (cursor != 0) {
            const previous = previousCodepointStart(bytes, cursor);
            if (isAsciiWhitespace(bytes[previous]) or viWordClass(bytes[previous]) != class) break;
            cursor = previous;
        }
    }
    return cursor;
}

pub fn viWordClass(byte: u8) enum { word, punct } {
    return if (std.ascii.isAlphanumeric(byte) or byte == '_') .word else .punct;
}

pub fn viFind(bytes: []const u8, cursor_byte: usize, find: ViFindCommand, count: usize) ?usize {
    if (bytes.len == 0) return null;
    var cursor = cursor_byte;
    var remaining = count;
    while (remaining != 0) : (remaining -= 1) {
        cursor = switch (find.direction) {
            .forward => findCodepointForward(bytes, cursor, find.char) orelse return null,
            .backward => findCodepointBackward(bytes, cursor, find.char) orelse return null,
        };
    }
    return switch (find.placement) {
        .on_character => cursor,
        .before_character => if (cursor == 0) cursor else previousGraphemeStart(bytes, cursor),
        .after_character => @min(nextGraphemeEnd(bytes, cursor), lastGraphemeStart(bytes)),
    };
}

pub fn findCodepointForward(bytes: []const u8, cursor_byte: usize, needle: u21) ?usize {
    var cursor = nextCodepointEnd(bytes, cursor_byte);
    while (cursor < bytes.len) : (cursor = nextCodepointEnd(bytes, cursor)) {
        if (codepointAt(bytes, cursor) == needle) return cursor;
    }
    return null;
}

pub fn findCodepointBackward(bytes: []const u8, cursor_byte: usize, needle: u21) ?usize {
    if (cursor_byte == 0) return null;
    var cursor = previousCodepointStart(bytes, cursor_byte);
    while (true) {
        if (codepointAt(bytes, cursor) == needle) return cursor;
        if (cursor == 0) return null;
        cursor = previousCodepointStart(bytes, cursor);
    }
}

pub fn reverseViFind(find: ViFindCommand) ViFindCommand {
    return .{
        .direction = switch (find.direction) {
            .forward => .backward,
            .backward => .forward,
        },
        .placement = switch (find.placement) {
            .on_character => .on_character,
            .before_character => .after_character,
            .after_character => .before_character,
        },
        .char = find.char,
    };
}

pub fn firstCodepoint(bytes: []const u8) ?u21 {
    if (bytes.len == 0) return null;
    return codepointAt(bytes, 0);
}

pub fn codepointAt(bytes: []const u8, cursor_byte: usize) ?u21 {
    if (cursor_byte >= bytes.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(bytes[cursor_byte]) catch return null;
    if (cursor_byte + len > bytes.len) return null;
    return std.unicode.utf8Decode(bytes[cursor_byte .. cursor_byte + len]) catch null;
}

pub fn previousCodepointStart(bytes: []const u8, cursor_byte: usize) usize {
    var i = cursor_byte - 1;
    while (i != 0 and (bytes[i] & 0xc0) == 0x80) i -= 1;
    return i;
}

pub fn nextCodepointEnd(bytes: []const u8, cursor_byte: usize) usize {
    if (cursor_byte >= bytes.len) return bytes.len;
    const len = std.unicode.utf8ByteSequenceLength(bytes[cursor_byte]) catch return bytes.len;
    return cursor_byte + len;
}

pub fn isAsciiWhitespace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r' => true,
        else => false,
    };
}

test "currentViWordEnd is sticky on last character of word" {
    try std.testing.expectEqual(@as(usize, 0), currentViWordEnd("a b", 0, .word));
    try std.testing.expectEqual(@as(usize, 2), currentViWordEnd("a b", 2, .word));
    try std.testing.expectEqual(@as(usize, 4), currentViWordEnd("hello", 4, .word));
    try std.testing.expectEqual(@as(usize, 4), currentViWordEnd("hello", 0, .word));
    // Word class splits alnum and punctuation: "foo" then "." then "bar".
    try std.testing.expectEqual(@as(usize, 2), currentViWordEnd("foo.bar", 0, .word));
    try std.testing.expectEqual(@as(usize, 3), currentViWordEnd("foo.bar", 3, .word));
    try std.testing.expectEqual(@as(usize, 6), currentViWordEnd("foo.bar", 4, .word));
}

test "changeViWordEndCount spans additional words for counts above one" {
    try std.testing.expectEqual(@as(usize, 2), changeViWordEndCount("one two", 0, 1, .word));
    try std.testing.expectEqual(@as(usize, 6), changeViWordEndCount("one two", 0, 2, .word));
    // First unit sticky on 'a', second unit is end of 'b' (index 2).
    try std.testing.expectEqual(@as(usize, 2), changeViWordEndCount("a b c", 0, 2, .word));
    try std.testing.expectEqual(@as(usize, 4), changeViWordEndCount("a b c", 0, 3, .word));
}

test "viChangeWordMotionRange preserves blanks around the changed word" {
    const mid = viChangeWordMotionRange("one two three", 0, 'w', 1);
    try std.testing.expectEqual(@as(usize, 0), mid.start);
    try std.testing.expectEqual(@as(usize, 3), mid.end);

    const short_last = viChangeWordMotionRange("a b", 0, 'w', 1);
    try std.testing.expectEqual(@as(usize, 0), short_last.start);
    try std.testing.expectEqual(@as(usize, 1), short_last.end);

    const final_word = viChangeWordMotionRange("hello world", 6, 'w', 1);
    try std.testing.expectEqual(@as(usize, 6), final_word.start);
    try std.testing.expectEqual(@as(usize, 11), final_word.end);

    const on_blank = viChangeWordMotionRange("one  two", 3, 'w', 1);
    try std.testing.expectEqual(@as(usize, 3), on_blank.start);
    try std.testing.expectEqual(@as(usize, 4), on_blank.end);

    const two_words = viChangeWordMotionRange("one two three", 0, 'w', 2);
    try std.testing.expectEqual(@as(usize, 0), two_words.start);
    try std.testing.expectEqual(@as(usize, 7), two_words.end);
}
