const std = @import("std");
const Allocator = std.mem.Allocator;

/// Quote-aware line tokenizer.
///
/// Converts raw input text into discrete string tokens.
/// This is the security boundary — raw text enters, structured tokens exit.
///
/// Supports:
/// - Double-quoted strings: "hello world" → single token
/// - Single-quoted strings: 'hello world' → single token (no escape processing)
/// - Backslash escaping in unquoted and double-quoted contexts: \" → "
/// - Whitespace splitting in unquoted context
///
/// Explicitly NOT supported (no shell interpretation):
/// - Glob expansion (*, ?)
/// - Variable expansion ($VAR)
/// - Pipe operators (|)
/// - Redirects (>, <, >>)
/// - Command substitution ($(), ``)

pub const TokenizeError = error{
    UnterminatedQuote,
    OutOfMemory,
};

/// Result of tokenization. Caller must call deinit() to free.
pub const TokenList = struct {
    tokens: [][]const u8,
    allocator: Allocator,

    pub fn deinit(self: *TokenList) void {
        for (self.tokens) |token| {
            self.allocator.free(token);
        }
        self.allocator.free(self.tokens);
    }
};

const State = enum {
    normal,
    double_quote,
    single_quote,
};

/// Tokenize an input line into discrete string tokens.
///
/// Returns a TokenList with owned token strings.
/// Caller must call .deinit() when done.
pub fn tokenize(allocator: Allocator, input: []const u8) TokenizeError!TokenList {
    var tokens: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (tokens.items) |t| allocator.free(t);
        tokens.deinit(allocator);
    }

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);

    var state: State = .normal;
    var in_token = false; // Tracks if we've started a token (for empty quoted strings)
    var i: usize = 0;

    while (i < input.len) : (i += 1) {
        const c = input[i];

        switch (state) {
            .normal => {
                if (c == '\\' and i + 1 < input.len) {
                    // Backslash escape: take next char literally
                    i += 1;
                    current.append(allocator, input[i]) catch return TokenizeError.OutOfMemory;
                    in_token = true;
                } else if (c == '"') {
                    state = .double_quote;
                    in_token = true; // Even empty "" is a token
                } else if (c == '\'') {
                    state = .single_quote;
                    in_token = true; // Even empty '' is a token
                } else if (c == ' ' or c == '\t') {
                    // Whitespace: emit token if we have content or were in quotes
                    if (in_token or current.items.len > 0) {
                        const owned = allocator.dupe(u8, current.items) catch return TokenizeError.OutOfMemory;
                        tokens.append(allocator, owned) catch {
                            allocator.free(owned);
                            return TokenizeError.OutOfMemory;
                        };
                        current.clearRetainingCapacity();
                        in_token = false;
                    }
                } else {
                    current.append(allocator, c) catch return TokenizeError.OutOfMemory;
                    in_token = true;
                }
            },
            .double_quote => {
                if (c == '\\' and i + 1 < input.len) {
                    const next = input[i + 1];
                    // In double quotes, only escape: \\ \" \n \t
                    if (next == '\\' or next == '"' or next == 'n' or next == 't') {
                        i += 1;
                        const escaped: u8 = switch (next) {
                            'n' => '\n',
                            't' => '\t',
                            else => next,
                        };
                        current.append(allocator, escaped) catch return TokenizeError.OutOfMemory;
                    } else {
                        // Not a recognized escape: keep the backslash
                        current.append(allocator, c) catch return TokenizeError.OutOfMemory;
                    }
                } else if (c == '"') {
                    state = .normal;
                } else {
                    current.append(allocator, c) catch return TokenizeError.OutOfMemory;
                }
            },
            .single_quote => {
                if (c == '\'') {
                    // Single quotes: no escape processing, just end on '
                    state = .normal;
                } else {
                    current.append(allocator, c) catch return TokenizeError.OutOfMemory;
                }
            },
        }
    }

    // Check for unterminated quotes
    if (state != .normal) {
        return TokenizeError.UnterminatedQuote;
    }

    // Emit final token if non-empty or we were in a token (empty quoted string)
    if (in_token or current.items.len > 0) {
        const owned = allocator.dupe(u8, current.items) catch return TokenizeError.OutOfMemory;
        tokens.append(allocator, owned) catch {
            allocator.free(owned);
            return TokenizeError.OutOfMemory;
        };
    }

    return TokenList{
        .tokens = tokens.toOwnedSlice(allocator) catch return TokenizeError.OutOfMemory,
        .allocator = allocator,
    };
}

/// Check if input contains shell metacharacters that we don't support.
/// Returns the offending character if found.
pub fn detectShellMeta(input: []const u8) ?u8 {
    var in_single_quote = false;
    var in_double_quote = false;
    var i: usize = 0;

    while (i < input.len) : (i += 1) {
        const c = input[i];

        if (in_single_quote) {
            if (c == '\'') in_single_quote = false;
            continue;
        }
        if (in_double_quote) {
            if (c == '\\' and i + 1 < input.len) {
                i += 1; // skip escaped char
                continue;
            }
            if (c == '"') in_double_quote = false;
            // $VAR inside double quotes is still a shell feature
            if (c == '$') return c;
            continue;
        }

        // Unquoted context
        if (c == '\'') {
            in_single_quote = true;
            continue;
        }
        if (c == '"') {
            in_double_quote = true;
            continue;
        }
        if (c == '\\' and i + 1 < input.len) {
            i += 1;
            continue;
        }

        switch (c) {
            '|', '>', '<', '`', '$', ';', '&' => return c,
            '*', '?' => return c,
            else => {},
        }
    }
    return null;
}

// ─── Tests ───────────────────────────────────────────────────────

test "tokenize: simple words" {
    const alloc = std.testing.allocator;
    var result = try tokenize(alloc, "git commit");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.tokens.len);
    try std.testing.expectEqualStrings("git", result.tokens[0]);
    try std.testing.expectEqualStrings("commit", result.tokens[1]);
}

test "tokenize: double-quoted string" {
    const alloc = std.testing.allocator;
    var result = try tokenize(alloc, "git commit -m \"fix bug\"");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 4), result.tokens.len);
    try std.testing.expectEqualStrings("git", result.tokens[0]);
    try std.testing.expectEqualStrings("commit", result.tokens[1]);
    try std.testing.expectEqualStrings("-m", result.tokens[2]);
    try std.testing.expectEqualStrings("fix bug", result.tokens[3]);
}

test "tokenize: single-quoted string" {
    const alloc = std.testing.allocator;
    var result = try tokenize(alloc, "git commit -m 'fix bug'");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 4), result.tokens.len);
    try std.testing.expectEqualStrings("fix bug", result.tokens[3]);
}

test "tokenize: backslash escape in normal context" {
    const alloc = std.testing.allocator;
    var result = try tokenize(alloc, "echo hello\\ world");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.tokens.len);
    try std.testing.expectEqualStrings("echo", result.tokens[0]);
    try std.testing.expectEqualStrings("hello world", result.tokens[1]);
}

test "tokenize: escaped quote inside double quotes" {
    const alloc = std.testing.allocator;
    var result = try tokenize(alloc, "echo \"he said \\\"hi\\\"\"");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.tokens.len);
    try std.testing.expectEqualStrings("he said \"hi\"", result.tokens[1]);
}

test "tokenize: single quotes preserve backslashes" {
    const alloc = std.testing.allocator;
    var result = try tokenize(alloc, "echo 'no\\escape'");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.tokens.len);
    try std.testing.expectEqualStrings("no\\escape", result.tokens[1]);
}

test "tokenize: mixed quote styles" {
    const alloc = std.testing.allocator;
    var result = try tokenize(alloc, "git commit -m \"first\" --all");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 5), result.tokens.len);
    try std.testing.expectEqualStrings("git", result.tokens[0]);
    try std.testing.expectEqualStrings("commit", result.tokens[1]);
    try std.testing.expectEqualStrings("-m", result.tokens[2]);
    try std.testing.expectEqualStrings("first", result.tokens[3]);
    try std.testing.expectEqualStrings("--all", result.tokens[4]);
}

test "tokenize: empty input" {
    const alloc = std.testing.allocator;
    var result = try tokenize(alloc, "");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.tokens.len);
}

test "tokenize: whitespace-only input" {
    const alloc = std.testing.allocator;
    var result = try tokenize(alloc, "   \t  ");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.tokens.len);
}

test "tokenize: unterminated double quote" {
    const alloc = std.testing.allocator;
    const result = tokenize(alloc, "echo \"hello");
    try std.testing.expectError(TokenizeError.UnterminatedQuote, result);
}

test "tokenize: unterminated single quote" {
    const alloc = std.testing.allocator;
    const result = tokenize(alloc, "echo 'hello");
    try std.testing.expectError(TokenizeError.UnterminatedQuote, result);
}

test "tokenize: multiple spaces between tokens" {
    const alloc = std.testing.allocator;
    var result = try tokenize(alloc, "git   commit   -m   \"hello\"");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 4), result.tokens.len);
    try std.testing.expectEqualStrings("git", result.tokens[0]);
    try std.testing.expectEqualStrings("commit", result.tokens[1]);
}

test "tokenize: adjacent quoted strings merge" {
    const alloc = std.testing.allocator;
    var result = try tokenize(alloc, "echo \"hello\"'world'");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.tokens.len);
    try std.testing.expectEqualStrings("helloworld", result.tokens[1]);
}

test "tokenize: equals in flag" {
    const alloc = std.testing.allocator;
    var result = try tokenize(alloc, "--message=\"fix bug\"");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.tokens.len);
    try std.testing.expectEqualStrings("--message=fix bug", result.tokens[0]);
}

test "tokenize: empty quoted string produces token" {
    const alloc = std.testing.allocator;
    var result = try tokenize(alloc, "echo \"\"");
    defer result.deinit();

    // "echo" and "" — empty string is still part of the echo token concatenation
    // Actually: "echo" is one token, then "" is adjacent with no space, so they merge
    // Wait: there IS a space between echo and ""
    try std.testing.expectEqual(@as(usize, 2), result.tokens.len);
    try std.testing.expectEqualStrings("echo", result.tokens[0]);
    try std.testing.expectEqualStrings("", result.tokens[1]);
}

test "detectShellMeta: pipe detected" {
    try std.testing.expectEqual(@as(?u8, '|'), detectShellMeta("git log | head"));
}

test "detectShellMeta: redirect detected" {
    try std.testing.expectEqual(@as(?u8, '>'), detectShellMeta("echo hello > file"));
}

test "detectShellMeta: variable detected" {
    try std.testing.expectEqual(@as(?u8, '$'), detectShellMeta("echo $HOME"));
}

test "detectShellMeta: glob detected" {
    try std.testing.expectEqual(@as(?u8, '*'), detectShellMeta("ls *.txt"));
}

test "detectShellMeta: clean input" {
    try std.testing.expectEqual(@as(?u8, null), detectShellMeta("git commit -m \"fix bug\" --all"));
}

test "detectShellMeta: metachar inside single quotes ignored" {
    try std.testing.expectEqual(@as(?u8, null), detectShellMeta("echo 'hello | world'"));
}

test "detectShellMeta: dollar inside double quotes detected" {
    try std.testing.expectEqual(@as(?u8, '$'), detectShellMeta("echo \"$HOME\""));
}
