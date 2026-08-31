//! Pure semantic interpretation of completion manifests.

const std = @import("std");

pub const Word = struct {
    text: []const u8,
    start: usize,
    end: usize,
};

pub const Semantic = struct {
    operand_index: usize,
    options_terminated: bool,
    complete_options: bool = false,
    complete_subcommands: bool = false,
    option_value_provider: ?std.json.Value = null,
};

pub fn semanticContext(
    words: []const Word,
    current_word_index: ?usize,
    prefix: []const u8,
    command_word_index: usize,
    root_command: std.json.Value,
) Semantic {
    var operand_index: usize = 0;
    var options_terminated = false;
    var pending_option: ?std.json.Value = null;
    var pending_value_index: usize = 0;
    var command = root_command;
    var command_path: [16]std.json.Value = undefined;
    command_path[0] = command;
    var command_path_len: usize = 1;
    const current_index = current_word_index orelse words.len;
    for (words[command_word_index + 1 ..], command_word_index + 1..) |word, absolute_index| {
        if (absolute_index >= current_index) break;
        if (pending_option) |option| {
            pending_value_index += 1;
            if (pending_value_index >= optionValueCount(option)) pending_option = null;
            continue;
        }
        if (std.mem.eql(u8, word.text, "--")) {
            options_terminated = true;
            continue;
        }
        if (!options_terminated and std.mem.startsWith(u8, word.text, "-")) {
            if (optionTokenForContext(command_path[0..command_path_len], word.text)) |parsed| {
                const consumed_values: usize = if (parsed.value != null) 1 else 0;
                if (consumed_values < optionValueCount(parsed.option)) {
                    pending_option = parsed.option;
                    pending_value_index = consumed_values;
                }
            }
            continue;
        }
        if (!options_terminated) {
            if (subcommandForName(command, null, word.text)) |subcommand| {
                command = subcommand;
                if (command_path_len == command_path.len) return .{
                    .operand_index = operand_index,
                    .options_terminated = options_terminated,
                };
                command_path[command_path_len] = command;
                command_path_len += 1;
                operand_index = 0;
                continue;
            }
        }
        operand_index += 1;
    }

    if (pending_option) |option| {
        const value = optionValueAt(option, pending_value_index) orelse return .{
            .operand_index = operand_index,
            .options_terminated = options_terminated,
        };
        return .{
            .operand_index = operand_index,
            .options_terminated = options_terminated,
            .option_value_provider = jsonField(value, "provider"),
        };
    }

    const prefix_is_option = prefix.len != 0 and prefix[0] == '-' and !options_terminated;
    return .{
        .operand_index = operand_index,
        .options_terminated = options_terminated,
        .complete_options = prefix_is_option,
        .complete_subcommands = operand_index == 0 and commandHasSubcommandCandidates(command),
    };
}

pub const CommandPath = struct {
    items: [16]std.json.Value,
    len: usize,

    pub fn commands(self: *const CommandPath) []const std.json.Value {
        std.debug.assert(self.len > 0);
        std.debug.assert(self.len <= self.items.len);
        return self.items[0..self.len];
    }

    pub fn command(self: *const CommandPath) std.json.Value {
        const path = self.commands();
        return path[path.len - 1];
    }
};

pub fn selectedCommand(
    root: std.json.Value,
    words: []const Word,
    current_word_index: ?usize,
    providers: ?std.json.Value,
) ?std.json.Value {
    const path = selectedCommandPath(root, words, current_word_index, providers);
    return path.command();
}

pub fn selectedCommandPath(
    root: std.json.Value,
    words: []const Word,
    current_word_index: ?usize,
    providers: ?std.json.Value,
) CommandPath {
    var path: CommandPath = .{ .items = undefined, .len = 1 };
    path.items[0] = root;
    var pending_option_values: usize = 0;
    var options_terminated = false;
    const limit = if (current_word_index) |index| @min(index, words.len) else words.len;
    for (words, 0..) |word, relative_index| {
        if (relative_index >= limit) break;
        if (pending_option_values != 0) {
            pending_option_values -= 1;
            continue;
        }
        if (std.mem.eql(u8, word.text, "--")) {
            options_terminated = true;
            continue;
        }
        if (!options_terminated and std.mem.startsWith(u8, word.text, "-")) {
            if (optionTokenForContext(path.commands(), word.text)) |parsed| {
                const consumed_values: usize = if (parsed.value != null) 1 else 0;
                pending_option_values = optionValueCount(parsed.option) - consumed_values;
            }
            continue;
        }
        if (options_terminated) break;
        if (subcommandForName(path.command(), providers, word.text)) |subcommand| {
            if (path.len == path.items.len) return path;
            path.items[path.len] = subcommand;
            path.len += 1;
            continue;
        }
        break;
    }
    return path;
}

pub fn argumentProvider(command: std.json.Value, operand_index: usize) ?std.json.Value {
    const arguments = jsonObjectField(command, "arguments") orelse return null;
    const states = jsonArrayField(arguments, "states") orelse return null;
    var repeatable_provider: ?std.json.Value = null;
    for (states.items) |state| {
        const provider = jsonObjectField(state, "provider") orelse jsonField(state, "provider") orelse continue;
        const index = jsonUsizeField(state, "index");
        if (index != null and index.? == operand_index) return provider;
        if (jsonBoolField(state, "repeatable") orelse false) repeatable_provider = provider;
    }
    return repeatable_provider;
}

pub const ParsedOptionToken = struct {
    option: std.json.Value,
    value: ?[]const u8 = null,
};

pub fn optionTokenForContext(command_path: []const std.json.Value, token: []const u8) ?ParsedOptionToken {
    var index = command_path.len;
    while (index > 0) {
        index -= 1;
        const options = jsonArrayField(command_path[index], "options") orelse continue;
        for (options.items) |option| {
            if (index + 1 != command_path.len and !(jsonBoolField(option, "inherit") orelse true)) continue;
            if (optionToken(option, token)) |parsed| return parsed;
        }
    }
    return null;
}

pub fn subcommandForName(
    command: std.json.Value,
    providers: ?std.json.Value,
    name: []const u8,
) ?std.json.Value {
    _ = providers;
    const subcommands = jsonArrayField(command, "subcommands") orelse return null;
    for (subcommands.items) |subcommand| {
        if (wordMatchesCommandName(subcommand, name)) return subcommand;
    }
    return null;
}

pub fn commandName(command: std.json.Value) ?[]const u8 {
    if (jsonStringField(command, "name")) |name| return name;
    const names = jsonArrayField(command, "name") orelse return null;
    if (names.items.len == 0) return null;
    return jsonString(names.items[0]);
}

fn optionForSpelling(command: std.json.Value, spelling: []const u8) ?std.json.Value {
    const options = jsonArrayField(command, "options") orelse return null;
    for (options.items) |option| {
        if (optionMatchesSpelling(option, spelling)) return option;
    }
    return null;
}

fn optionToken(option: std.json.Value, token: []const u8) ?ParsedOptionToken {
    if (optionMatchesSpelling(option, token)) return .{ .option = option };
    if (optionValueCount(option) == 0) return null;

    if (jsonStringField(option, "long")) |long| {
        if (token.len >= long.len + 3 and
            std.mem.eql(u8, token[0..2], "--") and
            std.mem.eql(u8, token[2 .. long.len + 2], long) and
            token[long.len + 2] == '=')
        {
            return .{ .option = option, .value = token[long.len + 3 ..] };
        }
    }
    if (jsonStringField(option, "short")) |short| {
        if (short.len == 1 and token.len > 2 and token[0] == '-' and token[1] == short[0]) {
            const value = if (token[2] == '=') token[3..] else token[2..];
            return .{ .option = option, .value = value };
        }
    }
    return null;
}

pub fn optionValueCount(option: std.json.Value) usize {
    const value = jsonField(option, "value") orelse return 0;
    return switch (value) {
        .object => 1,
        .array => |values| values.items.len,
        else => 0,
    };
}

pub fn optionValueAt(option: std.json.Value, index: usize) ?std.json.Value {
    const value = jsonField(option, "value") orelse return null;
    return switch (value) {
        .object => if (index == 0) value else null,
        .array => |values| if (index < values.items.len) values.items[index] else null,
        else => null,
    };
}

fn optionMatchesSpelling(option: std.json.Value, spelling: []const u8) bool {
    if (jsonStringField(option, "long")) |long| {
        if (spelling.len == long.len + 2 and
            std.mem.eql(u8, spelling[0..2], "--") and
            std.mem.eql(u8, spelling[2..], long)) return true;
    }
    if (jsonStringField(option, "short")) |short| {
        if (spelling.len == short.len + 1 and spelling[0] == '-' and std.mem.eql(u8, spelling[1..], short)) return true;
    }
    if (jsonArrayField(option, "spellings")) |spellings| {
        for (spellings.items) |item| if (jsonString(item)) |value| if (std.mem.eql(u8, spelling, value)) return true;
    }
    return false;
}

fn commandHasSubcommandCandidates(command: std.json.Value) bool {
    if (jsonArrayField(command, "subcommands")) |subcommands| {
        if (subcommands.items.len != 0) return true;
    }
    const dynamic = jsonArrayField(command, "dynamicSubcommands") orelse return false;
    return dynamic.items.len != 0;
}

fn wordMatchesCommandName(command: std.json.Value, name: []const u8) bool {
    if (commandName(command)) |primary| if (std.mem.eql(u8, primary, name)) return true;
    if (jsonArrayField(command, "aliases")) |aliases| {
        for (aliases.items) |alias| if (jsonString(alias)) |value| if (std.mem.eql(u8, value, name)) return true;
    }
    return false;
}

fn jsonField(value: std.json.Value, name: []const u8) ?std.json.Value {
    const object = jsonObject(value) orelse return null;
    return object.get(name);
}

fn jsonObjectField(value: std.json.Value, name: []const u8) ?std.json.Value {
    const field = jsonField(value, name) orelse return null;
    _ = jsonObject(field) orelse return null;
    return field;
}

fn jsonArrayField(value: std.json.Value, name: []const u8) ?std.json.Array {
    return jsonArray(jsonField(value, name) orelse return null);
}

fn jsonStringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    return jsonString(jsonField(value, name) orelse return null);
}

fn jsonBoolField(value: std.json.Value, name: []const u8) ?bool {
    return switch (jsonField(value, name) orelse return null) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn jsonUsizeField(value: std.json.Value, name: []const u8) ?usize {
    return switch (jsonField(value, name) orelse return null) {
        .integer => |integer| std.math.cast(usize, integer),
        else => null,
    };
}

fn jsonObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn jsonArray(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}
