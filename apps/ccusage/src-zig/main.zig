const std = @import("std");

const VERSION = "18.0.11-zig";
const LITELLM_PRICING_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json";
const EMBEDDED_PRICING_JSON = @embedFile("claude-pricing.json");
const SESSION_DURATION_HOURS = 5.0;
const RECENT_DAYS = 3;
const BLOCKS_WARNING_THRESHOLD = 0.8;
const ANSI_CYAN_CODE = "\x1b[36m";
const ANSI_YELLOW_CODE = "\x1b[33m";
const ANSI_GRAY_CODE = "\x1b[90m";
const ANSI_RESET_CODE = "\x1b[0m";

const CostMode = enum { auto, calculate, display };
const SortOrder = enum { asc, desc };
const Command = enum { daily, weekly, monthly, session, blocks, help, version };

const ExplicitArgs = struct {
    since: bool = false,
    until: bool = false,
    json: bool = false,
    mode: bool = false,
    debug: bool = false,
    debug_samples: bool = false,
    order: bool = false,
    breakdown: bool = false,
    offline: bool = false,
    timezone: bool = false,
    jq: bool = false,
    compact: bool = false,
    color: bool = false,
    instances: bool = false,
    project: bool = false,
    project_aliases: bool = false,
    id: bool = false,
    active: bool = false,
    recent: bool = false,
    token_limit: bool = false,
    session_length: bool = false,
    start_of_week: bool = false,
};

const Args = struct {
    command: Command = .daily,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
    json: bool = false,
    mode: CostMode = .auto,
    debug: bool = false,
    debug_samples: usize = 5,
    order: SortOrder = .asc,
    breakdown: bool = false,
    offline: bool = false,
    timezone: ?[]const u8 = null,
    jq: ?[]const u8 = null,
    compact: bool = false,
    color: ?bool = null,
    instances: bool = false,
    project: ?[]const u8 = null,
    project_aliases: ?[]const u8 = null,
    id: ?[]const u8 = null,
    active: bool = false,
    recent: bool = false,
    token_limit: ?[]const u8 = null,
    session_length: f64 = SESSION_DURATION_HOURS,
    start_of_week: WeekDay = .sunday,
    config_path: ?[]const u8 = null,
    explicit: ExplicitArgs = .{},
};

const WeekDay = enum {
    sunday,
    monday,
    tuesday,
    wednesday,
    thursday,
    friday,
    saturday,
};

const TokenUsage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    speed_fast: bool = false,

    fn total(self: TokenUsage) u64 {
        return self.input_tokens + self.output_tokens + self.cache_creation_input_tokens + self.cache_read_input_tokens;
    }
};

const Entry = struct {
    timestamp: i64,
    timestamp_text: []const u8,
    date: []const u8,
    session_id: []const u8,
    project: []const u8,
    project_path: []const u8,
    version: ?[]const u8,
    message_id: ?[]const u8,
    request_id: ?[]const u8,
    model: ?[]const u8,
    usage: TokenUsage,
    cost_usd: ?f64,
    cost: f64,
    is_api_error: bool,
    reset_time: ?i64,
    file_index: usize,
    line_number: usize,
};

const TokenTotals = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_creation_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cost: f64 = 0,

    fn addUsage(self: *TokenTotals, usage: TokenUsage, cost: f64) void {
        self.input_tokens += usage.input_tokens;
        self.output_tokens += usage.output_tokens;
        self.cache_creation_tokens += usage.cache_creation_input_tokens;
        self.cache_read_tokens += usage.cache_read_input_tokens;
        self.cost += cost;
    }

    fn total(self: TokenTotals) u64 {
        return self.input_tokens + self.output_tokens + self.cache_creation_tokens + self.cache_read_tokens;
    }
};

const ModelBreakdown = struct {
    model: []const u8,
    totals: TokenTotals,
    first_timestamp: i64,
};

const Summary = struct {
    label: []const u8,
    project: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    project_path: ?[]const u8 = null,
    last_activity: ?[]const u8 = null,
    totals: TokenTotals,
    models: std.array_list.Managed([]const u8),
    breakdowns: std.array_list.Managed(ModelBreakdown),
    versions: std.array_list.Managed([]const u8),
};

const SessionBlock = struct {
    id: []const u8,
    start: i64,
    end: i64,
    actual_end: ?i64,
    is_active: bool,
    is_gap: bool,
    entries: usize,
    totals: TokenTotals,
    models: std.array_list.Managed([]const u8),
    reset_time: ?i64,
};

const Pricing = struct {
    input: f64,
    output: f64,
    cache_create: f64,
    cache_read: f64,
    input_above_200k: ?f64 = null,
    output_above_200k: ?f64 = null,
    cache_create_above_200k: ?f64 = null,
    cache_read_above_200k: ?f64 = null,
};

const PricingMap = std.StringHashMap(Pricing);

const DebugBucket = struct {
    total: u64 = 0,
    matches: u64 = 0,
    mismatches: u64 = 0,
    avg_percent_diff: f64 = 0,
};

const DebugSample = struct {
    timestamp: []const u8,
    model: []const u8,
    original_cost: f64,
    calculated_cost: f64,
    difference: f64,
    percent_diff: f64,
    usage: TokenUsage,
};

const ParseWorker = struct {
    allocator: std.mem.Allocator,
    files: []const []const u8,
    start: usize,
    end: usize,
    args: Args,
    pricing: *const PricingMap,
    entries: std.array_list.Managed(Entry),
    err: ?anyerror = null,
};

var env_map: *std.process.Environ.Map = undefined;
var process_io: std.Io = undefined;
var out_writer_global: *std.Io.Writer = undefined;
var err_writer_global: *std.Io.Writer = undefined;
var ANSI_CYAN: []const u8 = ANSI_CYAN_CODE;
var ANSI_YELLOW: []const u8 = ANSI_YELLOW_CODE;
var ANSI_GRAY: []const u8 = ANSI_GRAY_CODE;
var ANSI_RESET: []const u8 = ANSI_RESET_CODE;

pub fn main(init: std.process.Init) !void {
    env_map = init.environ_map;
    process_io = init.io;
    const allocator = std.heap.smp_allocator;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    out_writer_global = &stdout_file_writer.interface;
    defer out_writer_global.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    err_writer_global = &stderr_file_writer.interface;
    defer err_writer_global.flush() catch {};

    const argv = try init.minimal.args.toSlice(allocator);

    var args = try parseArgs(argv[1..]);
    try applyConfig(allocator, &args);
    configureAnsi(args.color);
    if (args.command == .help) {
        printHelp();
        return;
    }
    if (args.command == .version) {
        try stdout().print("{s}\n", .{VERSION});
        return;
    }
    if (args.jq != null) args.json = true;

    var pricing = PricingMap.init(allocator);
    try loadPricing(allocator, &pricing, args.offline);

    var entries = std.array_list.Managed(Entry).init(allocator);
    try loadEntries(allocator, &entries, args, &pricing);
    if (args.debug and !args.json) try printMismatchReport(allocator, entries.items, &pricing, args.debug_samples);

    switch (args.command) {
        .daily => try runDaily(allocator, args, entries.items),
        .weekly => try runWeekly(allocator, args, entries.items),
        .monthly => try runMonthly(allocator, args, entries.items),
        .session => try runSession(allocator, args, entries.items),
        .blocks => try runBlocks(allocator, args, entries.items),
        else => unreachable,
    }
}

fn stdout() *std.Io.Writer {
    return out_writer_global;
}

fn stderr() *std.Io.Writer {
    return err_writer_global;
}

fn parseArgs(argv: []const []const u8) !Args {
    var args = Args{};
    var i: usize = 0;
    if (argv.len > 0 and !std.mem.startsWith(u8, argv[0], "-")) {
        if (std.mem.eql(u8, argv[0], "daily")) args.command = .daily else if (std.mem.eql(u8, argv[0], "weekly")) args.command = .weekly else if (std.mem.eql(u8, argv[0], "monthly")) args.command = .monthly else if (std.mem.eql(u8, argv[0], "session")) args.command = .session else if (std.mem.eql(u8, argv[0], "blocks")) args.command = .blocks else if (std.mem.eql(u8, argv[0], "help")) args.command = .help else return error.UnknownCommand;
        i = 1;
    }
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            args.command = .help;
        } else if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-v")) {
            args.command = .version;
        } else if (std.mem.eql(u8, a, "--json") or std.mem.eql(u8, a, "-j")) {
            args.json = true;
            args.explicit.json = true;
        } else if (std.mem.eql(u8, a, "--breakdown") or std.mem.eql(u8, a, "-b")) {
            args.breakdown = true;
            args.explicit.breakdown = true;
        } else if (std.mem.eql(u8, a, "--offline") or std.mem.eql(u8, a, "-O")) {
            args.offline = true;
            args.explicit.offline = true;
        } else if (std.mem.eql(u8, a, "--no-offline")) {
            args.offline = false;
            args.explicit.offline = true;
        } else if (std.mem.eql(u8, a, "--compact")) {
            args.compact = true;
            args.explicit.compact = true;
        } else if (std.mem.eql(u8, a, "--color")) {
            args.color = true;
            args.explicit.color = true;
        } else if (std.mem.eql(u8, a, "--no-color")) {
            args.color = false;
            args.explicit.color = true;
        } else if (std.mem.eql(u8, a, "--instances") or std.mem.eql(u8, a, "-i")) {
            if (args.command == .session) {
                i += 1;
                if (i >= argv.len) return error.MissingValue;
                args.id = argv[i];
                args.explicit.id = true;
            } else {
                args.instances = true;
                args.explicit.instances = true;
            }
        } else if (std.mem.eql(u8, a, "--active") or std.mem.eql(u8, a, "-a")) {
            args.active = true;
            args.explicit.active = true;
        } else if (std.mem.eql(u8, a, "--recent") or std.mem.eql(u8, a, "-r")) {
            args.recent = true;
            args.explicit.recent = true;
        } else if (std.mem.eql(u8, a, "--since") or std.mem.eql(u8, a, "-s")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.since = argv[i];
            args.explicit.since = true;
        } else if (std.mem.eql(u8, a, "--until") or std.mem.eql(u8, a, "-u")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.until = argv[i];
            args.explicit.until = true;
        } else if (std.mem.eql(u8, a, "--mode") or std.mem.eql(u8, a, "-m")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.mode = parseEnum(CostMode, argv[i]) orelse return error.InvalidMode;
            args.explicit.mode = true;
        } else if (std.mem.eql(u8, a, "--debug") or std.mem.eql(u8, a, "-d")) {
            args.debug = true;
            args.explicit.debug = true;
        } else if (std.mem.eql(u8, a, "--debug-samples")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.debug_samples = try std.fmt.parseInt(usize, argv[i], 10);
            args.explicit.debug_samples = true;
        } else if (std.mem.startsWith(u8, a, "--debug-samples=")) {
            args.debug_samples = try std.fmt.parseInt(usize, a["--debug-samples=".len..], 10);
            args.explicit.debug_samples = true;
        } else if (std.mem.eql(u8, a, "--order") or std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.order = parseEnum(SortOrder, argv[i]) orelse return error.InvalidOrder;
            args.explicit.order = true;
        } else if (std.mem.eql(u8, a, "--timezone") or std.mem.eql(u8, a, "-z")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.timezone = argv[i];
            args.explicit.timezone = true;
        } else if (std.mem.eql(u8, a, "--jq") or std.mem.eql(u8, a, "-q")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.jq = argv[i];
            args.explicit.jq = true;
        } else if (std.mem.eql(u8, a, "--project") or std.mem.eql(u8, a, "-p")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.project = argv[i];
            args.explicit.project = true;
        } else if (std.mem.eql(u8, a, "--project-aliases")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.project_aliases = argv[i];
            args.explicit.project_aliases = true;
        } else if (std.mem.eql(u8, a, "--id")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.id = argv[i];
            args.explicit.id = true;
        } else if (std.mem.eql(u8, a, "--token-limit") or std.mem.eql(u8, a, "-t")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.token_limit = argv[i];
            args.explicit.token_limit = true;
        } else if (std.mem.eql(u8, a, "--session-length") or std.mem.eql(u8, a, "-n")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.session_length = try std.fmt.parseFloat(f64, argv[i]);
            args.explicit.session_length = true;
        } else if (std.mem.eql(u8, a, "--start-of-week") or std.mem.eql(u8, a, "-w")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.start_of_week = parseEnum(WeekDay, argv[i]) orelse return error.InvalidWeekDay;
            args.explicit.start_of_week = true;
        } else if (std.mem.eql(u8, a, "--config")) {
            if (std.mem.eql(u8, a, "--config")) {
                i += 1;
                if (i >= argv.len) return error.MissingValue;
                args.config_path = argv[i];
            }
        } else {
            return error.UnknownOption;
        }
    }
    return args;
}

fn configureAnsi(explicit_color: ?bool) void {
    const enabled = explicit_color orelse colorEnabledFromEnv();
    if (enabled) {
        ANSI_CYAN = ANSI_CYAN_CODE;
        ANSI_YELLOW = ANSI_YELLOW_CODE;
        ANSI_GRAY = ANSI_GRAY_CODE;
        ANSI_RESET = ANSI_RESET_CODE;
    } else {
        ANSI_CYAN = "";
        ANSI_YELLOW = "";
        ANSI_GRAY = "";
        ANSI_RESET = "";
    }
}

fn colorEnabledFromEnv() bool {
    if (env_map.get("NO_COLOR")) |value| {
        if (value.len > 0) return false;
    }
    if (env_map.get("FORCE_COLOR")) |value| {
        return value.len > 0 and !std.mem.eql(u8, value, "0");
    }
    return true;
}

fn parseEnum(comptime T: type, value: []const u8) ?T {
    inline for (@typeInfo(T).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn printHelp() void {
    stdout().print(
        \\Usage: ccusage [command] [options]
        \\
        \\Commands:
        \\  daily      Show usage report grouped by date
        \\  weekly     Show usage report grouped by week
        \\  monthly    Show usage report grouped by month
        \\  session    Show usage report grouped by conversation session
        \\  blocks     Show usage report grouped by session billing blocks
        \\
        \\Options:
        \\  -s, --since <YYYYMMDD>
        \\  -u, --until <YYYYMMDD>
        \\  -j, --json
        \\  -m, --mode <auto|calculate|display>
        \\  -d, --debug
        \\  --debug-samples <count>
        \\  -o, --order <asc|desc>
        \\  -b, --breakdown
        \\  -O, --offline
        \\  -z, --timezone <TZ>
        \\  -q, --jq <filter>
        \\  --compact
        \\  --color / --no-color
        \\
    , .{}) catch {};
}

fn applyConfig(allocator: std.mem.Allocator, args: *Args) !void {
    const path = try findConfigPath(allocator, args.config_path);
    const config_path = path orelse return;
    const data = std.Io.Dir.cwd().readFileAlloc(process_io, config_path, allocator, .limited(1024 * 1024 * 16)) catch return;
    defer allocator.free(data);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return,
    };
    if (objectField(root, "defaults")) |defaults| try applyConfigObject(allocator, args, defaults);
    if (objectField(root, "commands")) |commands| {
        if (objectField(commands, commandName(args.command))) |command_config| try applyConfigObject(allocator, args, command_config);
    }
}

fn findConfigPath(allocator: std.mem.Allocator, explicit_path: ?[]const u8) !?[]const u8 {
    if (explicit_path) |path| return if (isFile(path)) try allocator.dupe(u8, path) else null;
    const local = try std.fs.path.join(allocator, &.{ ".ccusage", "ccusage.json" });
    if (isFile(local)) return local;
    var paths = std.array_list.Managed([]const u8).init(allocator);
    defer paths.deinit();
    claudePaths(allocator, &paths) catch return null;
    for (paths.items) |claude_path| {
        const candidate = try std.fs.path.join(allocator, &.{ claude_path, "ccusage.json" });
        if (isFile(candidate)) return candidate;
    }
    return null;
}

fn isFile(path: []const u8) bool {
    std.Io.Dir.cwd().access(process_io, path, .{}) catch return false;
    return true;
}

fn commandName(command: Command) []const u8 {
    return switch (command) {
        .daily => "daily",
        .weekly => "weekly",
        .monthly => "monthly",
        .session => "session",
        .blocks => "blocks",
        .help => "help",
        .version => "version",
    };
}

fn applyConfigObject(allocator: std.mem.Allocator, args: *Args, object: std.json.ObjectMap) !void {
    if (!args.explicit.since) {
        if (stringField(object, "since")) |v| args.since = try allocator.dupe(u8, v);
    }
    if (!args.explicit.until) {
        if (stringField(object, "until")) |v| args.until = try allocator.dupe(u8, v);
    }
    if (!args.explicit.json) {
        if (boolField(object, "json")) |v| args.json = v;
    }
    if (!args.explicit.breakdown) {
        if (boolField(object, "breakdown")) |v| args.breakdown = v;
    }
    if (!args.explicit.debug) {
        if (boolField(object, "debug")) |v| args.debug = v;
    }
    if (!args.explicit.debug_samples) {
        if (numberField(object, "debugSamples")) |v| {
            if (v >= 0) args.debug_samples = @intFromFloat(v);
        }
    }
    if (!args.explicit.offline) {
        if (boolField(object, "offline")) |v| args.offline = v;
    }
    if (!args.explicit.compact) {
        if (boolField(object, "compact")) |v| args.compact = v;
    }
    if (!args.explicit.color) {
        if (boolField(object, "color")) |v| args.color = v;
    }
    if (!args.explicit.instances) {
        if (boolField(object, "instances")) |v| args.instances = v;
    }
    if (!args.explicit.active) {
        if (boolField(object, "active")) |v| args.active = v;
    }
    if (!args.explicit.recent) {
        if (boolField(object, "recent")) |v| args.recent = v;
    }
    if (!args.explicit.timezone) {
        if (stringField(object, "timezone")) |v| args.timezone = try allocator.dupe(u8, v);
    }
    if (!args.explicit.jq) {
        if (stringField(object, "jq")) |v| args.jq = try allocator.dupe(u8, v);
    }
    if (!args.explicit.project) {
        if (stringField(object, "project")) |v| args.project = try allocator.dupe(u8, v);
    }
    if (!args.explicit.project_aliases) {
        if (stringField(object, "projectAliases")) |v| args.project_aliases = try allocator.dupe(u8, v);
    }
    if (!args.explicit.id) {
        if (stringField(object, "id")) |v| args.id = try allocator.dupe(u8, v);
    }
    if (!args.explicit.token_limit) {
        if (stringField(object, "tokenLimit")) |v| args.token_limit = try allocator.dupe(u8, v);
    }
    if (!args.explicit.session_length) {
        if (numberField(object, "sessionLength")) |v| args.session_length = v;
    }
    if (!args.explicit.mode) {
        if (stringField(object, "mode")) |v| {
            if (parseEnum(CostMode, v)) |mode| args.mode = mode;
        }
    }
    if (!args.explicit.order) {
        if (stringField(object, "order")) |v| {
            if (parseEnum(SortOrder, v)) |order| args.order = order;
        }
    }
    if (!args.explicit.start_of_week) {
        if (stringField(object, "startOfWeek")) |v| {
            if (parseEnum(WeekDay, v)) |day| args.start_of_week = day;
        }
    }
}

fn loadPricing(allocator: std.mem.Allocator, map: *PricingMap, offline: bool) !void {
    try loadPricingJson(allocator, map, EMBEDDED_PRICING_JSON);
    try putFallbackPricing(map);
    if (offline) return;

    try stderr().print("WARN  Fetching latest model pricing from LiteLLM...\n", .{});
    var client = std.http.Client{ .allocator = allocator, .io = process_io };
    defer client.deinit();

    var body: std.ArrayList(u8) = .empty;
    var writer_alloc: std.Io.Writer.Allocating = .fromArrayList(allocator, &body);

    const result = client.fetch(.{
        .location = .{ .url = LITELLM_PRICING_URL },
        .response_writer = &writer_alloc.writer,
    }) catch |err| {
        try stderr().print("WARN  Failed to fetch LiteLLM pricing ({s}); using embedded pricing.\n", .{@errorName(err)});
        return;
    };
    if (result.status != .ok) {
        try stderr().print("WARN  LiteLLM pricing fetch returned {}; using embedded pricing.\n", .{result.status});
        return;
    }

    try loadPricingJson(allocator, map, writer_alloc.written());
    try stderr().print("INFO  Loaded latest model pricing from LiteLLM.\n", .{});
}

fn loadPricingJson(allocator: std.mem.Allocator, map: *PricingMap, json_text: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return,
    };
    var it = root.iterator();
    while (it.next()) |entry| {
        const value = switch (entry.value_ptr.*) {
            .object => |object| object,
            else => continue,
        };
        const input = numberField(value, "input_cost_per_token") orelse continue;
        const output = numberField(value, "output_cost_per_token") orelse continue;
        const cache_create = numberField(value, "cache_creation_input_token_cost") orelse input * 1.25;
        const cache_read = numberField(value, "cache_read_input_token_cost") orelse input * 0.1;
        try map.put(try allocator.dupe(u8, entry.key_ptr.*), .{
            .input = input,
            .output = output,
            .cache_create = cache_create,
            .cache_read = cache_read,
            .input_above_200k = numberField(value, "input_cost_per_token_above_200k_tokens"),
            .output_above_200k = numberField(value, "output_cost_per_token_above_200k_tokens"),
            .cache_create_above_200k = numberField(value, "cache_creation_input_token_cost_above_200k_tokens"),
            .cache_read_above_200k = numberField(value, "cache_read_input_token_cost_above_200k_tokens"),
        });
    }
}

fn putFallbackPricing(map: *PricingMap) !void {
    try map.put("claude-opus-4-5", .{ .input = 5e-6, .output = 25e-6, .cache_create = 6.25e-6, .cache_read = 0.5e-6 });
    try map.put("claude-opus-4", .{ .input = 15e-6, .output = 75e-6, .cache_create = 18.75e-6, .cache_read = 1.5e-6 });
    try map.put("claude-sonnet-4-6", .{ .input = 3e-6, .output = 15e-6, .cache_create = 3.75e-6, .cache_read = 0.3e-6 });
    try map.put("claude-sonnet-4", .{ .input = 3e-6, .output = 15e-6, .cache_create = 3.75e-6, .cache_read = 0.3e-6, .input_above_200k = 6e-6, .output_above_200k = 22.5e-6, .cache_create_above_200k = 7.5e-6, .cache_read_above_200k = 0.6e-6 });
    try map.put("claude-haiku-4-5", .{ .input = 1e-6, .output = 5e-6, .cache_create = 1.25e-6, .cache_read = 0.1e-6 });
    try map.put("claude-3-5-haiku", .{ .input = 0.8e-6, .output = 4e-6, .cache_create = 1.0e-6, .cache_read = 0.08e-6 });
    try map.put("claude-3-opus", .{ .input = 15e-6, .output = 75e-6, .cache_create = 18.75e-6, .cache_read = 1.5e-6 });
    try map.put("claude-3-sonnet", .{ .input = 3e-6, .output = 15e-6, .cache_create = 3.75e-6, .cache_read = 0.3e-6 });
    try map.put("claude-3-haiku", .{ .input = 0.25e-6, .output = 1.25e-6, .cache_create = 0.3e-6, .cache_read = 0.03e-6 });
}

fn loadEntries(allocator: std.mem.Allocator, entries: *std.array_list.Managed(Entry), args: Args, pricing: *const PricingMap) !void {
    var paths = std.array_list.Managed([]const u8).init(allocator);
    defer paths.deinit();
    try claudePaths(allocator, &paths);

    var files = std.array_list.Managed([]const u8).init(allocator);
    defer files.deinit();
    for (paths.items) |path| {
        const projects = try std.fs.path.join(allocator, &.{ path, "projects" });
        try collectJsonlFiles(allocator, projects, &files);
    }
    std.mem.sort([]const u8, files.items, {}, stringLessThan);

    try readUsageFilesParallel(allocator, entries, files.items, args, pricing);
    try dedupeEntries(allocator, entries);
}

fn readUsageFilesParallel(allocator: std.mem.Allocator, entries: *std.array_list.Managed(Entry), files: []const []const u8, args: Args, pricing: *const PricingMap) !void {
    if (files.len == 0) return;
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const worker_count = @min(files.len, @max(@as(usize, 1), cpu_count));
    if (worker_count == 1) {
        for (files, 0..) |file, file_index| try readUsageFile(allocator, entries, file, file_index, args, pricing);
        return;
    }

    const workers = try allocator.alloc(ParseWorker, worker_count);
    const arenas = try allocator.alloc(std.heap.ArenaAllocator, worker_count);
    const threads = try allocator.alloc(std.Thread, worker_count);
    const chunk_size = (files.len + worker_count - 1) / worker_count;

    for (workers, 0..) |*worker, idx| {
        arenas[idx] = std.heap.ArenaAllocator.init(allocator);
        const worker_allocator = arenas[idx].allocator();
        const start = idx * chunk_size;
        const end = @min(files.len, start + chunk_size);
        worker.* = .{
            .allocator = worker_allocator,
            .files = files,
            .start = start,
            .end = end,
            .args = args,
            .pricing = pricing,
            .entries = std.array_list.Managed(Entry).init(worker_allocator),
        };
        threads[idx] = try std.Thread.spawn(.{}, parseWorkerMain, .{worker});
    }

    for (threads) |thread| thread.join();
    for (workers) |*worker| {
        if (worker.err) |err| return err;
        try entries.appendSlice(worker.entries.items);
    }
}

fn parseWorkerMain(worker: *ParseWorker) void {
    var file_index = worker.start;
    while (file_index < worker.end) : (file_index += 1) {
        readUsageFile(worker.allocator, &worker.entries, worker.files[file_index], file_index, worker.args, worker.pricing) catch |err| {
            worker.err = err;
            return;
        };
    }
}

fn claudePaths(allocator: std.mem.Allocator, paths: *std.array_list.Managed([]const u8)) !void {
    if (getEnvOwned(allocator, "CLAUDE_CONFIG_DIR")) |env_paths| {
        var it = std.mem.splitScalar(u8, env_paths, ',');
        while (it.next()) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0) continue;
            const projects = try std.fs.path.join(allocator, &.{ trimmed, "projects" });
            if (isDir(projects)) try paths.append(try allocator.dupe(u8, trimmed));
        }
        if (paths.items.len > 0) return;
        return error.NoClaudeData;
    } else |_| {}

    const home = try getEnvOwned(allocator, "HOME");
    const xdg = getEnvOwned(allocator, "XDG_CONFIG_HOME") catch try std.fs.path.join(allocator, &.{ home, ".config" });
    const p1 = try std.fs.path.join(allocator, &.{ xdg, "claude" });
    const p2 = try std.fs.path.join(allocator, &.{ home, ".claude" });
    if (isDir(try std.fs.path.join(allocator, &.{ p1, "projects" }))) try paths.append(p1);
    if (isDir(try std.fs.path.join(allocator, &.{ p2, "projects" }))) try paths.append(p2);
    if (paths.items.len == 0) return error.NoClaudeData;
}

fn getEnvOwned(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
    const value = env_map.get(key) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, value);
}

fn isDir(path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(process_io, path, .{}) catch return false;
    dir.close(process_io);
    return true;
}

fn collectJsonlFiles(allocator: std.mem.Allocator, dir_path: []const u8, files: *std.array_list.Managed([]const u8)) !void {
    var dir = std.Io.Dir.openDirAbsolute(process_io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(process_io);
    var it = dir.iterate();
    while (try it.next(process_io)) |entry| {
        const child = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        switch (entry.kind) {
            .file => if (std.mem.endsWith(u8, entry.name, ".jsonl")) try files.append(child),
            .directory => try collectJsonlFiles(allocator, child, files),
            else => {},
        }
    }
}

fn readUsageFile(allocator: std.mem.Allocator, entries: *std.array_list.Managed(Entry), file_path: []const u8, file_index: usize, args: Args, pricing: *const PricingMap) !void {
    const needs_project = args.command == .daily and (args.instances or args.project != null);
    const needs_session_parts = args.command == .session;
    const project = if (needs_project) try extractProject(allocator, file_path) else "unknown";
    if (args.project) |filter| {
        if (!std.mem.eql(u8, filter, project)) return;
    }
    const parts = if (needs_session_parts) try extractSessionParts(allocator, file_path) else SessionParts{ .session_id = "unknown", .file_session_id = "unknown", .project_path = "Unknown Project" };
    if (args.command == .session) {
        if (args.id) |id| {
            if (!std.mem.eql(u8, parts.file_session_id, id)) return;
        }
    }
    const data = std.Io.Dir.cwd().readFileAlloc(process_io, file_path, allocator, .limited(1024 * 1024 * 1024)) catch return;
    var line_it = std.mem.splitScalar(u8, data, '\n');
    var line_number: usize = 0;
    while (line_it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        line_number += 1;
        if (line.len == 0 or indexOfNeedle(line, "\"input_tokens\"") == null) continue;
        const parsed = parseUsageLine(line, args.command == .session or (args.debug and !args.json), args.command == .blocks) orelse continue;
        if (parsed.model_raw != null and parsed.model_raw.?.len == 0) continue;
        const model = if (parsed.model_raw) |m| try displayModel(allocator, m, parsed.usage.speed_fast) else null;
        const cost = switch (args.mode) {
            .display => parsed.cost_usd orelse 0,
            .auto => parsed.cost_usd orelse calculateTokenCost(parsed.model_raw, parsed.usage, pricing),
            .calculate => calculateTokenCost(parsed.model_raw, parsed.usage, pricing),
        };
        const timestamp_ms = parseTimestamp(parsed.timestamp_text) orelse continue;
        const date = try formatDateForTimezone(allocator, timestamp_ms, args.timezone);
        if (!dateInRange(date, args.since, args.until)) continue;
        try entries.append(.{
            .timestamp = timestamp_ms,
            .timestamp_text = parsed.timestamp_text,
            .date = date,
            .session_id = parts.session_id,
            .project = project,
            .project_path = parts.project_path,
            .version = parsed.version,
            .message_id = parsed.message_id,
            .request_id = parsed.request_id,
            .model = model,
            .usage = parsed.usage,
            .cost_usd = parsed.cost_usd,
            .cost = cost,
            .is_api_error = parsed.is_api_error,
            .reset_time = parsed.reset_time,
            .file_index = file_index,
            .line_number = line_number,
        });
    }
}

const ParsedUsageLine = struct {
    timestamp_text: []const u8,
    version: ?[]const u8,
    message_id: ?[]const u8,
    request_id: ?[]const u8,
    model_raw: ?[]const u8,
    usage: TokenUsage,
    cost_usd: ?f64,
    is_api_error: bool,
    reset_time: ?i64,
};

fn parseUsageLine(line: []const u8, need_version: bool, need_reset_time: bool) ?ParsedUsageLine {
    const message = jsonObjectField(line, "\"message\"") orelse return null;
    const usage_obj = jsonObjectField(message, "\"usage\"") orelse return null;
    const input_tokens = jsonU64Field(usage_obj, "\"input_tokens\"") orelse return null;
    const output_tokens = jsonU64Field(usage_obj, "\"output_tokens\"") orelse return null;
    const speed = jsonStringField(usage_obj, "\"speed\"");
    if (speed) |value| {
        if (!std.mem.eql(u8, value, "standard") and !std.mem.eql(u8, value, "fast")) return null;
    }
    const timestamp_text = jsonStringField(line, "\"timestamp\"") orelse return null;
    if (!isIsoTimestamp(timestamp_text)) return null;
    const version = if (need_version) jsonStringField(line, "\"version\"") else null;
    if (version) |value| if (!isVersion(value)) return null;
    const message_id = jsonStringField(message, "\"id\"");
    if (message_id) |value| if (value.len == 0) return null;
    const request_id = jsonStringField(line, "\"requestId\"");
    if (request_id) |value| if (value.len == 0) return null;
    return .{
        .timestamp_text = timestamp_text,
        .version = version,
        .message_id = message_id,
        .request_id = request_id,
        .model_raw = jsonStringField(message, "\"model\""),
        .usage = .{
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
            .cache_creation_input_tokens = jsonU64Field(usage_obj, "\"cache_creation_input_tokens\"") orelse 0,
            .cache_read_input_tokens = jsonU64Field(usage_obj, "\"cache_read_input_tokens\"") orelse 0,
            .speed_fast = if (speed) |value| std.mem.eql(u8, value, "fast") else false,
        },
        .cost_usd = jsonF64Field(line, "\"costUSD\""),
        .is_api_error = if (need_reset_time) jsonBoolField(line, "\"isApiErrorMessage\"") orelse false else false,
        .reset_time = if (need_reset_time) usageLimitResetTime(line) else null,
    };
}

fn usageLimitResetTime(line: []const u8) ?i64 {
    const marker = "Claude AI usage limit reached";
    const marker_index = std.mem.indexOf(u8, line, marker) orelse return null;
    const rest = line[marker_index + marker.len ..];
    const pipe_index = std.mem.indexOfScalar(u8, rest, '|') orelse return null;
    var i = pipe_index + 1;
    if (i >= rest.len or rest[i] < '0' or rest[i] > '9') return null;
    var seconds: i64 = 0;
    while (i < rest.len and rest[i] >= '0' and rest[i] <= '9') : (i += 1) {
        seconds = std.math.mul(i64, seconds, 10) catch return null;
        seconds = std.math.add(i64, seconds, rest[i] - '0') catch return null;
    }
    return if (seconds > 0) seconds * 1000 else null;
}

fn isIsoTimestamp(s: []const u8) bool {
    if (s.len != 20 and s.len != 24) return false;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return false;
    if (s.len == 20 and s[19] != 'Z') return false;
    if (s.len == 24 and (s[19] != '.' or s[23] != 'Z')) return false;
    return allDigits(s[0..4]) and allDigits(s[5..7]) and allDigits(s[8..10]) and allDigits(s[11..13]) and allDigits(s[14..16]) and allDigits(s[17..19]) and (s.len == 20 or allDigits(s[20..23]));
}

fn isVersion(s: []const u8) bool {
    var parts: usize = 0;
    var i: usize = 0;
    while (parts < 3) : (parts += 1) {
        const start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i == start) return false;
        if (parts < 2) {
            if (i >= s.len or s[i] != '.') return false;
            i += 1;
        }
    }
    return true;
}

const SessionParts = struct { session_id: []const u8, file_session_id: []const u8, project_path: []const u8 };

fn extractProject(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var it = std.mem.splitAny(u8, path, "/\\");
    var saw = false;
    while (it.next()) |part| {
        if (saw) return allocator.dupe(u8, if (part.len == 0) "unknown" else part);
        if (std.mem.eql(u8, part, "projects")) saw = true;
    }
    return allocator.dupe(u8, "unknown");
}

fn extractSessionParts(allocator: std.mem.Allocator, path: []const u8) !SessionParts {
    var parts = std.array_list.Managed([]const u8).init(allocator);
    defer parts.deinit();
    var it = std.mem.splitAny(u8, path, "/\\");
    var after_projects = false;
    while (it.next()) |part| {
        if (after_projects) try parts.append(part);
        if (std.mem.eql(u8, part, "projects")) after_projects = true;
    }
    if (parts.items.len >= 2) {
        const session_id = parts.items[parts.items.len - 2];
        const file_name = parts.items[parts.items.len - 1];
        const file_session_id = if (std.mem.endsWith(u8, file_name, ".jsonl")) file_name[0 .. file_name.len - ".jsonl".len] else file_name;
        const project_path = if (parts.items.len > 2) try std.mem.join(allocator, std.fs.path.sep_str, parts.items[0 .. parts.items.len - 2]) else try allocator.dupe(u8, "Unknown Project");
        return .{ .session_id = try allocator.dupe(u8, session_id), .file_session_id = try allocator.dupe(u8, file_session_id), .project_path = project_path };
    }
    return .{ .session_id = try allocator.dupe(u8, "unknown"), .file_session_id = try allocator.dupe(u8, "unknown"), .project_path = try allocator.dupe(u8, "Unknown Project") };
}

const DedupeKey = struct {
    message_id: []const u8,
    request_id: []const u8,
};

const DedupeContext = struct {
    pub fn hash(_: DedupeContext, key: DedupeKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.message_id);
        hasher.update(&.{0});
        hasher.update(key.request_id);
        return hasher.final();
    }

    pub fn eql(_: DedupeContext, a: DedupeKey, b: DedupeKey) bool {
        return std.mem.eql(u8, a.message_id, b.message_id) and std.mem.eql(u8, a.request_id, b.request_id);
    }
};

fn dedupeEntries(allocator: std.mem.Allocator, entries: *std.array_list.Managed(Entry)) !void {
    var seen = std.HashMap(DedupeKey, usize, DedupeContext, std.hash_map.default_max_load_percentage).init(allocator);
    defer seen.deinit();
    var out = std.array_list.Managed(Entry).init(allocator);
    try seen.ensureTotalCapacity(@intCast(entries.items.len));
    try out.ensureTotalCapacity(entries.items.len);
    for (entries.items) |entry| {
        if (entry.message_id == null or entry.request_id == null) {
            out.appendAssumeCapacity(entry);
            continue;
        }
        const key = DedupeKey{ .message_id = entry.message_id.?, .request_id = entry.request_id.? };
        if (seen.get(key)) |idx| {
            if (shouldReplaceDedupedEntry(entry, out.items[idx])) {
                out.items[idx] = entry;
            }
            continue;
        }
        seen.putAssumeCapacity(key, out.items.len);
        out.appendAssumeCapacity(entry);
    }
    entries.deinit();
    entries.* = out;
}

fn shouldReplaceDedupedEntry(candidate: Entry, existing: Entry) bool {
    const candidate_total = candidate.usage.total();
    const existing_total = existing.usage.total();
    if (candidate_total != existing_total) return candidate_total > existing_total;
    return candidate.usage.speed_fast and !existing.usage.speed_fast;
}

fn calculateTokenCost(model_opt: ?[]const u8, usage: TokenUsage, pricing: *const PricingMap) f64 {
    const model = model_opt orelse return 0;
    const p = findPricing(model, pricing) orelse return 0;
    return tiered(usage.input_tokens, p.input, p.input_above_200k) +
        tiered(usage.output_tokens, p.output, p.output_above_200k) +
        tiered(usage.cache_creation_input_tokens, p.cache_create, p.cache_create_above_200k) +
        tiered(usage.cache_read_input_tokens, p.cache_read, p.cache_read_above_200k);
}

fn findPricing(model: []const u8, pricing: *const PricingMap) ?Pricing {
    if (pricing.get(model)) |p| return p;
    var it = pricing.iterator();
    while (it.next()) |entry| {
        if (std.mem.indexOf(u8, model, entry.key_ptr.*) != null or std.mem.indexOf(u8, entry.key_ptr.*, model) != null) return entry.value_ptr.*;
    }
    return null;
}

fn tiered(tokens: u64, base: f64, above: ?f64) f64 {
    if (above) |a| {
        if (tokens > 200_000) return 200_000.0 * base + @as(f64, @floatFromInt(tokens - 200_000)) * a;
    }
    return @as(f64, @floatFromInt(tokens)) * base;
}

fn printMismatchReport(allocator: std.mem.Allocator, entries: []const Entry, pricing: *const PricingMap, sample_count: usize) !void {
    var entries_with_both: u64 = 0;
    var matches: u64 = 0;
    var mismatches: u64 = 0;
    var samples = std.array_list.Managed(DebugSample).init(allocator);
    defer samples.deinit();
    var model_stats = std.StringHashMap(DebugBucket).init(allocator);
    defer model_stats.deinit();
    var version_stats = std.StringHashMap(DebugBucket).init(allocator);
    defer version_stats.deinit();

    for (entries) |entry| {
        const original_cost = entry.cost_usd orelse continue;
        const model = entry.model orelse continue;
        entries_with_both += 1;
        const calculated_cost = calculateTokenCost(model, entry.usage, pricing);
        var difference = original_cost - calculated_cost;
        if (difference < 0) difference = -difference;
        const percent_diff = if (original_cost > 0) difference / original_cost * 100.0 else 0;
        const is_match = percent_diff < 0.1;
        if (is_match) {
            matches += 1;
        } else {
            mismatches += 1;
            if (samples.items.len < sample_count) {
                try samples.append(.{
                    .timestamp = entry.timestamp_text,
                    .model = model,
                    .original_cost = original_cost,
                    .calculated_cost = calculated_cost,
                    .difference = difference,
                    .percent_diff = percent_diff,
                    .usage = entry.usage,
                });
            }
        }
        try updateDebugBucket(&model_stats, model, is_match, percent_diff);
        if (entry.version) |version| try updateDebugBucket(&version_stats, version, is_match, percent_diff);
    }

    if (entries_with_both == 0) {
        try stderr().print("INFO  No pricing data found to analyze.\n", .{});
        return;
    }

    var total_buf: [32]u8 = undefined;
    var both_buf: [32]u8 = undefined;
    var matches_buf: [32]u8 = undefined;
    var mismatches_buf: [32]u8 = undefined;
    const match_rate = @as(f64, @floatFromInt(matches)) / @as(f64, @floatFromInt(entries_with_both)) * 100.0;
    try stderr().print(
        \\INFO
        \\=== Pricing Mismatch Debug Report ===
        \\INFO  Total entries processed: {s}
        \\INFO  Entries with both costUSD and model: {s}
        \\INFO  Matches (within 0.1%): {s}
        \\INFO  Mismatches: {s}
        \\INFO  Match rate: {d:.2}%
        \\
    , .{
        formatNumber(@intCast(entries.len), &total_buf),
        formatNumber(entries_with_both, &both_buf),
        formatNumber(matches, &matches_buf),
        formatNumber(mismatches, &mismatches_buf),
        match_rate,
    });

    if (mismatches > 0 and model_stats.count() > 0) {
        try stderr().print("INFO\n=== Model Statistics ===\n", .{});
        var it = model_stats.iterator();
        while (it.next()) |stat| {
            if (stat.value_ptr.mismatches == 0) continue;
            const model_match_rate = @as(f64, @floatFromInt(stat.value_ptr.matches)) / @as(f64, @floatFromInt(stat.value_ptr.total)) * 100.0;
            try stderr().print(
                \\INFO  {s}:
                \\INFO    Total entries: {}
                \\INFO    Matches: {} ({d:.1}%)
                \\INFO    Mismatches: {}
                \\INFO    Avg % difference: {d:.1}%
                \\
            , .{ stat.key_ptr.*, stat.value_ptr.total, stat.value_ptr.matches, model_match_rate, stat.value_ptr.mismatches, stat.value_ptr.avg_percent_diff });
        }
    }

    if (mismatches > 0 and version_stats.count() > 0) {
        try stderr().print("INFO\n=== Version Statistics ===\n", .{});
        var it = version_stats.iterator();
        while (it.next()) |stat| {
            if (stat.value_ptr.mismatches == 0) continue;
            const version_match_rate = @as(f64, @floatFromInt(stat.value_ptr.matches)) / @as(f64, @floatFromInt(stat.value_ptr.total)) * 100.0;
            try stderr().print(
                \\INFO  {s}:
                \\INFO    Total entries: {}
                \\INFO    Matches: {} ({d:.1}%)
                \\INFO    Mismatches: {}
                \\INFO    Avg % difference: {d:.1}%
                \\
            , .{ stat.key_ptr.*, stat.value_ptr.total, stat.value_ptr.matches, version_match_rate, stat.value_ptr.mismatches, stat.value_ptr.avg_percent_diff });
        }
    }

    if (samples.items.len > 0) {
        try stderr().print("INFO\n=== Sample Discrepancies (first {}) ===\n", .{sample_count});
        for (samples.items) |sample| {
            try stderr().print(
                \\INFO  Timestamp: {s}
                \\INFO  Model: {s}
                \\INFO  Original cost: ${d:.6}
                \\INFO  Calculated cost: ${d:.6}
                \\INFO  Difference: ${d:.6} ({d:.2}%)
                \\INFO  Tokens: {{"input_tokens":{},"output_tokens":{},"cache_creation_input_tokens":{},"cache_read_input_tokens":{}}}
                \\INFO  ---
                \\
            , .{
                sample.timestamp,
                sample.model,
                sample.original_cost,
                sample.calculated_cost,
                sample.difference,
                sample.percent_diff,
                sample.usage.input_tokens,
                sample.usage.output_tokens,
                sample.usage.cache_creation_input_tokens,
                sample.usage.cache_read_input_tokens,
            });
        }
    }
}

fn updateDebugBucket(map: *std.StringHashMap(DebugBucket), key: []const u8, is_match: bool, percent_diff: f64) !void {
    const result = try map.getOrPut(key);
    if (!result.found_existing) result.value_ptr.* = .{};
    result.value_ptr.total += 1;
    if (is_match) {
        result.value_ptr.matches += 1;
    } else {
        result.value_ptr.mismatches += 1;
    }
    result.value_ptr.avg_percent_diff =
        (result.value_ptr.avg_percent_diff * @as(f64, @floatFromInt(result.value_ptr.total - 1)) + percent_diff) /
        @as(f64, @floatFromInt(result.value_ptr.total));
}

fn runDaily(allocator: std.mem.Allocator, args: Args, entries: []const Entry) !void {
    const rows = try summarizeEntries(allocator, entries, .daily, args);
    defer deinitSummaries(rows.items);
    sortSummaries(rows.items, args.order);
    sortAllBreakdowns(rows.items);
    if (args.json) {
        if (args.instances) return printDailyProjectsJson(allocator, rows.items, args.jq);
        return printSummaryJson(allocator, "daily", rows.items, args.jq);
    }
    if (args.instances and hasProjectRows(rows.items)) {
        try printDailyProjectsTable("Claude Code Token Usage Report - Daily", "Date", rows.items, args.breakdown, args.compact, args.project_aliases);
        return;
    }
    try printUsageTable("Claude Code Token Usage Report - Daily", "Date", rows.items, args.breakdown, args.compact);
}

fn runWeekly(allocator: std.mem.Allocator, args: Args, entries: []const Entry) !void {
    const daily = try summarizeEntries(allocator, entries, .daily, args);
    defer deinitSummaries(daily.items);
    sortSummaries(daily.items, .asc);
    const rows = try summarizeBuckets(allocator, daily.items, .weekly, args.start_of_week);
    defer deinitSummaries(rows.items);
    sortSummaries(rows.items, args.order);
    sortAllBreakdowns(rows.items);
    if (args.json) return printSummaryJson(allocator, "weekly", rows.items, args.jq);
    try printUsageTable("Claude Code Token Usage Report - Weekly", "Week", rows.items, args.breakdown, args.compact);
}

fn runMonthly(allocator: std.mem.Allocator, args: Args, entries: []const Entry) !void {
    const daily = try summarizeEntries(allocator, entries, .daily, args);
    defer deinitSummaries(daily.items);
    sortSummaries(daily.items, .asc);
    const rows = try summarizeBuckets(allocator, daily.items, .monthly, args.start_of_week);
    defer deinitSummaries(rows.items);
    sortSummaries(rows.items, args.order);
    sortAllBreakdowns(rows.items);
    if (args.json) return printSummaryJson(allocator, "monthly", rows.items, args.jq);
    try printUsageTable("Claude Code Token Usage Report - Monthly", "Month", rows.items, args.breakdown, args.compact);
}

fn runSession(allocator: std.mem.Allocator, args: Args, entries: []const Entry) !void {
    if (args.id) |id| return runSessionId(allocator, args, entries, id);
    const rows = try summarizeEntries(allocator, entries, .session, args);
    defer deinitSummaries(rows.items);
    sortSummariesByCost(rows.items);
    sortAllBreakdowns(rows.items);
    if (args.json) return printSessionJson(allocator, rows.items, args.jq);
    try printSessionTable("Claude Code Token Usage Report - By Session", rows.items, args.breakdown, args.compact);
}

const SummaryKind = enum { daily, session };
const BucketKind = enum { weekly, monthly };

fn summarizeEntries(allocator: std.mem.Allocator, entries: []const Entry, kind: SummaryKind, args: Args) !std.array_list.Managed(Summary) {
    var rows = std.array_list.Managed(Summary).init(allocator);
    var indexes = std.StringHashMap(usize).init(allocator);
    for (entries) |entry| {
        const key = switch (kind) {
            .daily => if (args.instances) try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ entry.date, entry.project }) else entry.date,
            .session => try std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.project_path, entry.session_id }),
        };
        const idx = indexes.get(key) orelse blk: {
            const label = switch (kind) {
                .daily => entry.date,
                .session => shortSession(entry.session_id),
            };
            try rows.append(.{
                .label = try allocator.dupe(u8, label),
                .project = if (kind == .daily and (args.instances or args.project != null)) entry.project else null,
                .session_id = if (kind == .session) entry.session_id else null,
                .project_path = if (kind == .session) entry.project_path else null,
                .last_activity = if (kind == .session) entry.date else null,
                .totals = .{},
                .models = std.array_list.Managed([]const u8).init(allocator),
                .breakdowns = std.array_list.Managed(ModelBreakdown).init(allocator),
                .versions = std.array_list.Managed([]const u8).init(allocator),
            });
            try indexes.put(try allocator.dupe(u8, key), rows.items.len - 1);
            break :blk rows.items.len - 1;
        };
        addEntryToSummary(&rows.items[idx], entry) catch return error.OutOfMemory;
    }
    sortAllBreakdowns(rows.items);
    return rows;
}

fn summarizeBuckets(allocator: std.mem.Allocator, daily: []const Summary, kind: BucketKind, start: WeekDay) !std.array_list.Managed(Summary) {
    var rows = std.array_list.Managed(Summary).init(allocator);
    var indexes = std.StringHashMap(usize).init(allocator);
    for (daily) |row| {
        const bucket = switch (kind) {
            .monthly => row.label[0..@min(7, row.label.len)],
            .weekly => try weekStart(allocator, row.label, start),
        };
        const idx = indexes.get(bucket) orelse blk: {
            try rows.append(.{
                .label = try allocator.dupe(u8, bucket),
                .totals = .{},
                .models = std.array_list.Managed([]const u8).init(allocator),
                .breakdowns = std.array_list.Managed(ModelBreakdown).init(allocator),
                .versions = std.array_list.Managed([]const u8).init(allocator),
            });
            try indexes.put(try allocator.dupe(u8, bucket), rows.items.len - 1);
            break :blk rows.items.len - 1;
        };
        addSummaryToSummary(&rows.items[idx], row) catch return error.OutOfMemory;
    }
    sortAllBreakdowns(rows.items);
    return rows;
}

fn sortAllBreakdowns(rows: []Summary) void {
    for (rows) |*row| {
        std.mem.sort(ModelBreakdown, row.breakdowns.items, {}, breakdownCostDesc);
    }
}

fn breakdownCostDesc(_: void, a: ModelBreakdown, b: ModelBreakdown) bool {
    if (a.totals.cost == b.totals.cost) return a.first_timestamp < b.first_timestamp;
    return a.totals.cost > b.totals.cost;
}

fn addEntryToSummary(summary: *Summary, entry: Entry) !void {
    summary.totals.addUsage(entry.usage, entry.cost);
    if (entry.model) |model| {
        if (!containsString(summary.models.items, model)) try summary.models.append(model);
        for (summary.breakdowns.items) |*breakdown| {
            if (std.mem.eql(u8, breakdown.model, model)) {
                breakdown.totals.addUsage(entry.usage, entry.cost);
                return;
            }
        }
        var totals = TokenTotals{};
        totals.addUsage(entry.usage, entry.cost);
        try summary.breakdowns.append(.{ .model = model, .totals = totals, .first_timestamp = entry.timestamp });
    }
    if (entry.version) |version| {
        if (!containsString(summary.versions.items, version)) try summary.versions.append(version);
    }
    if (summary.last_activity) |last| {
        if (std.mem.order(u8, entry.date, last) == .gt) summary.last_activity = entry.date;
    }
}

fn addSummaryToSummary(dst: *Summary, src: Summary) !void {
    dst.totals.input_tokens += src.totals.input_tokens;
    dst.totals.output_tokens += src.totals.output_tokens;
    dst.totals.cache_creation_tokens += src.totals.cache_creation_tokens;
    dst.totals.cache_read_tokens += src.totals.cache_read_tokens;
    dst.totals.cost += src.totals.cost;
    for (src.models.items) |model| if (!containsString(dst.models.items, model)) try dst.models.append(model);
    for (src.breakdowns.items) |item| {
        var found = false;
        for (dst.breakdowns.items) |*breakdown| {
            if (std.mem.eql(u8, breakdown.model, item.model)) {
                breakdown.totals.input_tokens += item.totals.input_tokens;
                breakdown.totals.output_tokens += item.totals.output_tokens;
                breakdown.totals.cache_creation_tokens += item.totals.cache_creation_tokens;
                breakdown.totals.cache_read_tokens += item.totals.cache_read_tokens;
                breakdown.totals.cost += item.totals.cost;
                breakdown.first_timestamp = @min(breakdown.first_timestamp, item.first_timestamp);
                found = true;
                break;
            }
        }
        if (!found) try dst.breakdowns.append(item);
    }
}

fn runSessionId(allocator: std.mem.Allocator, args: Args, entries: []const Entry, id: []const u8) !void {
    var selected = std.array_list.Managed(Entry).init(allocator);
    defer selected.deinit();
    var totals = TokenTotals{};
    for (entries) |entry| {
        try selected.append(entry);
        totals.addUsage(entry.usage, entry.cost);
    }
    if (selected.items.len == 0) {
        if (args.json) try stdout().print("null\n", .{}) else try stderr().print("No session found with ID: {s}\n", .{id});
        return;
    }
    if (args.json) {
        var out = std.array_list.Managed(u8).init(allocator);
        defer out.deinit();
        try out.appendSlice("{\n  \"sessionId\": ");
        try writeJsonString(&out, id);
        try out.print(",\n  \"totalCost\": {d},\n  \"totalTokens\": {},\n  \"entries\": [\n", .{ totals.cost, totals.total() });
        for (selected.items, 0..) |entry, idx| {
            if (idx > 0) try out.appendSlice(",\n");
            try out.appendSlice("    {\"timestamp\":");
            try writeJsonString(&out, entry.timestamp_text);
            try out.print(",\"inputTokens\":{},\"outputTokens\":{},\"cacheCreationTokens\":{},\"cacheReadTokens\":{},\"model\":", .{
                entry.usage.input_tokens,
                entry.usage.output_tokens,
                entry.usage.cache_creation_input_tokens,
                entry.usage.cache_read_input_tokens,
            });
            try writeJsonString(&out, entry.model orelse "unknown");
            try out.print(",\"costUSD\":{d}}}", .{entry.cost_usd orelse 0});
        }
        try out.appendSlice("\n  ]\n}\n");
        return printMaybeJq(allocator, out.items, args.jq);
    }
    try stdout().print("Claude Code Session Usage - {s}\nTotal Cost: ${d:.2}\nTotal Tokens: {}\nTotal Entries: {}\n", .{ id, totals.cost, totals.total(), selected.items.len });
}

fn runBlocks(allocator: std.mem.Allocator, args: Args, entries: []const Entry) !void {
    if (args.session_length <= 0) return error.InvalidSessionLength;
    var blocks = try identifyBlocks(allocator, entries, args.session_length);
    defer deinitBlocks(blocks.items);
    filterBlocks(&blocks, args);
    sortBlocks(blocks.items, args.order);
    if (args.recent) filterRecent(&blocks);
    if (args.active) filterActive(&blocks);
    if (args.json) return printBlocksJson(allocator, blocks.items, args);
    try printBlocksTable(blocks.items, args);
}

fn identifyBlocks(allocator: std.mem.Allocator, entries_raw: []const Entry, hours: f64) !std.array_list.Managed(SessionBlock) {
    var entries = try allocator.dupe(Entry, entries_raw);
    std.mem.sort(Entry, entries, {}, timestampLessThan);
    var blocks = std.array_list.Managed(SessionBlock).init(allocator);
    if (entries.len == 0) return blocks;
    const duration_ms: i64 = @intFromFloat(hours * 60.0 * 60.0 * 1000.0);
    const now = nowMillis();
    var current_start: ?i64 = null;
    var start_index: usize = 0;
    var i: usize = 0;
    while (i < entries.len) : (i += 1) {
        const entry = entries[i];
        if (current_start) |start| {
            const last = entries[i - 1].timestamp;
            if (entry.timestamp - start > duration_ms or entry.timestamp - last > duration_ms) {
                try appendBlock(allocator, &blocks, entries[start_index..i], start, now, duration_ms);
                if (entry.timestamp - last > duration_ms) try appendGap(allocator, &blocks, last + duration_ms, entry.timestamp);
                current_start = floorHour(entry.timestamp);
                start_index = i;
            }
        } else {
            current_start = floorHour(entry.timestamp);
            start_index = i;
        }
    }
    if (current_start) |start| try appendBlock(allocator, &blocks, entries[start_index..], start, now, duration_ms);
    return blocks;
}

fn appendBlock(allocator: std.mem.Allocator, blocks: *std.array_list.Managed(SessionBlock), entries: []const Entry, start: i64, now: i64, duration_ms: i64) !void {
    var totals = TokenTotals{};
    var models = std.array_list.Managed([]const u8).init(allocator);
    var reset_time: ?i64 = null;
    for (entries) |entry| {
        totals.addUsage(entry.usage, entry.cost);
        if (entry.model) |model| if (!containsString(models.items, model)) try models.append(model);
        if (entry.reset_time) |reset| reset_time = reset;
    }
    const actual_end = if (entries.len > 0) entries[entries.len - 1].timestamp else start;
    const id = try formatIso(allocator, start);
    try blocks.append(.{
        .id = id,
        .start = start,
        .end = start + duration_ms,
        .actual_end = actual_end,
        .is_active = now - actual_end < duration_ms and now < start + duration_ms,
        .is_gap = false,
        .entries = entries.len,
        .totals = totals,
        .models = models,
        .reset_time = reset_time,
    });
}

fn appendGap(allocator: std.mem.Allocator, blocks: *std.array_list.Managed(SessionBlock), start: i64, end: i64) !void {
    const models = std.array_list.Managed([]const u8).init(allocator);
    const id_date = try formatIso(allocator, start);
    const id = try std.fmt.allocPrint(allocator, "gap-{s}", .{id_date});
    try blocks.append(.{
        .id = id,
        .start = start,
        .end = end,
        .actual_end = null,
        .is_active = false,
        .is_gap = true,
        .entries = 0,
        .totals = .{},
        .models = models,
        .reset_time = null,
    });
}

fn printDailyProjectsJson(allocator: std.mem.Allocator, rows: []const Summary, jq: ?[]const u8) !void {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    var projects = std.array_list.Managed([]const u8).init(allocator);
    defer projects.deinit();

    try out.appendSlice("{\n  \"projects\": {");
    for (rows) |row| {
        const project = row.project orelse "unknown";
        if (containsString(projects.items, project)) continue;
        if (projects.items.len > 0) try out.appendSlice(",");
        try projects.append(project);
        try out.appendSlice("\n    ");
        try writeJsonString(&out, project);
        try out.appendSlice(": [");
        var row_count: usize = 0;
        for (rows) |project_row| {
            const project_row_name = project_row.project orelse "unknown";
            if (!std.mem.eql(u8, project, project_row_name)) continue;
            if (row_count > 0) try out.appendSlice(",");
            try out.appendSlice("\n      {\n        ");
            try writeJsonStringField(&out, "date", project_row.label);
            try out.appendSlice(",\n");
            try writeUsageFields(&out, project_row);
            try out.appendSlice("\n      }");
            row_count += 1;
        }
        try out.appendSlice("\n    ]");
    }
    try out.appendSlice("\n  },\n  \"totals\": ");
    try writeTotalsJson(&out, totalsFor(rows));
    try out.appendSlice("\n}\n");
    try printMaybeJq(allocator, out.items, jq);
}

fn printSummaryJson(allocator: std.mem.Allocator, key: []const u8, rows: []const Summary, jq: ?[]const u8) !void {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    try out.print("{{\n  \"{s}\": [", .{key});
    for (rows, 0..) |row, idx| {
        if (idx > 0) try out.appendSlice(",");
        try out.append('\n');
        try writeSummaryJson(&out, row, key);
    }
    try out.appendSlice("\n  ],\n  \"totals\": ");
    try writeTotalsJson(&out, totalsFor(rows));
    try out.appendSlice("\n}\n");
    try printMaybeJq(allocator, out.items, jq);
}

fn printSessionJson(allocator: std.mem.Allocator, rows: []const Summary, jq: ?[]const u8) !void {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    try out.appendSlice("{\n  \"sessions\": [");
    for (rows, 0..) |row, idx| {
        if (idx > 0) try out.appendSlice(",");
        try out.append('\n');
        try writeSessionJson(&out, row);
    }
    try out.appendSlice("\n  ],\n  \"totals\": ");
    try writeTotalsJson(&out, totalsFor(rows));
    try out.appendSlice("\n}\n");
    try printMaybeJq(allocator, out.items, jq);
}

fn writeSessionJson(out: *std.array_list.Managed(u8), row: Summary) !void {
    try out.appendSlice("    {\n      \"sessionId\": ");
    try writeJsonString(out, row.session_id orelse row.label);
    try out.appendSlice(",\n");
    try writeUsageFields(out, row);
    try out.appendSlice(",\n      \"lastActivity\": ");
    try writeJsonString(out, row.last_activity orelse "");
    try out.appendSlice(",\n      \"projectPath\": ");
    try writeJsonString(out, row.project_path orelse "");
    try out.appendSlice("\n    }");
}

fn writeJsonString(out: *std.array_list.Managed(u8), value: []const u8) !void {
    const hex = "0123456789abcdef";
    try out.append('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try out.appendSlice("\\\""),
            '\\' => try out.appendSlice("\\\\"),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            0...8, 11...12, 14...0x1f => {
                try out.appendSlice("\\u00");
                try out.append(hex[byte >> 4]);
                try out.append(hex[byte & 0xf]);
            },
            else => try out.append(byte),
        }
    }
    try out.append('"');
}

fn writeJsonStringField(out: *std.array_list.Managed(u8), name: []const u8, value: []const u8) !void {
    try out.print("\"{s}\":", .{name});
    try writeJsonString(out, value);
}

fn writeSummaryJson(out: *std.array_list.Managed(u8), row: Summary, key: []const u8) !void {
    const field = if (std.mem.eql(u8, key, "daily")) "date" else if (std.mem.eql(u8, key, "weekly")) "week" else "month";
    try out.appendSlice("    {\n      ");
    try writeJsonStringField(out, field, row.label);
    try out.appendSlice(",\n");
    try writeUsageFields(out, row);
    if (row.project) |project| {
        try out.appendSlice(",\n      ");
        try writeJsonStringField(out, "project", project);
    }
    try out.appendSlice("\n    }");
}

fn writeUsageFields(out: *std.array_list.Managed(u8), row: Summary) !void {
    try out.print(
        \\      "inputTokens": {},
        \\      "outputTokens": {},
        \\      "cacheCreationTokens": {},
        \\      "cacheReadTokens": {},
        \\      "totalTokens": {},
        \\      "totalCost": {d},
        \\      "modelsUsed": [
    , .{ row.totals.input_tokens, row.totals.output_tokens, row.totals.cache_creation_tokens, row.totals.cache_read_tokens, row.totals.total(), row.totals.cost });
    for (row.models.items, 0..) |model, idx| {
        if (idx > 0) try out.appendSlice(", ");
        try writeJsonString(out, model);
    }
    try out.appendSlice("],\n      \"modelBreakdowns\": [");
    for (row.breakdowns.items, 0..) |breakdown, idx| {
        if (idx > 0) try out.appendSlice(", ");
        try out.appendSlice("{\"modelName\":");
        try writeJsonString(out, breakdown.model);
        try out.print(",\"inputTokens\":{},\"outputTokens\":{},\"cacheCreationTokens\":{},\"cacheReadTokens\":{},\"cost\":{d}}}", .{
            breakdown.totals.input_tokens,
            breakdown.totals.output_tokens,
            breakdown.totals.cache_creation_tokens,
            breakdown.totals.cache_read_tokens,
            breakdown.totals.cost,
        });
    }
    try out.append(']');
}

fn writeTotalsJson(out: *std.array_list.Managed(u8), totals: TokenTotals) !void {
    try out.print("{{\"inputTokens\":{},\"outputTokens\":{},\"cacheCreationTokens\":{},\"cacheReadTokens\":{},\"totalTokens\":{},\"totalCost\":{d}}}", .{
        totals.input_tokens,
        totals.output_tokens,
        totals.cache_creation_tokens,
        totals.cache_read_tokens,
        totals.total(),
        totals.cost,
    });
}

fn printBlocksJson(allocator: std.mem.Allocator, blocks: []const SessionBlock, args: Args) !void {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    const max_tokens = maxPreviousTokens(blocks);
    try out.appendSlice("{\n  \"blocks\": [");
    for (blocks, 0..) |block, idx| {
        if (idx > 0) try out.appendSlice(",");
        const start = try formatIso(allocator, block.start);
        const end = try formatIso(allocator, block.end);
        try out.appendSlice("\n    {\"id\":");
        try writeJsonString(&out, block.id);
        try out.appendSlice(",\"startTime\":");
        try writeJsonString(&out, start);
        try out.appendSlice(",\"endTime\":");
        try writeJsonString(&out, end);
        try out.appendSlice(",\"actualEndTime\":");
        if (block.actual_end) |actual| {
            const actual_s = try formatIso(allocator, actual);
            try writeJsonString(&out, actual_s);
        } else try out.appendSlice("null");
        try out.print(",\"isActive\":{},\"isGap\":{},\"entries\":{},\"tokenCounts\":{{\"inputTokens\":{},\"outputTokens\":{},\"cacheCreationInputTokens\":{},\"cacheReadInputTokens\":{}}},\"totalTokens\":{},\"costUSD\":{d},\"models\":[", .{
            block.is_active,
            block.is_gap,
            block.entries,
            block.totals.input_tokens,
            block.totals.output_tokens,
            block.totals.cache_creation_tokens,
            block.totals.cache_read_tokens,
            block.totals.total(),
            block.totals.cost,
        });
        for (block.models.items, 0..) |model, midx| {
            if (midx > 0) try out.appendSlice(",");
            try writeJsonString(&out, model);
        }
        try out.appendSlice("]");
        if (block.is_active) {
            if (burnRate(block)) |burn| {
                try out.print(",\"burnRate\":{{\"tokensPerMinute\":{d},\"tokensPerMinuteForIndicator\":{d},\"costPerHour\":{d}}}", .{ burn.tokens, burn.non_cache_tokens, burn.cost_hour });
            } else try out.appendSlice(",\"burnRate\":null");
            if (projection(block)) |proj| {
                try out.print(",\"projection\":{{\"totalTokens\":{},\"totalCost\":{d},\"remainingMinutes\":{}}}", .{ proj.tokens, proj.cost, proj.remaining });
                if (parseTokenLimit(args.token_limit, max_tokens)) |limit| {
                    const percent = @as(f64, @floatFromInt(proj.tokens)) / @as(f64, @floatFromInt(limit)) * 100.0;
                    const status = if (proj.tokens > limit) "exceeds" else if (@as(f64, @floatFromInt(proj.tokens)) > @as(f64, @floatFromInt(limit)) * BLOCKS_WARNING_THRESHOLD) "warning" else "ok";
                    try out.print(",\"tokenLimitStatus\":{{\"limit\":{},\"projectedUsage\":{},\"percentUsed\":{d},\"status\":\"{s}\"}}", .{ limit, proj.tokens, percent, status });
                }
            } else try out.appendSlice(",\"projection\":null");
        } else try out.appendSlice(",\"burnRate\":null,\"projection\":null");
        if (block.reset_time) |reset| {
            const reset_s = try formatIso(allocator, reset);
            try out.appendSlice(",\"usageLimitResetTime\":");
            try writeJsonString(&out, reset_s);
        }
        try out.append('}');
    }
    try out.appendSlice("\n  ]\n}\n");
    try printMaybeJq(allocator, out.items, args.jq);
}

fn printUsageTable(title: []const u8, first_col: []const u8, rows: []const Summary, show_breakdown: bool, force_compact: bool) !void {
    if (rows.len == 0) {
        try stderr().print("No Claude usage data found.\n", .{});
        return;
    }
    const compact = force_compact or terminalColumns() < 100;
    try printTitleBox(title);
    const widths = usageTableWidths(compact);
    try printBorder("┌", "┬", "┐", widths);
    try printUsageHeader(first_col, widths);
    try printBorder("├", "┼", "┤", widths);
    for (rows) |row| {
        try printSummaryDataRows(row, show_breakdown, widths);
    }
    try printUsageWrappedRow("Total", totalsFor(rows), &.{}, widths, ANSI_YELLOW);
    try printBorder("└", "┴", "┘", widths);
}

fn printSessionTable(title: []const u8, rows: []const Summary, show_breakdown: bool, force_compact: bool) !void {
    if (rows.len == 0) {
        try stderr().print("No Claude usage data found.\n", .{});
        return;
    }
    const compact = force_compact or terminalColumns() < 100;
    try printTitleBox(title);
    const widths = sessionTableWidths(compact);
    try printBorder9("┌", "┬", "┐", widths);
    try printSessionHeader(widths);
    try printBorder9("├", "┼", "┤", widths);
    for (rows) |row| {
        try printSessionDataRows(row, show_breakdown, widths);
    }
    try printSessionWrappedRow("Total", totalsFor(rows), &.{}, null, widths, ANSI_YELLOW);
    try printBorder9("└", "┴", "┘", widths);
}

fn printDailyProjectsTable(title: []const u8, first_col: []const u8, rows: []const Summary, show_breakdown: bool, force_compact: bool, aliases: ?[]const u8) !void {
    if (rows.len == 0) {
        try stderr().print("No Claude usage data found.\n", .{});
        return;
    }
    const compact = force_compact or terminalColumns() < 100;
    try printTitleBox(title);
    const widths = usageTableWidths(compact);
    try printBorder("┌", "┬", "┐", widths);
    try printUsageHeader(first_col, widths);
    try printBorder("├", "┼", "┤", widths);

    for (rows, 0..) |row, idx| {
        const project = row.project orelse continue;
        if (!isFirstProjectOccurrence(rows[0..idx], project)) continue;
        if (idx != 0) {
            try printEmptyTableLine(widths);
            try printBorder("├", "┼", "┤", widths);
        }
        try printProjectHeader(project, aliases, widths);
        try printBorder("├", "┼", "┤", widths);
        for (rows) |project_row| {
            if (project_row.project) |row_project| {
                if (std.mem.eql(u8, row_project, project)) {
                    try printSummaryDataRows(project_row, show_breakdown, widths);
                }
            }
        }
    }
    try printUsageWrappedRow("Total", totalsFor(rows), &.{}, widths, ANSI_YELLOW);
    try printBorder("└", "┴", "┘", widths);
}

fn printSummaryDataRows(row: Summary, show_breakdown: bool, widths: [8]usize) !void {
    try printUsageWrappedRow(row.label, row.totals, row.models.items, widths, null);
    try printBorder("├", "┼", "┤", widths);
    if (show_breakdown) {
        for (row.breakdowns.items) |breakdown| {
            var label_buf: [96]u8 = undefined;
            try printUsageWrappedRow(modelBreakdownLabel(breakdown.model, &label_buf), breakdown.totals, &.{}, widths, ANSI_GRAY);
            try printBorder("├", "┼", "┤", widths);
        }
    }
}

fn printSessionDataRows(row: Summary, show_breakdown: bool, widths: [9]usize) !void {
    try printSessionWrappedRow(row.label, row.totals, row.models.items, row.last_activity, widths, null);
    try printBorder9("├", "┼", "┤", widths);
    if (show_breakdown) {
        for (row.breakdowns.items) |breakdown| {
            var label_buf: [96]u8 = undefined;
            try printSessionWrappedRow(modelBreakdownLabel(breakdown.model, &label_buf), breakdown.totals, &.{}, null, widths, ANSI_GRAY);
            try printBorder9("├", "┼", "┤", widths);
        }
    }
}

fn hasProjectRows(rows: []const Summary) bool {
    for (rows) |row| if (row.project != null) return true;
    return false;
}

fn isFirstProjectOccurrence(previous: []const Summary, project: []const u8) bool {
    for (previous) |row| {
        if (row.project) |seen| {
            if (std.mem.eql(u8, seen, project)) return false;
        }
    }
    return true;
}

fn usageTableWidths(compact: bool) [8]usize {
    const columns = terminalColumns();
    const first_width: usize = if (compact or columns <= 120) 18 else 18;
    const model_width: usize = if (compact or columns <= 120) 18 else @min(@max(@as(usize, 22), columns / 3), @as(usize, 42));
    return .{ first_width, model_width, 8, 8, 8, 8, 8, 8 };
}

fn sessionTableWidths(compact: bool) [9]usize {
    const columns = terminalColumns();
    const model_width: usize = if (compact or columns <= 120) 16 else @min(@max(@as(usize, 20), columns / 4), @as(usize, 36));
    return .{ 18, model_width, 8, 8, 8, 8, 8, 8, 13 };
}

fn printBorder(left: []const u8, sep: []const u8, right: []const u8, widths: [8]usize) !void {
    try stdout().writeAll(ANSI_GRAY);
    try stdout().writeAll(left);
    for (widths, 0..) |width, idx| {
        try writeRepeat(stdout(), "─", width + 2);
        if (idx + 1 < widths.len) try stdout().writeAll(sep);
    }
    try stdout().writeAll(right);
    try stdout().writeAll(ANSI_RESET);
    try stdout().writeAll("\n");
}

fn printBorder9(left: []const u8, sep: []const u8, right: []const u8, widths: [9]usize) !void {
    try stdout().writeAll(ANSI_GRAY);
    try stdout().writeAll(left);
    for (widths, 0..) |width, idx| {
        try writeRepeat(stdout(), "─", width + 2);
        if (idx + 1 < widths.len) try stdout().writeAll(sep);
    }
    try stdout().writeAll(right);
    try stdout().writeAll(ANSI_RESET);
    try stdout().writeAll("\n");
}

fn printUsageHeader(first_col: []const u8, widths: [8]usize) !void {
    const top = [_][]const u8{ first_col, "Models", "Input", "Output", "Cache", "Cache", "Total", "Cost" };
    const bottom = [_][]const u8{ "", "", "", "", "Create", "Read", "Tokens", "(USD)" };
    try printTableLine(top, widths, .{ .right_from = 2, .color = ANSI_CYAN });
    try printTableLine(bottom, widths, .{ .right_from = 2, .color = ANSI_CYAN });
}

fn printSessionHeader(widths: [9]usize) !void {
    const top = [_][]const u8{ "Session", "Models", "Input", "Output", "Cache", "Cache", "Total", "Cost", "Last" };
    const bottom = [_][]const u8{ "", "", "", "", "Create", "Read", "Tokens", "(USD)", "Activity" };
    try printTableLine9(top, widths, .{ .right_from = 2, .color = ANSI_CYAN });
    try printTableLine9(bottom, widths, .{ .right_from = 2, .color = ANSI_CYAN });
}

const LineStyle = struct {
    right_from: usize,
    color: ?[]const u8 = null,
};

fn printTableLine(cells: [8][]const u8, widths: [8]usize, style: LineStyle) !void {
    try stdout().writeAll(ANSI_GRAY);
    try stdout().writeAll("│");
    try stdout().writeAll(ANSI_RESET);
    for (cells, 0..) |cell, idx| {
        try stdout().writeAll(" ");
        try writeCell(cell, widths[idx], idx >= style.right_from, style.color);
        try stdout().writeAll(" ");
        try stdout().writeAll(ANSI_GRAY);
        try stdout().writeAll("│");
        try stdout().writeAll(ANSI_RESET);
    }
    try stdout().writeAll("\n");
}

fn printTableLine9(cells: [9][]const u8, widths: [9]usize, style: LineStyle) !void {
    try stdout().writeAll(ANSI_GRAY);
    try stdout().writeAll("│");
    try stdout().writeAll(ANSI_RESET);
    for (cells, 0..) |cell, idx| {
        try stdout().writeAll(" ");
        try writeCell(cell, widths[idx], idx >= style.right_from, style.color);
        try stdout().writeAll(" ");
        try stdout().writeAll(ANSI_GRAY);
        try stdout().writeAll("│");
        try stdout().writeAll(ANSI_RESET);
    }
    try stdout().writeAll("\n");
}

fn printEmptyTableLine(widths: [8]usize) !void {
    const cells = [_][]const u8{ "", "", "", "", "", "", "", "" };
    try printTableLine(cells, widths, .{ .right_from = 2 });
}

fn printProjectHeader(project: []const u8, aliases: ?[]const u8, widths: [8]usize) !void {
    var project_buf: [128]u8 = undefined;
    const display = formatProjectName(project, aliases, &project_buf);
    const cells_top = [_][]const u8{ "Project:", "", "", "", "", "", "", "" };
    const cells_bottom = [_][]const u8{ display, "", "", "", "", "", "", "" };
    try printTableLine(cells_top, widths, .{ .right_from = 2, .color = ANSI_CYAN });
    try printTableLine(cells_bottom, widths, .{ .right_from = 2, .color = ANSI_CYAN });
}

fn printUsageWrappedRow(label_raw: []const u8, totals: TokenTotals, models: []const []const u8, widths: [8]usize, color: ?[]const u8) !void {
    var input_buf: [32]u8 = undefined;
    var output_buf: [32]u8 = undefined;
    var cache_create_buf: [32]u8 = undefined;
    var cache_read_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    var cost_buf: [32]u8 = undefined;
    const numeric = [_][]const u8{
        formatNumber(totals.input_tokens, &input_buf),
        formatNumber(totals.output_tokens, &output_buf),
        formatNumber(totals.cache_creation_tokens, &cache_create_buf),
        formatNumber(totals.cache_read_tokens, &cache_read_buf),
        formatNumber(totals.total(), &total_buf),
        formatCurrency(totals.cost, &cost_buf),
    };
    const date_lines = splitLabelLines(label_raw);
    const line_count = @max(date_lines.count, @max(@as(usize, 1), models.len));
    var line_idx: usize = 0;
    while (line_idx < line_count) : (line_idx += 1) {
        var model_buf: [96]u8 = undefined;
        const model_text = if (line_idx < models.len) modelBullet(models[line_idx], &model_buf) else "";
        const cells = [_][]const u8{
            if (line_idx < date_lines.count) date_lines.lines[line_idx] else "",
            model_text,
            if (line_idx == 0) numeric[0] else "",
            if (line_idx == 0) numeric[1] else "",
            if (line_idx == 0) numeric[2] else "",
            if (line_idx == 0) numeric[3] else "",
            if (line_idx == 0) numeric[4] else "",
            if (line_idx == 0) numeric[5] else "",
        };
        try printTableLine(cells, widths, .{ .right_from = 2, .color = color });
    }
}

fn printSessionWrappedRow(label_raw: []const u8, totals: TokenTotals, models: []const []const u8, last_activity: ?[]const u8, widths: [9]usize, color: ?[]const u8) !void {
    var input_buf: [32]u8 = undefined;
    var output_buf: [32]u8 = undefined;
    var cache_create_buf: [32]u8 = undefined;
    var cache_read_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    var cost_buf: [32]u8 = undefined;
    const numeric = [_][]const u8{
        formatNumber(totals.input_tokens, &input_buf),
        formatNumber(totals.output_tokens, &output_buf),
        formatNumber(totals.cache_creation_tokens, &cache_create_buf),
        formatNumber(totals.cache_read_tokens, &cache_read_buf),
        formatNumber(totals.total(), &total_buf),
        formatCurrency(totals.cost, &cost_buf),
    };
    const label_lines = splitLabelLines(label_raw);
    const activity_lines = if (last_activity) |activity| splitLabelLines(activity) else LabelLines{ .lines = .{ "", "" }, .count = 1 };
    const line_count = @max(@max(label_lines.count, activity_lines.count), @max(@as(usize, 1), models.len));
    var line_idx: usize = 0;
    while (line_idx < line_count) : (line_idx += 1) {
        var model_buf: [96]u8 = undefined;
        const model_text = if (line_idx < models.len) modelBullet(models[line_idx], &model_buf) else "";
        const cells = [_][]const u8{
            if (line_idx < label_lines.count) label_lines.lines[line_idx] else "",
            model_text,
            if (line_idx == 0) numeric[0] else "",
            if (line_idx == 0) numeric[1] else "",
            if (line_idx == 0) numeric[2] else "",
            if (line_idx == 0) numeric[3] else "",
            if (line_idx == 0) numeric[4] else "",
            if (line_idx == 0) numeric[5] else "",
            if (line_idx < activity_lines.count) activity_lines.lines[line_idx] else "",
        };
        try printTableLine9(cells, widths, .{ .right_from = 2, .color = color });
    }
}

const LabelLines = struct {
    lines: [2][]const u8,
    count: usize,
};

fn splitLabelLines(label: []const u8) LabelLines {
    if (label.len == 10 and label[4] == '-' and label[7] == '-') {
        return .{ .lines = .{ label[0..4], label[5..10] }, .count = 2 };
    }
    return .{ .lines = .{ label, "" }, .count = 1 };
}

fn modelBullet(model: []const u8, buf: []u8) []const u8 {
    var short_buf: [64]u8 = undefined;
    const display = shortModel(model, &short_buf);
    return std.fmt.bufPrint(buf, "- {s}", .{display}) catch "-";
}

fn modelBreakdownLabel(model: []const u8, buf: []u8) []const u8 {
    var short_buf: [64]u8 = undefined;
    const display = shortModel(model, &short_buf);
    return std.fmt.bufPrint(buf, "  └─ {s}", .{display}) catch "  └─";
}

fn formatProjectName(project: []const u8, aliases: ?[]const u8, buf: []u8) []const u8 {
    if (aliasForProject(project, aliases)) |alias| return alias;
    if (project.len == 0 or std.mem.eql(u8, project, "unknown")) return "Unknown Project";
    if (std.mem.indexOfScalar(u8, project, '/') != null) {
        return lastPathComponent(project);
    }
    if (std.mem.startsWith(u8, project, "-")) {
        var last = project;
        var it = std.mem.splitScalar(u8, project, '-');
        while (it.next()) |part| {
            if (part.len > 0) last = part;
        }
        if (last.len > 0 and last.len <= buf.len) return last;
    }
    return project;
}

fn aliasForProject(project: []const u8, aliases: ?[]const u8) ?[]const u8 {
    const raw_aliases = aliases orelse return null;
    var pairs = std.mem.splitScalar(u8, raw_aliases, ',');
    while (pairs.next()) |raw_pair| {
        const pair = std.mem.trim(u8, raw_pair, " \t\r\n");
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = std.mem.trim(u8, pair[0..eq], " \t\r\n");
        const value = std.mem.trim(u8, pair[eq + 1 ..], " \t\r\n");
        if (key.len > 0 and value.len > 0 and std.mem.eql(u8, key, project)) return value;
    }
    return null;
}

fn lastPathComponent(path: []const u8) []const u8 {
    var it = std.mem.splitAny(u8, path, "/\\");
    var last = path;
    while (it.next()) |part| {
        if (part.len > 0) last = part;
    }
    return last;
}

fn writeCell(text: []const u8, width: usize, right: bool, color: ?[]const u8) !void {
    var fit_buf: [128]u8 = undefined;
    const fitted = fitEllipsis(text, width, &fit_buf);
    const pad = if (width > fitted.len) width - fitted.len else 0;
    if (right) try writeRepeat(stdout(), " ", pad);
    if (color) |c| try stdout().writeAll(c);
    try stdout().writeAll(fitted);
    if (color != null) try stdout().writeAll(ANSI_RESET);
    if (!right) try writeRepeat(stdout(), " ", pad);
}

fn fitEllipsis(text: []const u8, width: usize, buf: []u8) []const u8 {
    if (text.len <= width) return text;
    if (width == 0) return "";
    if (width <= 3) return fit(text, buf[0..width]);
    const n = @min(width - 3, buf.len - 3);
    @memcpy(buf[0..n], text[0..n]);
    @memcpy(buf[n .. n + 3], "…");
    return buf[0 .. n + 3];
}

fn printUsageTableCompact(first_col: []const u8, rows: []const Summary, show_breakdown: bool) !void {
    try stdout().print("┌────────────┬────────────────────────┬────────────┬────────────┬────────────┐\n", .{});
    try stdout().print("│ {s}{s:<10}{s} │ {s}{s:<22}{s} │ {s}{s:>10}{s} │ {s}{s:>10}{s} │ {s}{s:>10}{s} │\n", .{
        ANSI_CYAN, first_col,    ANSI_RESET,
        ANSI_CYAN, "Models",     ANSI_RESET,
        ANSI_CYAN, "Input",      ANSI_RESET,
        ANSI_CYAN, "Output",     ANSI_RESET,
        ANSI_CYAN, "Cost (USD)", ANSI_RESET,
    });
    try stdout().print("├────────────┼────────────────────────┼────────────┼────────────┼────────────┤\n", .{});
    for (rows) |row| {
        try printUsageRowCompact(row.label, row.totals, row.models.items, null);
        if (show_breakdown) {
            for (row.breakdowns.items) |breakdown| {
                var label_buf: [96]u8 = undefined;
                try printUsageRowCompact(modelBreakdownLabel(breakdown.model, &label_buf), breakdown.totals, &.{}, ANSI_GRAY);
            }
        }
    }
    try stdout().print("├────────────┼────────────────────────┼────────────┼────────────┼────────────┤\n", .{});
    try printUsageRowCompact("Total", totalsFor(rows), &.{}, ANSI_YELLOW);
    try stdout().print("└────────────┴────────────────────────┴────────────┴────────────┴────────────┘\n", .{});
}

fn printUsageRow(label_raw: []const u8, totals: TokenTotals, models: []const []const u8) !void {
    var label_buf: [17]u8 = undefined;
    const label = fit(label_raw, &label_buf);
    var models_buf: [29]u8 = undefined;
    const model_text = joinModels(models, &models_buf);
    var input_buf: [32]u8 = undefined;
    var output_buf: [32]u8 = undefined;
    var cache_create_buf: [32]u8 = undefined;
    var cache_read_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    var cost_buf: [32]u8 = undefined;
    try stdout().print("│ {s:<16} │ {s:<28} │ {s:>10} │ {s:>10} │ {s:>12} │ {s:>10} │ {s:>12} │ {s:>10} │\n", .{
        label,
        model_text,
        formatNumber(totals.input_tokens, &input_buf),
        formatNumber(totals.output_tokens, &output_buf),
        formatNumber(totals.cache_creation_tokens, &cache_create_buf),
        formatNumber(totals.cache_read_tokens, &cache_read_buf),
        formatNumber(totals.total(), &total_buf),
        formatCurrency(totals.cost, &cost_buf),
    });
}

fn printUsageRowStyled(label_raw: []const u8, totals: TokenTotals, models: []const []const u8, color: []const u8) !void {
    var label_buf: [17]u8 = undefined;
    const label = fit(label_raw, &label_buf);
    var models_buf: [29]u8 = undefined;
    const model_text = joinModels(models, &models_buf);
    var input_buf: [32]u8 = undefined;
    var output_buf: [32]u8 = undefined;
    var cache_create_buf: [32]u8 = undefined;
    var cache_read_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    var cost_buf: [32]u8 = undefined;
    try stdout().print("│ {s}{s:<16}{s} │ {s}{s:<28}{s} │ {s}{s:>10}{s} │ {s}{s:>10}{s} │ {s}{s:>12}{s} │ {s}{s:>10}{s} │ {s}{s:>12}{s} │ {s}{s:>10}{s} │\n", .{
        color, label,                                                         ANSI_RESET,
        color, model_text,                                                    ANSI_RESET,
        color, formatNumber(totals.input_tokens, &input_buf),                 ANSI_RESET,
        color, formatNumber(totals.output_tokens, &output_buf),               ANSI_RESET,
        color, formatNumber(totals.cache_creation_tokens, &cache_create_buf), ANSI_RESET,
        color, formatNumber(totals.cache_read_tokens, &cache_read_buf),       ANSI_RESET,
        color, formatNumber(totals.total(), &total_buf),                      ANSI_RESET,
        color, formatCurrency(totals.cost, &cost_buf),                        ANSI_RESET,
    });
}

fn printUsageRowCompact(label_raw: []const u8, totals: TokenTotals, models: []const []const u8, color_opt: ?[]const u8) !void {
    var label_buf: [11]u8 = undefined;
    const label = fit(label_raw, &label_buf);
    var models_buf: [23]u8 = undefined;
    const model_text = joinModels(models, &models_buf);
    var input_buf: [32]u8 = undefined;
    var output_buf: [32]u8 = undefined;
    var cost_buf: [32]u8 = undefined;
    const color = color_opt orelse "";
    const reset = if (color_opt == null) "" else ANSI_RESET;
    try stdout().print("│ {s}{s:<10}{s} │ {s}{s:<22}{s} │ {s}{s:>10}{s} │ {s}{s:>10}{s} │ {s}{s:>10}{s} │\n", .{
        color, label,                                           reset,
        color, model_text,                                      reset,
        color, formatNumber(totals.input_tokens, &input_buf),   reset,
        color, formatNumber(totals.output_tokens, &output_buf), reset,
        color, formatCurrency(totals.cost, &cost_buf),          reset,
    });
}

fn printTitleBox(title: []const u8) !void {
    const width = @max(title.len + 2, @as(usize, 48));
    try stdout().writeAll("╭");
    try writeRepeat(stdout(), "─", width);
    try stdout().writeAll("╮\n│ ");
    try stdout().writeAll(title);
    try writeRepeat(stdout(), " ", width - title.len - 1);
    try stdout().writeAll("│\n╰");
    try writeRepeat(stdout(), "─", width);
    try stdout().writeAll("╯\n\n");
}

fn writeRepeat(writer: *std.Io.Writer, text: []const u8, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try writer.writeAll(text);
}

fn terminalColumns() usize {
    if (env_map.get("COLUMNS")) |value| {
        return std.fmt.parseInt(usize, value, 10) catch 120;
    }
    return 120;
}

fn printBlocksTable(blocks: []const SessionBlock, args: Args) !void {
    if (blocks.len == 0) {
        try stderr().print("No Claude usage data found.\n", .{});
        return;
    }
    const limit = parseTokenLimit(args.token_limit, maxPreviousTokens(blocks));
    try printTitleBox("Claude Code Token Usage Report - Session Blocks");
    try stdout().print("┌──────────────────────────┬──────────────┬──────────────────────────────┬────────────┬──────────┬────────────┐\n", .{});
    try stdout().print("│ {s}{s:<24}{s} │ {s}{s:<12}{s} │ {s}{s:<28}{s} │ {s}{s:>10}{s} │ {s}{s:>8}{s} │ {s}{s:>10}{s} │\n", .{
        ANSI_CYAN, "Block Start", ANSI_RESET,
        ANSI_CYAN, "Status",      ANSI_RESET,
        ANSI_CYAN, "Models",      ANSI_RESET,
        ANSI_CYAN, "Tokens",      ANSI_RESET,
        ANSI_CYAN, "%",           ANSI_RESET,
        ANSI_CYAN, "Cost",        ANSI_RESET,
    });
    try stdout().print("├──────────────────────────┼──────────────┼──────────────────────────────┼────────────┼──────────┼────────────┤\n", .{});
    for (blocks) |block| {
        var start_buf: [32]u8 = undefined;
        const start = try formatIsoBuf(block.start, &start_buf);
        var model_buf: [29]u8 = undefined;
        var token_buf: [32]u8 = undefined;
        var cost_buf: [32]u8 = undefined;
        var percent_buf: [32]u8 = undefined;
        const percent = if (limit) |l| try std.fmt.bufPrint(&percent_buf, "{d:.1}%", .{@as(f64, @floatFromInt(block.totals.total())) / @as(f64, @floatFromInt(l)) * 100.0}) else "-";
        try stdout().print("│ {s:<24} │ {s:<12} │ {s:<28} │ {s:>10} │ {s:>8} │ {s:>10} │\n", .{
            fit(start, start_buf[0..24]),
            if (block.is_gap) "(inactive)" else if (block.is_active) "ACTIVE" else "",
            joinModels(block.models.items, &model_buf),
            if (block.is_gap) "-" else formatNumber(block.totals.total(), &token_buf),
            percent,
            if (block.is_gap) "-" else formatCurrency(block.totals.cost, &cost_buf),
        });
    }
    try stdout().print("└──────────────────────────┴──────────────┴──────────────────────────────┴────────────┴──────────┴────────────┘\n", .{});
}

fn printMaybeJq(allocator: std.mem.Allocator, json_text: []const u8, jq: ?[]const u8) !void {
    const filter = jq orelse {
        try stdout().writeAll(json_text);
        return;
    };
    const tmp = try std.fmt.allocPrint(allocator, "/tmp/ccusage-zig-{d}.json", .{std.Io.Timestamp.now(process_io, .real).toMicroseconds()});
    try std.Io.Dir.cwd().writeFile(process_io, .{ .sub_path = tmp, .data = json_text });
    defer std.Io.Dir.cwd().deleteFile(process_io, tmp) catch {};
    const result = try std.process.run(allocator, process_io, .{ .argv = &.{ "jq", filter, tmp }, .stdout_limit = .unlimited, .stderr_limit = .limited(64 * 1024) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            try stderr().writeAll(result.stderr);
            return error.JqFailed;
        },
        else => return error.JqFailed,
    }
    try stdout().writeAll(result.stdout);
}

fn jsonObjectField(json: []const u8, key: []const u8) ?[]const u8 {
    const value = jsonFieldValue(json, key) orelse return null;
    return if (value.len > 0 and value[0] == '{') value else null;
}

fn jsonStringField(json: []const u8, key: []const u8) ?[]const u8 {
    const value = jsonFieldValue(json, key) orelse return null;
    if (value.len < 2 or value[0] != '"') return null;
    return value[1 .. value.len - 1];
}

fn jsonU64Field(json: []const u8, key: []const u8) ?u64 {
    const value = std.mem.trim(u8, jsonFieldValue(json, key) orelse return null, " \t\r\n");
    if (value.len == 0 or value[0] == '-') return null;
    var total: u64 = 0;
    var saw_digit = false;
    for (value) |ch| {
        if (ch < '0' or ch > '9') break;
        saw_digit = true;
        total = std.math.mul(u64, total, 10) catch return null;
        total = std.math.add(u64, total, ch - '0') catch return null;
    }
    return if (saw_digit) total else null;
}

fn jsonF64Field(json: []const u8, key: []const u8) ?f64 {
    const value = std.mem.trim(u8, jsonFieldValue(json, key) orelse return null, " \t\r\n");
    if (value.len == 0) return null;
    return std.fmt.parseFloat(f64, value) catch null;
}

fn jsonBoolField(json: []const u8, key: []const u8) ?bool {
    const value = std.mem.trim(u8, jsonFieldValue(json, key) orelse return null, " \t\r\n");
    if (std.mem.startsWith(u8, value, "true")) return true;
    if (std.mem.startsWith(u8, value, "false")) return false;
    return null;
}

fn jsonFieldValue(json: []const u8, key: []const u8) ?[]const u8 {
    if (json.len < 2 or json[0] != '{') return null;
    var i: usize = 1;
    while (i < json.len) {
        while (i < json.len and (isJsonSpace(json[i]) or json[i] == ',')) i += 1;
        if (i >= json.len or json[i] == '}') return null;
        if (json[i] != '"') return null;
        const key_start = i;
        const key_end = jsonStringEnd(json, i) orelse return null;
        i = key_end + 1;
        while (i < json.len and isJsonSpace(json[i])) i += 1;
        if (i >= json.len or json[i] != ':') return null;
        i += 1;
        while (i < json.len and isJsonSpace(json[i])) i += 1;
        const value = jsonValueSlice(json, i) orelse return null;
        if (std.mem.eql(u8, json[key_start .. key_end + 1], key)) return value;
        i = @intFromPtr(value.ptr) - @intFromPtr(json.ptr) + value.len;
    }
    return null;
}

fn jsonValueSlice(json: []const u8, start: usize) ?[]const u8 {
    if (start >= json.len) return null;
    return switch (json[start]) {
        '"' => if (jsonStringEnd(json, start)) |end| json[start .. end + 1] else null,
        '{' => jsonBalancedSlice(json, start, '{', '}'),
        '[' => jsonBalancedSlice(json, start, '[', ']'),
        else => {
            var end = start;
            while (end < json.len and json[end] != ',' and json[end] != '}' and json[end] != ']') end += 1;
            return std.mem.trim(u8, json[start..end], " \t\r\n");
        },
    };
}

fn jsonStringEnd(json: []const u8, start: usize) ?usize {
    if (start >= json.len or json[start] != '"') return null;
    var i = start + 1;
    var escaped = false;
    while (i < json.len) : (i += 1) {
        const ch = json[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch == '\\') {
            escaped = true;
            continue;
        }
        if (ch == '"') return i;
    }
    return null;
}

fn jsonBalancedSlice(json: []const u8, start: usize, open: u8, close: u8) ?[]const u8 {
    if (start >= json.len or json[start] != open) return null;
    var depth: usize = 0;
    var i = start;
    while (i < json.len) : (i += 1) {
        const ch = json[i];
        if (ch == '"') {
            i = jsonStringEnd(json, i) orelse return null;
            continue;
        }
        if (ch == open) depth += 1;
        if (ch == close) {
            depth -= 1;
            if (depth == 0) return json[start .. i + 1];
        }
    }
    return null;
}

fn isJsonSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

fn indexOfNeedle(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    const vector_len = comptime std.simd.suggestVectorLength(u8) orelse 16;
    const Vec = @Vector(vector_len, u8);
    const first: Vec = @splat(needle[0]);
    var i: usize = 0;
    while (i + vector_len <= haystack.len) : (i += vector_len) {
        const chunk: Vec = @as(Vec, haystack[i..][0..vector_len].*);
        const matches = chunk == first;
        if (@reduce(.Or, matches)) {
            comptime var j: usize = 0;
            inline while (j < vector_len) : (j += 1) {
                if (matches[j]) {
                    const candidate = i + j;
                    if (candidate + needle.len <= haystack.len and std.mem.eql(u8, haystack[candidate .. candidate + needle.len], needle)) return candidate;
                }
            }
        }
    }
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (haystack[i] == needle[0] and std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn objectField(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .object => |child| child,
        else => null,
    };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn boolField(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn numberField(object: std.json.ObjectMap, key: []const u8) ?f64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn dateInRange(date: []const u8, since: ?[]const u8, until: ?[]const u8) bool {
    var compact_buf: [8]u8 = undefined;
    if (date.len < 10) return false;
    @memcpy(compact_buf[0..4], date[0..4]);
    @memcpy(compact_buf[4..6], date[5..7]);
    @memcpy(compact_buf[6..8], date[8..10]);
    const compact = compact_buf[0..8];
    if (since) |s| if (std.mem.order(u8, compact, s) == .lt) return false;
    if (until) |u| if (std.mem.order(u8, compact, u) == .gt) return false;
    return true;
}

fn displayModel(allocator: std.mem.Allocator, model: []const u8, fast: bool) !?[]const u8 {
    if (std.mem.eql(u8, model, "<synthetic>")) return null;
    if (fast) return try std.fmt.allocPrint(allocator, "{s}-fast", .{model});
    return model;
}

fn containsString(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

fn shortSession(session_id: []const u8) []const u8 {
    var last: usize = 0;
    var second_last: usize = 0;
    for (session_id, 0..) |ch, idx| {
        if (ch == '-') {
            second_last = last;
            last = idx + 1;
        }
    }
    return if (second_last > 0) session_id[second_last..] else session_id;
}

fn totalsFor(rows: []const Summary) TokenTotals {
    var totals = TokenTotals{};
    for (rows) |row| {
        totals.input_tokens += row.totals.input_tokens;
        totals.output_tokens += row.totals.output_tokens;
        totals.cache_creation_tokens += row.totals.cache_creation_tokens;
        totals.cache_read_tokens += row.totals.cache_read_tokens;
        totals.cost += row.totals.cost;
    }
    return totals;
}

fn sortSummaries(rows: []Summary, order: SortOrder) void {
    std.mem.sort(Summary, rows, order, summaryLessThan);
}

fn sortSummariesByCost(rows: []Summary) void {
    std.mem.sort(Summary, rows, {}, summaryCostDesc);
}

fn summaryLessThan(order: SortOrder, a: Summary, b: Summary) bool {
    return switch (order) {
        .asc => std.mem.order(u8, a.label, b.label) == .lt,
        .desc => std.mem.order(u8, a.label, b.label) == .gt,
    };
}

fn summaryCostDesc(_: void, a: Summary, b: Summary) bool {
    return a.totals.cost > b.totals.cost;
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn timestampLessThan(_: void, a: Entry, b: Entry) bool {
    return a.timestamp < b.timestamp;
}

fn filterBlocks(blocks: *std.array_list.Managed(SessionBlock), args: Args) void {
    if (args.since == null and args.until == null) return;
    var write: usize = 0;
    for (blocks.items) |block| {
        var buf: [32]u8 = undefined;
        const date = formatDateBuf(block.start + timezoneOffsetMillis(block.start, args.timezone), &buf) catch continue;
        if (dateInRange(date, args.since, args.until)) {
            blocks.items[write] = block;
            write += 1;
        }
    }
    blocks.items.len = write;
}

fn filterRecent(blocks: *std.array_list.Managed(SessionBlock)) void {
    const cutoff = nowMillis() - RECENT_DAYS * 24 * 60 * 60 * 1000;
    var write: usize = 0;
    for (blocks.items) |block| {
        if (block.start >= cutoff or block.is_active) {
            blocks.items[write] = block;
            write += 1;
        }
    }
    blocks.items.len = write;
}

fn filterActive(blocks: *std.array_list.Managed(SessionBlock)) void {
    var write: usize = 0;
    for (blocks.items) |block| {
        if (block.is_active) {
            blocks.items[write] = block;
            write += 1;
        }
    }
    blocks.items.len = write;
}

fn sortBlocks(blocks: []SessionBlock, order: SortOrder) void {
    std.mem.sort(SessionBlock, blocks, order, blockLessThan);
}

fn blockLessThan(order: SortOrder, a: SessionBlock, b: SessionBlock) bool {
    return switch (order) {
        .asc => a.start < b.start,
        .desc => a.start > b.start,
    };
}

fn maxPreviousTokens(blocks: []const SessionBlock) u64 {
    var max: u64 = 0;
    for (blocks) |block| {
        if (!block.is_gap and !block.is_active) max = @max(max, block.totals.total());
    }
    return max;
}

fn parseTokenLimit(value: ?[]const u8, max_tokens: u64) ?u64 {
    const raw = value orelse return if (max_tokens > 0) max_tokens else null;
    if (raw.len == 0 or std.mem.eql(u8, raw, "max")) return if (max_tokens > 0) max_tokens else null;
    return std.fmt.parseInt(u64, raw, 10) catch null;
}

fn nowMillis() i64 {
    return std.Io.Timestamp.now(process_io, .real).toMilliseconds();
}

const Burn = struct { tokens: f64, non_cache_tokens: f64, cost_hour: f64 };
const Proj = struct { tokens: u64, cost: f64, remaining: u64 };

fn burnRate(block: SessionBlock) ?Burn {
    if (block.is_gap or block.actual_end == null) return null;
    const elapsed = @as(f64, @floatFromInt(block.actual_end.? - block.start)) / 60000.0;
    if (elapsed <= 0) return null;
    return .{
        .tokens = @as(f64, @floatFromInt(block.totals.total())) / elapsed,
        .non_cache_tokens = @as(f64, @floatFromInt(block.totals.input_tokens + block.totals.output_tokens)) / elapsed,
        .cost_hour = block.totals.cost / elapsed * 60.0,
    };
}

fn projection(block: SessionBlock) ?Proj {
    if (!block.is_active or block.is_gap) return null;
    const burn = burnRate(block) orelse return null;
    const remaining_f = @max(0.0, @as(f64, @floatFromInt(block.end - nowMillis())) / 60000.0);
    return .{
        .tokens = @intFromFloat(@round(@as(f64, @floatFromInt(block.totals.total())) + burn.tokens * remaining_f)),
        .cost = round2(block.totals.cost + burn.cost_hour / 60.0 * remaining_f),
        .remaining = @intFromFloat(@round(remaining_f)),
    };
}

fn round2(value: f64) f64 {
    return @round(value * 100.0) / 100.0;
}

fn weekStart(allocator: std.mem.Allocator, date: []const u8, start: WeekDay) ![]const u8 {
    if (date.len < 10) return allocator.dupe(u8, date);
    const y = try std.fmt.parseInt(i32, date[0..4], 10);
    const m = try std.fmt.parseInt(u8, date[5..7], 10);
    const d = try std.fmt.parseInt(u8, date[8..10], 10);
    const z = daysFromCivil(y, m, d);
    const dow_sunday = @mod(z + 4, 7);
    const start_num: i64 = @intFromEnum(start);
    const shift = @mod(dow_sunday - start_num + 7, 7);
    return formatDateAlloc(allocator, (z - shift) * 86_400_000);
}

fn parseTimestamp(s: []const u8) ?i64 {
    if (s.len < 20) return null;
    const y: i32 = @intCast(parseFixedDigits(s[0..4]) orelse return null);
    const mo: u8 = @intCast(parseFixedDigits(s[5..7]) orelse return null);
    const d: u8 = @intCast(parseFixedDigits(s[8..10]) orelse return null);
    const h: u8 = @intCast(parseFixedDigits(s[11..13]) orelse return null);
    const mi: u8 = @intCast(parseFixedDigits(s[14..16]) orelse return null);
    const sec: u8 = @intCast(parseFixedDigits(s[17..19]) orelse return null);
    var ms: i64 = 0;
    if (s.len >= 24 and s[19] == '.') ms = @intCast(parseFixedDigits(s[20..23]) orelse 0);
    const days = daysFromCivil(y, mo, d);
    return (((days * 24 + h) * 60 + mi) * 60 + sec) * 1000 + ms;
}

fn parseFixedDigits(bytes: []const u8) ?u64 {
    var value: u64 = 0;
    for (bytes) |ch| {
        if (ch < '0' or ch > '9') return null;
        value = value * 10 + ch - '0';
    }
    return value;
}

fn floorHour(ms: i64) i64 {
    const hour = 60 * 60 * 1000;
    return @divFloor(ms, hour) * hour;
}

fn daysFromCivil(y_raw: i32, m_raw: u8, d_raw: u8) i64 {
    var y: i64 = y_raw;
    const m: i64 = m_raw;
    const d: i64 = d_raw;
    y -= if (m <= 2) 1 else 0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = m + if (m > 2) @as(i64, -3) else @as(i64, 9);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(z_raw: i64) struct { y: i64, m: i64, d: i64 } {
    const z = z_raw + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = mp + if (mp < 10) @as(i64, 3) else @as(i64, -9);
    y += if (m <= 2) 1 else 0;
    return .{ .y = y, .m = m, .d = d };
}

fn formatDateAlloc(allocator: std.mem.Allocator, ms: i64) ![]const u8 {
    var buf: [32]u8 = undefined;
    return allocator.dupe(u8, try formatDateBuf(ms, &buf));
}

fn formatDateForTimezone(allocator: std.mem.Allocator, ms: i64, timezone: ?[]const u8) ![]const u8 {
    return formatDateAlloc(allocator, ms + timezoneOffsetMillis(ms, timezone));
}

fn timezoneOffsetMillis(ms: i64, timezone: ?[]const u8) i64 {
    if (timezone) |tz| {
        if (std.mem.eql(u8, tz, "UTC")) return 0;
        if (!std.mem.eql(u8, tz, "Europe/London")) return 0;
    }
    return londonOffsetMillis(ms);
}

fn londonOffsetMillis(ms: i64) i64 {
    const days = @divFloor(ms, 86_400_000);
    const c = civilFromDays(days);
    const start = londonDstTransition(c.y, 3);
    const end = londonDstTransition(c.y, 10);
    return if (ms >= start and ms < end) 3_600_000 else 0;
}

fn londonDstTransition(year: i64, month: u8) i64 {
    const last_day: u8 = 31;
    const last_day_index = daysFromCivil(@intCast(year), month, last_day);
    const dow_sunday = @mod(last_day_index + 4, 7);
    const last_sunday = @as(i64, last_day) - dow_sunday;
    return (daysFromCivil(@intCast(year), month, @intCast(last_sunday)) * 24 + 1) * 60 * 60 * 1000;
}

fn formatDateBuf(ms: i64, buf: []u8) ![]const u8 {
    const days = @divFloor(ms, 86_400_000);
    const c = civilFromDays(days);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u64, @intCast(c.y)),
        @as(u64, @intCast(c.m)),
        @as(u64, @intCast(c.d)),
    });
}

fn formatIso(allocator: std.mem.Allocator, ms: i64) ![]const u8 {
    var buf: [40]u8 = undefined;
    return allocator.dupe(u8, try formatIsoBuf(ms, &buf));
}

fn formatIsoBuf(ms: i64, buf: []u8) ![]const u8 {
    const days = @divFloor(ms, 86_400_000);
    const rem = @mod(ms, 86_400_000);
    const c = civilFromDays(days);
    const h = @divFloor(rem, 3_600_000);
    const m = @divFloor(@mod(rem, 3_600_000), 60_000);
    const s = @divFloor(@mod(rem, 60_000), 1000);
    const milli = @mod(rem, 1000);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        @as(u64, @intCast(c.y)),
        @as(u64, @intCast(c.m)),
        @as(u64, @intCast(c.d)),
        @as(u64, @intCast(h)),
        @as(u64, @intCast(m)),
        @as(u64, @intCast(s)),
        @as(u64, @intCast(milli)),
    });
}

fn formatNumber(value: u64, buf: []u8) []const u8 {
    var tmp: [32]u8 = undefined;
    const raw = std.fmt.bufPrint(&tmp, "{}", .{value}) catch return "";
    var out_i: usize = buf.len;
    var count: usize = 0;
    var i = raw.len;
    while (i > 0 and out_i > 0) {
        if (count == 3) {
            out_i -= 1;
            buf[out_i] = ',';
            count = 0;
        }
        i -= 1;
        out_i -= 1;
        buf[out_i] = raw[i];
        count += 1;
    }
    return buf[out_i..];
}

fn formatCurrency(value: f64, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "${d:.2}", .{value}) catch "";
}

fn joinModels(models: []const []const u8, buf: []u8) []const u8 {
    if (models.len == 0) return "-";
    var pos: usize = 0;
    for (models, 0..) |model, idx| {
        if (idx > 0 and pos + 2 < buf.len) {
            buf[pos] = ',';
            buf[pos + 1] = ' ';
            pos += 2;
        }
        const remain = buf.len - pos;
        if (remain == 0) break;
        var short_buf: [48]u8 = undefined;
        const display = shortModel(model, &short_buf);
        const n = @min(display.len, remain);
        @memcpy(buf[pos .. pos + n], display[0..n]);
        pos += n;
    }
    return fit(buf[0..pos], buf);
}

fn shortModel(model: []const u8, buf: []u8) []const u8 {
    if (std.mem.startsWith(u8, model, "[pi] ")) {
        const inner = shortModel(model[5..], buf[5..]);
        if (buf.len < inner.len + 5) return fit(model, buf);
        @memcpy(buf[0..5], "[pi] ");
        return buf[0 .. inner.len + 5];
    }
    if (std.mem.startsWith(u8, model, "anthropic/claude-")) return shortClaudeModel(model["anthropic/claude-".len..], buf) orelse fit(model, buf);
    if (std.mem.startsWith(u8, model, "claude-")) return shortClaudeModel(model["claude-".len..], buf) orelse fit(model, buf);
    return fit(model, buf);
}

fn shortClaudeModel(rest: []const u8, buf: []u8) ?[]const u8 {
    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse return null;
    const family = rest[0..dash];
    var version_end = rest.len;
    if (rest.len >= 9 and rest[rest.len - 9] == '-' and allDigits(rest[rest.len - 8 ..])) version_end = rest.len - 9;
    const version = rest[dash + 1 .. version_end];
    if (family.len == 0 or version.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}-{s}", .{ family, version }) catch null;
}

fn allDigits(text: []const u8) bool {
    for (text) |ch| if (ch < '0' or ch > '9') return false;
    return true;
}

fn fit(text: []const u8, buf: []u8) []const u8 {
    if (text.len <= buf.len) return text;
    if (buf.len == 0) return "";
    const n = if (buf.len > 1) buf.len - 1 else 1;
    @memcpy(buf[0..n], text[0..n]);
    if (buf.len > 1) buf[n] = '~';
    return buf[0..buf.len];
}

fn deinitSummaries(rows: []Summary) void {
    for (rows) |row| {
        row.models.deinit();
        row.breakdowns.deinit();
        row.versions.deinit();
    }
}

fn deinitBlocks(blocks: []SessionBlock) void {
    for (blocks) |block| block.models.deinit();
}

test "tiered cost above 200k" {
    try std.testing.expectApproxEqAbs(1.2, tiered(300_000, 3e-6, 6e-6), 0.0000001);
}

test "token totals match TypeScript token utility cases" {
    try std.testing.expectEqual(@as(u64, 3800), (TokenUsage{
        .input_tokens = 1000,
        .output_tokens = 500,
        .cache_creation_input_tokens = 2000,
        .cache_read_input_tokens = 300,
    }).total());
    try std.testing.expectEqual(@as(u64, 0), (TokenUsage{}).total());
    try std.testing.expectEqual(@as(u64, 1500), (TokenUsage{
        .input_tokens = 1000,
        .output_tokens = 500,
    }).total());
}

test "token aggregation matches TypeScript calculateTotals cases" {
    var totals = TokenTotals{};
    totals.addUsage(.{
        .input_tokens = 100,
        .output_tokens = 50,
        .cache_creation_input_tokens = 25,
        .cache_read_input_tokens = 10,
    }, 0.01);
    totals.addUsage(.{
        .input_tokens = 200,
        .output_tokens = 100,
        .cache_creation_input_tokens = 50,
        .cache_read_input_tokens = 20,
    }, 0.02);

    try std.testing.expectEqual(@as(u64, 300), totals.input_tokens);
    try std.testing.expectEqual(@as(u64, 150), totals.output_tokens);
    try std.testing.expectEqual(@as(u64, 75), totals.cache_creation_tokens);
    try std.testing.expectEqual(@as(u64, 30), totals.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 555), totals.total());
    try std.testing.expectApproxEqAbs(0.03, totals.cost, 0.0000001);
}

test "date range filtering matches TypeScript date utility cases" {
    try std.testing.expect(dateInRange("2024-01-03", null, null));
    try std.testing.expect(!dateInRange("2024-01-02", "20240103", null));
    try std.testing.expect(dateInRange("2024-01-03", "20240103", null));
    try std.testing.expect(dateInRange("2024-01-03", null, "20240103"));
    try std.testing.expect(!dateInRange("2024-01-04", null, "20240103"));
    try std.testing.expect(dateInRange("2024-01-03T10:00:00Z", "20240102", "20240104"));
    try std.testing.expect(!dateInRange("bad", "20240102", null));
}

test "week start" {
    const allocator = std.testing.allocator;
    const sunday = try weekStart(allocator, "2024-01-03", .sunday);
    defer allocator.free(sunday);
    try std.testing.expectEqualStrings("2023-12-31", sunday);
    const monday = try weekStart(allocator, "2024-01-03", .monday);
    defer allocator.free(monday);
    try std.testing.expectEqualStrings("2024-01-01", monday);
    const already_monday = try weekStart(allocator, "2024-01-01", .monday);
    defer allocator.free(already_monday);
    try std.testing.expectEqualStrings("2024-01-01", already_monday);
    const already_sunday = try weekStart(allocator, "2023-12-31", .sunday);
    defer allocator.free(already_sunday);
    try std.testing.expectEqualStrings("2023-12-31", already_sunday);
}

test "timestamp formatting round-trips UTC dates" {
    const timestamp = parseTimestamp("2024-08-04T12:34:56.789Z") orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(i64, 1722774896789), timestamp);
    var date_buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2024-08-04", try formatDateBuf(timestamp, &date_buf));
    var iso_buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("2024-08-04T12:34:56.789Z", try formatIsoBuf(timestamp, &iso_buf));
    try std.testing.expectEqual(@as(?i64, null), parseTimestamp("not-a-date"));
}

test "token limit parsing matches blocks option cases" {
    try std.testing.expectEqual(@as(?u64, 42), parseTokenLimit("42", 100));
    try std.testing.expectEqual(@as(?u64, 100), parseTokenLimit("max", 100));
    try std.testing.expectEqual(@as(?u64, 100), parseTokenLimit("", 100));
    try std.testing.expectEqual(@as(?u64, null), parseTokenLimit("bad", 100));
    try std.testing.expectEqual(@as(?u64, null), parseTokenLimit(null, 0));
    try std.testing.expectEqual(@as(?u64, 100), parseTokenLimit(null, 100));
}

test "usage limit reset time is extracted from api error message" {
    const line = "{\"isApiErrorMessage\":true,\"message\":{\"content\":[{\"text\":\"Claude AI usage limit reached|1736337600\"}]}}";
    try std.testing.expectEqual(@as(?i64, 1736337600000), usageLimitResetTime(line));
    try std.testing.expectEqual(@as(?i64, null), usageLimitResetTime("{\"message\":{\"content\":[]}}"));
}

test "argument parsing matches supported JavaScript CLI options" {
    const argv = [_][]const u8{
        "weekly",
        "--since",
        "20240101",
        "--until",
        "20240131",
        "--json",
        "--mode",
        "display",
        "--debug",
        "--debug-samples",
        "2",
        "--order",
        "desc",
        "--breakdown",
        "--offline",
        "--timezone",
        "UTC",
        "--jq",
        ".weekly",
        "--project-aliases",
        "project-a=Project A",
        "--start-of-week",
        "monday",
        "--no-color",
    };
    const args = try parseArgs(&argv);
    try std.testing.expectEqual(Command.weekly, args.command);
    try std.testing.expectEqualStrings("20240101", args.since.?);
    try std.testing.expectEqualStrings("20240131", args.until.?);
    try std.testing.expect(args.json);
    try std.testing.expectEqual(CostMode.display, args.mode);
    try std.testing.expect(args.debug);
    try std.testing.expectEqual(@as(usize, 2), args.debug_samples);
    try std.testing.expectEqual(SortOrder.desc, args.order);
    try std.testing.expect(args.breakdown);
    try std.testing.expect(args.offline);
    try std.testing.expectEqualStrings("UTC", args.timezone.?);
    try std.testing.expectEqualStrings(".weekly", args.jq.?);
    try std.testing.expectEqualStrings("project-a=Project A", args.project_aliases.?);
    try std.testing.expectEqual(WeekDay.monday, args.start_of_week);
    try std.testing.expectEqual(false, args.color.?);
    try std.testing.expect(args.explicit.color);
}

test "session shorthand and blocks options parse like JavaScript CLI" {
    const session_argv = [_][]const u8{ "session", "-i", "session-id" };
    const session_args = try parseArgs(&session_argv);
    try std.testing.expectEqual(Command.session, session_args.command);
    try std.testing.expectEqualStrings("session-id", session_args.id.?);

    const blocks_argv = [_][]const u8{ "blocks", "--active", "--recent", "--token-limit", "max", "--session-length", "2.5" };
    const blocks_args = try parseArgs(&blocks_argv);
    try std.testing.expectEqual(Command.blocks, blocks_args.command);
    try std.testing.expect(blocks_args.active);
    try std.testing.expect(blocks_args.recent);
    try std.testing.expectEqualStrings("max", blocks_args.token_limit.?);
    try std.testing.expectApproxEqAbs(2.5, blocks_args.session_length, 0.0000001);
}

test "model display handling matches data loader behavior" {
    const allocator = std.testing.allocator;
    const normal = try displayModel(allocator, "claude-sonnet-4-20250514", false);
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", normal.?);

    const fast = try displayModel(allocator, "claude-sonnet-4-20250514", true);
    defer allocator.free(fast.?);
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514-fast", fast.?);

    try std.testing.expectEqual(@as(?[]const u8, null), try displayModel(allocator, "<synthetic>", false));
}

test "project name aliases match daily table behavior" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Project A", formatProjectName("project-a", "project-a=Project A", &buf));
    try std.testing.expectEqualStrings("Unknown Project", formatProjectName("unknown", null, &buf));
    try std.testing.expectEqualStrings("ccusage", formatProjectName("/Users/example/ccusage", null, &buf));
    try std.testing.expectEqualStrings("ccusage", formatProjectName("-Users-example-ccusage", null, &buf));
}
