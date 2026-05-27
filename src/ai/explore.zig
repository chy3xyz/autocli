const std = @import("std");
const json = std.json;
const CliError = @import("core").CliError;
const IPage = @import("core").IPage;
const freeJsonValue = @import("core").freeJsonValue;
const NetworkRequest = @import("core").NetworkRequest;

// ── Constants ──────────────────────────────────────────────────────────────

const VOLATILE_PARAMS = &[_][]const u8{
    "_", "t", "ts", "timestamp", "cb", "callback", "nonce", "rand", "random",
    "spm_id_from", "vd_source", "from_spmid", "seid", "rt", "mid",
    "web_location", "platform", "w_rid", "wts", "sign",
};

const SEARCH_PARAMS = &[_][]const u8{
    "q", "query", "keyword", "keywords", "search", "search_query", "w", "wd", "kw",
};

const PAGINATION_PARAMS = &[_][]const u8{
    "page", "pn", "p", "offset", "cursor", "next", "page_num", "pageNum",
};

const LIMIT_PARAMS = &[_][]const u8{
    "limit", "ps", "size", "pageSize", "page_size", "count", "num", "per_page",
};

const FieldRole = struct { role: []const u8, aliases: []const []const u8 };

const FIELD_ROLES = &[_]FieldRole{
    .{ .role = "title", .aliases = &[_][]const u8{ "title", "name", "text", "content", "desc", "description", "headline", "subject" } },
    .{ .role = "url", .aliases = &[_][]const u8{ "url", "uri", "link", "href", "permalink", "jump_url", "web_url", "share_url" } },
    .{ .role = "author", .aliases = &[_][]const u8{ "author", "username", "user_name", "nickname", "nick", "owner", "creator", "up_name", "uname" } },
    .{ .role = "score", .aliases = &[_][]const u8{ "score", "hot", "heat", "likes", "like_count", "view_count", "views", "play", "favorite_count", "reply_count" } },
    .{ .role = "time", .aliases = &[_][]const u8{ "time", "created_at", "publish_time", "pub_time", "date", "ctime", "mtime", "pubdate", "created" } },
    .{ .role = "id", .aliases = &[_][]const u8{ "id", "aid", "bvid", "mid", "uid", "oid", "note_id", "item_id" } },
    .{ .role = "cover", .aliases = &[_][]const u8{ "cover", "pic", "image", "thumbnail", "poster", "avatar" } },
    .{ .role = "category", .aliases = &[_][]const u8{ "category", "tag", "type", "tname", "channel", "section" } },
};

const KNOWN_SITE_ALIASES = &[_]struct { host: []const u8, name: []const u8 }{
    .{ .host = "x.com", .name = "twitter" },
    .{ .host = "twitter.com", .name = "twitter" },
    .{ .host = "news.ycombinator.com", .name = "hackernews" },
    .{ .host = "www.zhihu.com", .name = "zhihu" },
    .{ .host = "www.bilibili.com", .name = "bilibili" },
    .{ .host = "search.bilibili.com", .name = "bilibili" },
    .{ .host = "www.v2ex.com", .name = "v2ex" },
    .{ .host = "www.reddit.com", .name = "reddit" },
    .{ .host = "www.xiaohongshu.com", .name = "xiaohongshu" },
    .{ .host = "www.douban.com", .name = "douban" },
    .{ .host = "www.weibo.com", .name = "weibo" },
    .{ .host = "www.bbc.com", .name = "bbc" },
};

// ── JavaScript Snippets ────────────────────────────────────────────────────

const FRAMEWORK_DETECT_JS =
    \\(() => {
    \\    const r = {};
    \\    try {
    \\        const app = document.querySelector('#app');
    \\        r.vue3 = !!(app && app.__vue_app__);
    \\        r.vue2 = !!(app && app.__vue__);
    \\        r.react = !!(window.__REACT_DEVTOOLS_GLOBAL_HOOK__) || !!document.querySelector('[data-reactroot]');
    \\        r.nextjs = !!(window.__NEXT_DATA__);
    \\        r.nuxt = !!(window.__NUXT__);
    \\        if (r.vue3 && app.__vue_app__) {
    \\            const gp = app.__vue_app__.config && app.__vue_app__.config.globalProperties;
    \\            r.pinia = !!(gp && gp.$pinia);
    \\            r.vuex = !!(gp && gp.$store);
    \\        }
    \\    } catch(e) {}
    \\    return r;
    \\})()
;

const STORE_DISCOVER_JS =
    \\(() => {
    \\    const stores = [];
    \\    try {
    \\        const app = document.querySelector('#app');
    \\        if (!app || !app.__vue_app__) return stores;
    \\        const gp = app.__vue_app__.config && app.__vue_app__.config.globalProperties;
    \\        const pinia = gp && gp.$pinia;
    \\        if (pinia && pinia._s) {
    \\            pinia._s.forEach((store, id) => {
    \\                const actions = [];
    \\                const stateKeys = [];
    \\                for (const k in store) {
    \\                    try {
    \\                        if (k.startsWith('$') || k.startsWith('_')) continue;
    \\                        if (typeof store[k] === 'function') actions.push(k);
    \\                        else stateKeys.push(k);
    \\                    } catch(e) {}
    \\                }
    \\                stores.push({ type: 'pinia', id, actions: actions.slice(0, 20), stateKeys: stateKeys.slice(0, 15) });
    \\            });
    \\        }
    \\        const vuex = gp && gp.$store;
    \\        if (vuex && vuex._modules && vuex._modules.root && vuex._modules.root._children) {
    \\            const children = vuex._modules.root._children;
    \\            for (const [modName, mod] of Object.entries(children)) {
    \\                const actions = Object.keys((mod._rawModule && mod._rawModule.actions) || {}).slice(0, 20);
    \\                const stateKeys = Object.keys(mod.state || {}).slice(0, 15);
    \\                stores.push({ type: 'vuex', id: modName, actions, stateKeys });
    \\            }
    \\        }
    \\    } catch(e) {}
    \\    return stores;
    \\})()
;

const SMART_API_DISCOVER_JS =
    \\(async () => {
    \\    const entries = performance.getEntriesByType('resource');
    \\    const apiUrls = entries
    \\        .map(e => e.name)
    \\        .filter(url => {
    \\            const lower = url.toLowerCase();
    \\            return (lower.includes('/api/') || lower.includes('/v1/') || lower.includes('/v2/')
    \\                || lower.includes('/v3/') || lower.includes('/x/') || lower.includes('.json')
    \\                || lower.includes('graphql') || lower.includes('search') || lower.includes('feed')
    \\                || lower.includes('hot') || lower.includes('trending') || lower.includes('list'))
    \\                && !lower.includes('.js') && !lower.includes('.css') && !lower.includes('.png')
    \\                && !lower.includes('.jpg') && !lower.includes('.svg') && !lower.includes('.woff');
    \\        });
    \\    const seen = new Set();
    \\    const unique = apiUrls.filter(url => {
    \\        try {
    \\            const u = new URL(url);
    \\            const key = u.pathname;
    \\            if (seen.has(key)) return false;
    \\            seen.add(key);
    \\            return true;
    \\        } catch { return false; }
    \\    });
    \\    const results = [];
    \\    for (const url of unique.slice(0, 20)) {
    \\        try {
    \\            const resp = await fetch(url, { credentials: 'include' });
    \\            if (!resp.ok) continue;
    \\            const ct = resp.headers.get('content-type') || '';
    \\            if (!ct.includes('json') && !ct.includes('javascript')) continue;
    \\            const body = await resp.json();
    \\            results.push({ url, status: resp.status, body });
    \\        } catch {}
    \\    }
    \\    return results;
    \\})()
;

const INTERACT_FUZZ_JS =
    \\(async () => {
    \\    const sleep = (ms) => new Promise(r => setTimeout(r, ms));
    \\    const clickables = Array.from(document.querySelectorAll(
    \\        'button, [role="button"], [role="tab"], .tab, .btn, a[href="javascript:void(0)"], a[href="#"]'
    \\    )).slice(0, 15);
    \\    let clicked = 0;
    \\    for (const el of clickables) {
    \\        try {
    \\            const rect = el.getBoundingClientRect();
    \\            if (rect.width > 0 && rect.height > 0) {
    \\                el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
    \\                clicked++;
    \\                await sleep(300);
    \\            }
    \\        } catch(e) {}
    \\    }
    \\    return clicked;
    \\})()
;

const PROBE_INITIAL_STATE_JS =
    \\(() => {
    \\    const candidates = [
    \\        window.__INITIAL_STATE__,
    \\        window.__NEXT_DATA__?.props?.pageProps,
    \\        window.__NUXT__?.data,
    \\        window.__SSR_DATA__,
    \\        window.__PRELOADED_STATE__,
    \\    ];
    \\    for (const data of candidates) {
    \\        if (data && typeof data === 'object' && Object.keys(data).length > 3) {
    \\            return data;
    \\        }
    \\    }
    \\    return null;
    \\})()
;

// ── Types ──────────────────────────────────────────────────────────────────

pub const ResponseAnalysis = struct {
    item_path: ?[]const u8,
    item_count: usize,
    // role -> field name
    detected_fields: std.StringHashMap([]const u8),
    sample_fields: [][]const u8,

    pub fn deinit(self: *ResponseAnalysis, allocator: std.mem.Allocator) void {
        if (self.item_path) |p| allocator.free(p);
        var it = self.detected_fields.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        self.detected_fields.deinit();
        for (self.sample_fields) |f| allocator.free(f);
        allocator.free(self.sample_fields);
    }
};

pub const DiscoveredEndpoint = struct {
    url: []const u8,
    method: []const u8,
    content_type: ?[]const u8,
    pattern: []const u8,
    query_params: [][]const u8,
    score: i32,
    confidence: f64,
    has_search_param: bool,
    has_pagination_param: bool,
    has_limit_param: bool,
    auth_indicators: [][]const u8,
    response_analysis: ?ResponseAnalysis,
    auth_level: []const u8,

    pub fn deinit(self: *DiscoveredEndpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.method);
        if (self.content_type) |ct| allocator.free(ct);
        allocator.free(self.pattern);
        for (self.query_params) |qp| allocator.free(qp);
        allocator.free(self.query_params);
        for (self.auth_indicators) |ai| allocator.free(ai);
        allocator.free(self.auth_indicators);
        if (self.response_analysis) |*ra| ra.deinit(allocator);
        allocator.free(self.auth_level);
    }
};

pub const InferredCapability = struct {
    name: []const u8,
    description: []const u8,
    strategy: []const u8,
    confidence: f64,
    endpoint: []const u8,
    item_path: ?[]const u8,
    recommended_columns: [][]const u8,
    recommended_args: []RecommendedArg,
    store_hint: ?StoreHint,

    pub fn deinit(self: *InferredCapability, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.strategy);
        allocator.free(self.endpoint);
        if (self.item_path) |p| allocator.free(p);
        for (self.recommended_columns) |c| allocator.free(c);
        allocator.free(self.recommended_columns);
        for (self.recommended_args) |*a| a.deinit(allocator);
        allocator.free(self.recommended_args);
        if (self.store_hint) |*sh| sh.deinit(allocator);
    }
};

pub const RecommendedArg = struct {
    name: []const u8,
    arg_type: []const u8,
    required: bool,

    pub fn deinit(self: *RecommendedArg, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.arg_type);
    }
};

pub const StoreHint = struct {
    store: []const u8,
    action: []const u8,

    pub fn deinit(self: *StoreHint, allocator: std.mem.Allocator) void {
        allocator.free(self.store);
        allocator.free(self.action);
    }
};

pub const StoreInfo = struct {
    store_type: []const u8,
    id: []const u8,
    actions: [][]const u8,
    state_keys: [][]const u8,

    pub fn deinit(self: *StoreInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.store_type);
        allocator.free(self.id);
        for (self.actions) |a| allocator.free(a);
        allocator.free(self.actions);
        for (self.state_keys) |k| allocator.free(k);
        allocator.free(self.state_keys);
    }
};

pub const ExploreManifest = struct {
    url: []const u8,
    title: ?[]const u8,
    endpoints: []DiscoveredEndpoint,
    framework: ?[]const u8,
    store: ?[]const u8,
    auth_indicators: [][]const u8,

    pub fn deinit(self: *ExploreManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        if (self.title) |t| allocator.free(t);
        for (self.endpoints) |*ep| ep.deinit(allocator);
        allocator.free(self.endpoints);
        if (self.framework) |f| allocator.free(f);
        if (self.store) |s| allocator.free(s);
        for (self.auth_indicators) |ai| allocator.free(ai);
        allocator.free(self.auth_indicators);
    }
};

pub const ExploreOptions = struct {
    timeout: u64 = 120,
    max_scrolls: u32 = 5,
    capture_network: bool = true,
    wait_seconds: f64 = 3.0,
    auto_fuzz: bool = false,
    goal: ?[]const u8 = null,
    site_name: ?[]const u8 = null,
};

// ── URL Helpers ────────────────────────────────────────────────────────────

fn urlToPattern(url: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return try allocator.dupe(u8, url);
    const host_start = scheme_end + 3;
    const path_pos = std.mem.indexOfScalar(u8, url[host_start..], '/') orelse url.len - host_start;
    const host = url[host_start..@min(path_pos + host_start, url.len)];
    const clean_host = if (std.mem.startsWith(u8, host, "www.")) host[4..] else host;
    const query_start = std.mem.indexOfScalar(u8, url, '?');
    const path_end = query_start orelse url.len;

    var result = std.ArrayList(u8).empty;
    try result.appendSlice(allocator,clean_host);

    const path = if (path_pos + host_start < path_end) url[path_pos + host_start .. path_end] else "";
    var seg_iter = std.mem.splitScalar(u8, path, '/');
    while (seg_iter.next()) |segment| {
        if (segment.len == 0) continue;
        try result.append(allocator, '/');
        if (isAllDigits(segment)) {
            try result.appendSlice(allocator,"{id}");
        } else if (segment.len >= 8 and isAllHex(segment)) {
            try result.appendSlice(allocator,"{hex}");
        } else if (segment.len == 12 and std.mem.startsWith(u8, segment, "BV") and isAlphanumeric(segment[2..])) {
            try result.appendSlice(allocator,"{bvid}");
        } else {
            try result.appendSlice(allocator,segment);
        }
    }

    if (query_start) |qs| {
        const query = url[qs + 1 ..];
        var params_added: usize = 0;
        var pair_iter = std.mem.splitScalar(u8, query, '&');
        while (pair_iter.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const k = pair[0..eq];
            if (!isVolatileParam(k)) {
                if (params_added == 0) try result.append(allocator, '?');
                if (params_added > 0) try result.append(allocator, '&');
                try result.appendSlice(allocator,k);
                try result.appendSlice(allocator,"={}");
                params_added += 1;
            }
        }
    }

    return result.toOwnedSlice(allocator);
}

fn isAllDigits(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return s.len > 0;
}

fn isAllHex(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return s.len > 0;
}

fn isAlphanumeric(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

fn isVolatileParam(name: []const u8) bool {
    for (VOLATILE_PARAMS) |vp| {
        if (std.mem.eql(u8, vp, name)) return true;
    }
    return false;
}

fn extractQueryParams(allocator: std.mem.Allocator, url: []const u8) ![][]const u8 {
    const qs = std.mem.indexOfScalar(u8, url, '?') orelse return &[_][]const u8{};
    const query = url[qs + 1 ..];
    var list = std.ArrayList([]const u8).empty;
    var pair_iter = std.mem.splitScalar(u8, query, '&');
    while (pair_iter.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const k = pair[0..eq];
        if (!isVolatileParam(k)) {
            try list.append(allocator, try allocator.dupe(u8, k));
        }
    }
    return list.toOwnedSlice(allocator);
}

// ── Auth Detection ─────────────────────────────────────────────────────────

fn detectAuthIndicators(allocator: std.mem.Allocator, headers: std.StringHashMap([]const u8)) ![][]const u8 {
    var list = std.ArrayList([]const u8).empty;
    var it = headers.iterator();
    while (it.next()) |entry| {
        const lower = try std.ascii.allocLowerString(allocator, entry.key_ptr.*);
        defer allocator.free(lower);
        if (std.mem.eql(u8, lower, "authorization")) {
            try list.append(allocator, try allocator.dupe(u8, "bearer"));
        }
        if (std.mem.startsWith(u8, lower, "x-csrf") or std.mem.startsWith(u8, lower, "x-xsrf")) {
            if (!hasStr(list.items, "csrf")) try list.append(allocator, try allocator.dupe(u8, "csrf"));
        }
        if (std.mem.startsWith(u8, lower, "x-s") or std.mem.eql(u8, lower, "x-t") or std.mem.eql(u8, lower, "x-s-common")) {
            if (!hasStr(list.items, "signature")) try list.append(allocator, try allocator.dupe(u8, "signature"));
        }
    }
    return list.toOwnedSlice(allocator);
}

fn hasStr(items: [][]const u8, s: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, s)) return true;
    }
    return false;
}

fn inferStrategy(indicators: [][]const u8) []const u8 {
    for (indicators) |i| {
        if (std.mem.eql(u8, i, "signature")) return "intercept";
        if (std.mem.eql(u8, i, "bearer") or std.mem.eql(u8, i, "csrf")) return "header";
    }
    return "cookie";
}

// ── Endpoint Scoring ───────────────────────────────────────────────────────

fn scoreEndpoint(
    content_type: []const u8,
    pattern: []const u8,
    status: ?u16,
    has_search: bool,
    has_pagination: bool,
    has_limit: bool,
    response_analysis: ?*const ResponseAnalysis,
) i32 {
    var s: i32 = 0;
    if (std.mem.indexOf(u8, content_type, "json") != null) s += 10;
    if (response_analysis) |ra| {
        s += 5;
        s += @min(@as(i32, @intCast(ra.item_count)), 10);
        s += @as(i32, @intCast(ra.detected_fields.count())) * 2;
        if (ra.item_count == 0 and std.mem.indexOf(u8, content_type, "json") != null) s -= 3;
    }
    if (std.mem.indexOf(u8, pattern, "/api/") != null or std.mem.indexOf(u8, pattern, "/x/") != null) s += 3;
    if (has_search) s += 3;
    if (has_pagination) s += 2;
    if (has_limit) s += 2;
    if (status == 200) s += 2;
    return s;
}

// ── Response Body Analysis ─────────────────────────────────────────────────

const ItemArrayCandidate = struct { path: []const u8, items: []json.Value };

fn findItemArrays(allocator: std.mem.Allocator, value: json.Value, path: []const u8, depth: usize) ![]ItemArrayCandidate {
    if (depth > 4) return &[_]ItemArrayCandidate{};
    var candidates = std.ArrayList(ItemArrayCandidate).empty;

    switch (value) {
        .array => |arr| {
            if (arr.items.len >= 2) {
                for (arr.items) |item| {
                    if (item == .object) {
                        try candidates.append(allocator, .{ .path = try allocator.dupe(u8, path), .items = arr.items });
                        break;
                    }
                }
            }
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                const child_path = if (path.len == 0)
                    try allocator.dupe(u8, entry.key_ptr.*)
                else
                    try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, entry.key_ptr.* });
                const sub = try findItemArrays(allocator, entry.value_ptr.*, child_path, depth + 1);
                for (sub) |s| try candidates.append(allocator, s);
                allocator.free(child_path);
            }
        },
        else => {},
    }
    return candidates.toOwnedSlice(allocator);
}

fn flattenFields(allocator: std.mem.Allocator, obj: json.Value, prefix: []const u8, max_depth: usize) ![][]const u8 {
    if (max_depth == 0) return &[_][]const u8{};
    const map = switch (obj) {
        .object => |m| m,
        else => return &[_][]const u8{},
    };
    var names = std.ArrayList([]const u8).empty;
    var it = map.iterator();
    while (it.next()) |entry| {
        const full = if (prefix.len == 0)
            try allocator.dupe(u8, entry.key_ptr.*)
        else
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, entry.key_ptr.* });
        try names.append(allocator, full);
        if (entry.value_ptr.* == .object) {
            const sub = try flattenFields(allocator, entry.value_ptr.*, full, max_depth - 1);
            for (sub) |s| try names.append(allocator, try allocator.dupe(u8, s));
        }
    }
    return names.toOwnedSlice(allocator);
}

fn detectFieldRoles(allocator: std.mem.Allocator, sample_fields: []const []const u8) !std.StringHashMap([]const u8) {
    var detected = std.StringHashMap([]const u8).init(allocator);

    for (FIELD_ROLES) |fr| {
        var found: bool = false;

        // Exact match: field name equals role name
        for (sample_fields) |f| {
            const leaf = leafName(f);
            if (std.mem.eql(u8, leaf, fr.role)) {
                try detected.put(fr.role, try allocator.dupe(u8, f));
                found = true;
                break;
            }
        }
        if (found) continue;

        // Alias match
        for (sample_fields) |f| {
            const leaf = leafName(f);
            for (fr.aliases) |alias| {
                if (std.mem.eql(u8, leaf, alias)) {
                    try detected.put(fr.role, try allocator.dupe(u8, f));
                    found = true;
                    break;
                }
            }
            if (found) break;
        }
    }
    return detected;
}

fn leafName(field: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, field, '.')) |dot| {
        return field[dot + 1 ..];
    }
    return field;
}

fn copyStrSlice(allocator: std.mem.Allocator, src: []const []const u8) ![][]const u8 {
    const result = try allocator.alloc([]const u8, src.len);
    for (src, 0..) |s, i| result[i] = try allocator.dupe(u8, s);
    return result;
}

fn analyzeResponseBody(allocator: std.mem.Allocator, body: []const u8) !struct { ?ResponseAnalysis, ?json.Value } {
    const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch return .{ null, null };
    const value = parsed.value;

    const candidates = try findItemArrays(allocator, value, "", 0);
    defer {
        for (candidates) |c| allocator.free(c.path);
        allocator.free(candidates);
    }

    if (candidates.len == 0) return .{ null, value };

    var best_idx: usize = 0;
    for (candidates, 0..) |c, i| {
        if (c.items.len > candidates[best_idx].items.len) best_idx = i;
    }
    const best = candidates[best_idx];

    const sample: ?json.Value = if (best.items.len > 0) best.items[0] else null;
    const sample_fields = if (sample) |s| try flattenFields(allocator, s, "", 4) else &[_][]const u8{};
    defer {
        for (sample_fields) |f| allocator.free(f);
        allocator.free(sample_fields);
    }

    const detected = try detectFieldRoles(allocator, sample_fields);

    const ra = ResponseAnalysis{
        .item_path = if (best.path.len > 0) try allocator.dupe(u8, best.path) else null,
        .item_count = best.items.len,
        .detected_fields = detected,
        .sample_fields = try copyStrSlice(allocator, sample_fields),
    };

    return .{ ra, value };
}

// ── Endpoint Analysis ──────────────────────────────────────────────────────

fn getContentType(headers: std.StringHashMap([]const u8)) []const u8 {
    var it = headers.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "content-type"))
            return entry.value_ptr.*;
    }
    return "";
}

fn cloneNetworkRequest(allocator: std.mem.Allocator, req: NetworkRequest) !NetworkRequest {
    var headers = std.StringHashMap([]const u8).init(allocator);
    var it = req.headers.iterator();
    while (it.next()) |entry| {
        try headers.put(
            try allocator.dupe(u8, entry.key_ptr.*),
            try allocator.dupe(u8, entry.value_ptr.*),
        );
    }
    return NetworkRequest{
        .url = try allocator.dupe(u8, req.url),
        .method = try allocator.dupe(u8, req.method),
        .headers = headers,
        .body = if (req.body) |b| try allocator.dupe(u8, b) else null,
        .status = req.status,
        .response_body = if (req.response_body) |rb| try allocator.dupe(u8, rb) else null,
    };
}

fn deinitNetworkRequest(allocator: std.mem.Allocator, req: *NetworkRequest) void {
    allocator.free(req.url);
    allocator.free(req.method);
    var it = req.headers.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    req.headers.deinit();
    if (req.body) |b| allocator.free(b);
    if (req.response_body) |rb| allocator.free(rb);
}

fn analyzeEndpoints(allocator: std.mem.Allocator, requests: []const NetworkRequest) !struct { []DiscoveredEndpoint, usize } {
    var seen = std.StringHashMap(DiscoveredEndpoint).init(allocator);
    defer {
        var it = seen.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(allocator);
        seen.deinit();
    }

    for (requests) |req| {
        if (req.url.len == 0) continue;
        const ct = getContentType(req.headers);
        if (std.mem.indexOf(u8, ct, "image/") != null or
            std.mem.indexOf(u8, ct, "font/") != null or
            std.mem.indexOf(u8, ct, "css") != null or
            std.mem.indexOf(u8, ct, "javascript") != null or
            std.mem.indexOf(u8, ct, "wasm") != null) continue;
        if (req.status) |s| {
            if (s >= 400) continue;
        }

        const pattern = try urlToPattern(req.url, allocator);
        const key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ req.method, pattern });
        defer allocator.free(key);

        if (seen.get(key)) |existing| {
            if (existing.response_analysis != null or req.response_body == null) {
                allocator.free(pattern);
                continue;
            }
        }

        const effective_ct = if (ct.len == 0) blk: {
            if (std.mem.indexOf(u8, req.url, "/api/") != null or
                std.mem.indexOf(u8, req.url, "/x/") != null or
                std.mem.endsWith(u8, req.url, ".json"))
                break :blk "application/json"
            else
                break :blk "";
        } else ct;

        const qps = try extractQueryParams(allocator, req.url);
        var has_search = false;
        var has_pagination = false;
        var has_limit = false;
        for (qps) |qp| {
            if (!has_search) has_search = paramInList(qp, SEARCH_PARAMS);
            if (!has_pagination) has_pagination = paramInList(qp, PAGINATION_PARAMS);
            if (!has_limit) has_limit = paramInList(qp, LIMIT_PARAMS);
        }

        const auth_indicators = try detectAuthIndicators(allocator, req.headers);

        var response_analysis: ?ResponseAnalysis = null;
        if (req.response_body) |body| {
            const analysis_result = try analyzeResponseBody(allocator, body);
            response_analysis = analysis_result[0];
            if (analysis_result[1]) |v| {
                freeJsonValue(allocator, v);
            }
        }

        const score = scoreEndpoint(effective_ct, pattern, req.status, has_search, has_pagination, has_limit, if (response_analysis) |*ra| ra else null);
        const confidence: f64 = @min(@as(f64, @floatFromInt(score)) / 20.0, 1.0);
        const auth_level = try allocator.dupe(u8, inferStrategy(auth_indicators));

        const ep = DiscoveredEndpoint{
            .url = try allocator.dupe(u8, req.url),
            .method = try allocator.dupe(u8, req.method),
            .content_type = if (effective_ct.len > 0) try allocator.dupe(u8, effective_ct) else null,
            .pattern = pattern,
            .query_params = qps,
            .score = score,
            .confidence = confidence,
            .has_search_param = has_search,
            .has_pagination_param = has_pagination,
            .has_limit_param = has_limit,
            .auth_indicators = auth_indicators,
            .response_analysis = response_analysis,
            .auth_level = auth_level,
        };

        try seen.put(key, ep);
    }

    var analyzed = std.ArrayList(DiscoveredEndpoint).empty;
    var it = seen.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.score >= 5) {
            try analyzed.append(allocator, entry.value_ptr.*);
        }
    }

    std.mem.sort(DiscoveredEndpoint, analyzed.items, {}, struct {
        fn lessThan(_: void, a: DiscoveredEndpoint, b: DiscoveredEndpoint) bool {
            return a.score > b.score;
        }
    }.lessThan);

    const total_count = seen.count();
    return .{ try analyzed.toOwnedSlice(allocator), total_count };
}

fn paramInList(param: []const u8, list: []const []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, param, item)) return true;
    }
    return false;
}

// ── Browser Probe Functions ────────────────────────────────────────────────

fn probeJsonSuffix(page: IPage, url: []const u8, network: *std.ArrayList(NetworkRequest), allocator: std.mem.Allocator) !void {
    if (std.mem.indexOf(u8, url, "/api/") != null or
        std.mem.indexOf(u8, url, "/x/") != null or
        std.mem.endsWith(u8, url, ".json")) return;

    const json_url = if (std.mem.indexOfScalar(u8, url, '?')) |q| blk: {
        break :blk try std.fmt.allocPrint(allocator, "{s}.json{s}", .{ url[0..q], url[q..] });
    } else try std.fmt.allocPrint(allocator, "{s}.json", .{trimTrailingSlash(url)});
    defer allocator.free(json_url);

    const js = try std.fmt.allocPrint(allocator,
        \\(async () => {{
        \\    try {{
        \\        const r = await fetch("{s}", {{ credentials: 'include' }});
        \\        if (!r.ok) return null;
        \\        const ct = r.headers.get('content-type') || '';
        \\        if (!ct.includes('json')) return null;
        \\        return await r.json();
        \\    }} catch {{ return null; }}
        \\}})()
    , .{json_url});
    defer allocator.free(js);

    const result = page.evaluate(js) catch return;
    if (result != .null) {
        const body = std.json.Stringify.valueAlloc(allocator, result, .{}) catch return;
        var headers = std.StringHashMap([]const u8).init(allocator);
        try headers.put(
            try allocator.dupe(u8, "content-type"),
            try allocator.dupe(u8, "application/json"),
        );
        try network.append(allocator, .{
            .url = try allocator.dupe(u8, json_url),
            .method = try allocator.dupe(u8, "GET"),
            .headers = headers,
            .status = 200,
            .response_body = try allocator.dupe(u8, body),
        });
    }
}

fn probeInitialState(page: IPage, network: *std.ArrayList(NetworkRequest), allocator: std.mem.Allocator) !void {
    const result = page.evaluate(PROBE_INITIAL_STATE_JS) catch return;
    if (result != .null and result == .object) {
        const body = std.json.Stringify.valueAlloc(allocator, result, .{}) catch return;
        if (body.len > 100) {
            var headers = std.StringHashMap([]const u8).init(allocator);
            try headers.put(
                try allocator.dupe(u8, "content-type"),
                try allocator.dupe(u8, "application/json"),
            );
            try network.append(allocator, .{
                .url = try allocator.dupe(u8, "__INITIAL_STATE__"),
                .method = try allocator.dupe(u8, "SSR"),
                .headers = headers,
                .status = 200,
                .response_body = try allocator.dupe(u8, body),
            });
        }
    }
}

fn smartApiDiscovery(page: IPage, network: *std.ArrayList(NetworkRequest), allocator: std.mem.Allocator) !void {
    const result = page.evaluate(SMART_API_DISCOVER_JS) catch return;
    if (result == .array) {
        for (result.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const url_val = obj.get("url") orelse continue;
            if (url_val != .string) continue;
            const api_url = url_val.string;

            var duplicate = false;
            for (network.items) |n| {
                if (std.mem.eql(u8, n.url, api_url) and n.response_body != null) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;

            const status_val = obj.get("status");
            const status: ?u16 = if (status_val) |s| blk: {
                if (s == .integer) break :blk @intCast(s.integer);
                break :blk null;
            } else null;

            const body_val = obj.get("body") orelse continue;
            const body = std.json.Stringify.valueAlloc(allocator, body_val, .{}) catch continue;

            var headers = std.StringHashMap([]const u8).init(allocator);
            try headers.put(
                try allocator.dupe(u8, "content-type"),
                try allocator.dupe(u8, "application/json"),
            );
            try network.append(allocator, .{
                .url = try allocator.dupe(u8, api_url),
                .method = try allocator.dupe(u8, "GET"),
                .headers = headers,
                .status = status,
                .response_body = try allocator.dupe(u8, body),
            });
        }
    }
}

fn reFetchMissingBodies(page: IPage, network: *std.ArrayList(NetworkRequest), allocator: std.mem.Allocator) !void {
    var fetched: usize = 0;
    for (network.items) |*entry| {
        if (fetched >= 15) break;
        const ct = getContentType(entry.headers);
        const inferred_json = std.mem.indexOf(u8, ct, "json") != null or
            std.mem.indexOf(u8, entry.url, "/api/") != null or
            std.mem.indexOf(u8, entry.url, "/x/") != null or
            std.mem.endsWith(u8, entry.url, ".json");

        if (std.mem.eql(u8, entry.method, "GET") and
            (entry.status == null or entry.status.? == 200) and
            inferred_json and
            entry.response_body == null)
        {
            const js = try std.fmt.allocPrint(allocator,
                \\(async () => {{
                \\    try {{
                \\        const r = await fetch("{s}", {{ credentials: 'include' }});
                \\        if (!r.ok) return null;
                \\        return await r.json();
                \\    }} catch(e) {{ return null; }}
                \\}})()
            , .{entry.url});
            defer allocator.free(js);

            const result = page.evaluate(js) catch continue;
            if (result != .null) {
                const body = std.json.Stringify.valueAlloc(allocator, result, .{}) catch continue;
                entry.response_body = try allocator.dupe(u8, body);
                entry.status = 200;
            }
            fetched += 1;
        }
    }
}

// ── Framework & Store Detection ────────────────────────────────────────────

fn detectFramework(page: IPage, allocator: std.mem.Allocator) !std.StringHashMap(bool) {
    var map = std.StringHashMap(bool).init(allocator);
    const result = page.evaluate(FRAMEWORK_DETECT_JS) catch return map;
    if (result == .object) {
        var it = result.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == .bool) {
                try map.put(try allocator.dupe(u8, entry.key_ptr.*), entry.value_ptr.*.bool);
            }
        }
    }
    return map;
}

fn frameworkDisplayName(allocator: std.mem.Allocator, map: std.StringHashMap(bool)) ?[]const u8 {
    const priority = &[_][]const u8{ "nextjs", "nuxt", "vue3", "vue2", "react" };
    for (priority) |name| {
        if (map.get(name)) |v| {
            if (v) {
                const display = if (std.mem.eql(u8, name, "nextjs")) "Next.js"
                    else if (std.mem.eql(u8, name, "nuxt")) "Nuxt"
                    else if (std.mem.eql(u8, name, "vue3")) "Vue3"
                    else if (std.mem.eql(u8, name, "vue2")) "Vue2"
                    else if (std.mem.eql(u8, name, "react")) "React"
                    else name;
                return allocator.dupe(u8, display) catch null;
            }
        }
    }
    return null;
}

fn discoverStores(page: IPage, allocator: std.mem.Allocator) ![]StoreInfo {
    const result = page.evaluate(STORE_DISCOVER_JS) catch return &[_]StoreInfo{};
    if (result == .array) {
        var stores = std.ArrayList(StoreInfo).empty;
        for (result.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const store_type_val = obj.get("type") orelse continue;
            if (store_type_val != .string) continue;
            const id_val = obj.get("id") orelse continue;
            if (id_val != .string) continue;

            var actions = std.ArrayList([]const u8).empty;
            if (obj.get("actions")) |a| {
                if (a == .array) {
                    for (a.array.items) |act| {
                        if (act == .string) try actions.append(allocator, try allocator.dupe(u8, act.string));
                    }
                }
            }
            var state_keys = std.ArrayList([]const u8).empty;
            if (obj.get("stateKeys")) |sk| {
                if (sk == .array) {
                    for (sk.array.items) |key| {
                        if (key == .string) try state_keys.append(allocator, try allocator.dupe(u8, key.string));
                    }
                }
            }
            try stores.append(allocator, .{
                .store_type = try allocator.dupe(u8, store_type_val.string),
                .id = try allocator.dupe(u8, id_val.string),
                .actions = try actions.toOwnedSlice(allocator),
                .state_keys = try state_keys.toOwnedSlice(allocator),
            });
        }
        return stores.toOwnedSlice(allocator);
    }
    return &[_]StoreInfo{};
}

fn readPageMetadata(page: IPage, allocator: std.mem.Allocator) !struct { ?[]const u8, ?[]const u8 } {
    const result = page.evaluate("(() => ({ url: window.location.href, title: document.title || '' }))()") catch return .{ null, null };
    if (result == .object) {
        const obj = result.object;
        const url_val: ?[]const u8 = if (obj.get("url")) |v| blk: {
            if (v == .string) break :blk try allocator.dupe(u8, v.string);
            break :blk null;
        } else null;
        const title_val: ?[]const u8 = if (obj.get("title")) |v| blk: {
            if (v == .string and v.string.len > 0) break :blk try allocator.dupe(u8, v.string);
            break :blk null;
        } else null;
        return .{ url_val, title_val };
    }
    return .{ null, null };
}

// ── Capability Inference ───────────────────────────────────────────────────

pub fn detectSiteName(url: []const u8) []const u8 {
    const scheme_end = if (std.mem.indexOf(u8, url, "://")) |pos| pos + 3 else 0;
    const path_start = if (std.mem.indexOfScalar(u8, url[scheme_end..], '/')) |pos| pos + scheme_end else url.len;
    const host = url[scheme_end..path_start];
    const clean_host = if (std.mem.startsWith(u8, host, "www.")) host[4..] else host;
    const lower = std.ascii.allocLowerString(std.heap.page_allocator, clean_host) catch return "site";
    defer std.heap.page_allocator.free(lower);

    for (KNOWN_SITE_ALIASES) |alias| {
        if (std.mem.eql(u8, lower, alias.host)) return alias.name;
    }

    const parts = splitStr(lower, '.');
    if (parts.len >= 2) {
        const last = parts[parts.len - 1];
        if ((std.mem.eql(u8, last, "uk") or std.mem.eql(u8, last, "jp") or
            std.mem.eql(u8, last, "cn") or std.mem.eql(u8, last, "com")) and parts.len >= 3)
        {
            return slugify(parts[parts.len - 3]);
        }
        return slugify(parts[parts.len - 2]);
    }
    if (parts.len > 0) return slugify(parts[0]);
    return "site";
}

fn splitStr(s: []const u8, delimiter: u8) [][]const u8 {
    var count: usize = 1;
    for (s) |c| {
        if (c == delimiter) count += 1;
    }
    const result = std.heap.page_allocator.alloc([]const u8, count) catch return &[_][]const u8{};
    var idx: usize = 0;
    var start: usize = 0;
    for (s, 0..) |c, i| {
        if (c == delimiter) {
            if (i > start) {
                result[idx] = s[start..i];
                idx += 1;
            }
            start = i + 1;
        }
    }
    if (start < s.len) {
        result[idx] = s[start..];
        idx += 1;
    }
    return result[0..idx];
}

fn slugify(value: []const u8) []const u8 {
    const gpa = std.heap.page_allocator;
    var result = std.ArrayList(u8).empty;
    defer result.deinit(gpa);
    for (value) |c| {
        const ch = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(ch)) {
            result.append(gpa, ch) catch return "site";
        } else {
            if (result.items.len > 0 and result.items[result.items.len - 1] != '-')
                result.append(gpa, '-') catch return "site";
        }
    }
    while (result.items.len > 0 and result.items[result.items.len - 1] == '-') {
        result.items.len -= 1;
    }
    if (result.items.len == 0) return "site";
    return result.toOwnedSlice(gpa) catch "site";
}

fn trimTrailingSlash(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '/') return s[0 .. s.len - 1];
    return s;
}

pub fn inferCapabilityName(url: []const u8, goal: ?[]const u8) []const u8 {
    if (goal) |g| return g;
    const lower = std.ascii.allocLowerString(std.heap.page_allocator, url) catch return "data";
    defer std.heap.page_allocator.free(lower);
    if (std.mem.indexOf(u8, lower, "hot") != null or std.mem.indexOf(u8, lower, "popular") != null or
        std.mem.indexOf(u8, lower, "ranking") != null or std.mem.indexOf(u8, lower, "trending") != null) return "hot";
    if (std.mem.indexOf(u8, lower, "search") != null) return "search";
    if (std.mem.indexOf(u8, lower, "feed") != null or std.mem.indexOf(u8, lower, "timeline") != null or
        std.mem.indexOf(u8, lower, "dynamic") != null) return "feed";
    if (std.mem.indexOf(u8, lower, "comment") != null or std.mem.indexOf(u8, lower, "reply") != null) return "comments";
    if (std.mem.indexOf(u8, lower, "history") != null) return "history";
    if (std.mem.indexOf(u8, lower, "profile") != null or std.mem.indexOf(u8, lower, "userinfo") != null or
        std.mem.indexOf(u8, lower, "/me") != null) return "me";
    if (std.mem.indexOf(u8, lower, "favorite") != null or std.mem.indexOf(u8, lower, "collect") != null or
        std.mem.indexOf(u8, lower, "bookmark") != null) return "favorite";
    return "data";
}

fn findStoreHint(allocator: std.mem.Allocator, cap_name: []const u8, stores: []StoreInfo) ?StoreHint {
    const parts = splitStr(cap_name, '_');
    for (stores) |s| {
        for (s.actions) |action| {
            const lower = std.ascii.allocLowerString(allocator, action) catch continue;
            defer allocator.free(lower);
            const matches = for (parts) |part| {
                if (std.mem.indexOf(u8, lower, part) != null) break true;
            } else std.mem.indexOf(u8, lower, "fetch") != null or std.mem.indexOf(u8, lower, "get") != null;
            if (matches) {
                return StoreHint{
                    .store = allocator.dupe(u8, s.id) catch return null,
                    .action = allocator.dupe(u8, action) catch {
                        allocator.free(s.id);
                        return null;
                    },
                };
            }
        }
    }
    return null;
}

// ── Public API ─────────────────────────────────────────────────────────────

pub fn explore(
    allocator: std.mem.Allocator,
    io: std.Io,
    page: ?IPage,
    url: []const u8,
    options: ExploreOptions,
) CliError!ExploreManifest {
    var manifest = ExploreManifest{
        .url = try allocator.dupe(u8, url),
        .title = null,
        .endpoints = &[_]DiscoveredEndpoint{},
        .framework = null,
        .store = null,
        .auth_indicators = &[_][]const u8{},
    };
    errdefer manifest.deinit(allocator);

    const p = page orelse return manifest;

    // Step 1: Navigate
    p.goto(url, null) catch |err| {
        std.log.err("Failed to navigate to {s}: {s}", .{ url, @errorName(err) });
        return manifest;
    };
    const wait_ms: i64 = @intFromFloat(options.wait_seconds * 1000.0);
    std.Io.sleep(io, .fromMilliseconds(wait_ms), .real) catch {};

    // Step 2: Auto-scroll
    const max_scrolls = @min(options.max_scrolls, 3);
    for (0..max_scrolls) |_| {
        _ = p.evaluate("window.scrollBy(0, window.innerHeight * 0.7)") catch {};
        std.Io.sleep(io, .fromMilliseconds(1500), .real) catch {};
    }

    // Step 2.5: Interactive fuzzing
    if (options.auto_fuzz) {
        _ = p.evaluate(INTERACT_FUZZ_JS) catch {};
        std.Io.sleep(io, .fromMilliseconds(2000), .real) catch {};
    }

    // Step 3: Read page metadata
    const metadata = try readPageMetadata(p, allocator);
    manifest.title = metadata[1];

    // Step 4: Capture network traffic
    var network = std.ArrayList(NetworkRequest).empty;
    defer {
        for (network.items) |*n| deinitNetworkRequest(allocator, n);
        network.deinit(allocator);
    }
    if (options.capture_network) {
        const requests = p.getNetworkRequests() catch &[_]NetworkRequest{};
        for (requests) |req| {
            try network.append(allocator, try cloneNetworkRequest(allocator, req));
        }
    }

    // Step 4.5: Probe .json suffix
    try probeJsonSuffix(p, url, &network, allocator);

    // Step 4.6: Probe __INITIAL_STATE__
    try probeInitialState(p, &network, allocator);

    // Step 4.8: Smart API discovery
    try smartApiDiscovery(p, &network, allocator);

    // Step 5: Re-fetch missing bodies
    try reFetchMissingBodies(p, &network, allocator);

    // Step 6: Detect framework
    var framework_map = try detectFramework(p, allocator);
    defer {
        var fw_it = framework_map.iterator();
        while (fw_it.next()) |entry| allocator.free(entry.key_ptr.*);
        framework_map.deinit();
    }
    manifest.framework = frameworkDisplayName(allocator, framework_map);

    // Step 6.5: Discover stores
    const has_pinia = framework_map.get("pinia") orelse false;
    const has_vuex = framework_map.get("vuex") orelse false;
    const stores = if (has_pinia or has_vuex) try discoverStores(p, allocator) else &[_]StoreInfo{};
    defer {
        for (stores) |s| { var ms = s; ms.deinit(allocator); }
        allocator.free(stores);
    }
    if (stores.len > 0) {
        manifest.store = try allocator.dupe(u8, stores[0].store_type);
    }

    // Step 7+8: Analyze endpoints
    const analyzed_result = try analyzeEndpoints(allocator, network.items);
    manifest.endpoints = analyzed_result[0];

    // Aggregate auth indicators
    var auth_set = std.StringHashMap(void).init(allocator);
    defer auth_set.deinit();
    for (manifest.endpoints) |ep| {
        for (ep.auth_indicators) |ai| {
            if (!auth_set.contains(ai)) {
                auth_set.put(try allocator.dupe(u8, ai), {}) catch {};
            }
        }
    }
    var auth_list = std.ArrayList([]const u8).empty;
    defer auth_list.deinit(allocator);
    var auth_it = auth_set.iterator();
    while (auth_it.next()) |entry| auth_list.append(allocator, entry.key_ptr.*) catch {};
    manifest.auth_indicators = try auth_list.toOwnedSlice(allocator);

    return manifest;
}

/// Synthesize adapter candidates from an explore manifest
pub fn synthesize(
    allocator: std.mem.Allocator,
    manifest: ExploreManifest,
    goal: ?[]const u8,
) ![]InferredCapability {
    const site_name = detectSiteName(manifest.url);

    // No endpoints? Create generic candidate
    if (manifest.endpoints.len == 0) {
        var caps = try allocator.alloc(InferredCapability, 1);
        const cap_name = if (goal) |g| try allocator.dupe(u8, g) else try allocator.dupe(u8, "list");
        caps[0] = .{
            .name = cap_name,
            .description = try std.fmt.allocPrint(allocator, "{s} (auto-generated)", .{site_name}),
            .strategy = try allocator.dupe(u8, "public"),
            .confidence = 0.5,
            .endpoint = try allocator.dupe(u8, manifest.url),
            .item_path = null,
            .recommended_columns = try allocator.dupe([]const u8, &[_][]const u8{ "title", "url" }),
            .recommended_args = try allocator.dupe(RecommendedArg, &[_]RecommendedArg{
                .{ .name = try allocator.dupe(u8, "limit"), .arg_type = try allocator.dupe(u8, "int"), .required = false },
            }),
            .store_hint = null,
        };
        return caps;
    }

    var capabilities = std.ArrayList(InferredCapability).empty;
    var used_names = std.StringHashMap(void).init(allocator);
    defer used_names.deinit();

    const max_eps = @min(manifest.endpoints.len, 8);
    for (manifest.endpoints[0..max_eps]) |ep| {
        var cap_name = try allocator.dupe(u8, inferCapabilityName(ep.url, goal));

        if (used_names.contains(cap_name)) {
            allocator.free(cap_name);
            const suffix = blk: {
                var seg_iter = std.mem.splitScalar(u8, ep.pattern, '/');
                var last: ?[]const u8 = null;
                while (seg_iter.next()) |seg| {
                    if (seg.len > 0 and !std.mem.startsWith(u8, seg, "{") and std.mem.indexOfScalar(u8, seg, '.') == null)
                        last = seg;
                }
                break :blk last orelse "1";
            };
            cap_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ inferCapabilityName(ep.url, goal), suffix });
        }
        try used_names.put(cap_name, {});

        var cols = std.ArrayList([]const u8).empty;
        if (ep.response_analysis) |ra| {
            const col_roles = &[_][]const u8{ "title", "url", "author", "score", "time" };
            for (col_roles) |role| {
                if (ra.detected_fields.get(role)) |field| {
                    try cols.append(allocator, try allocator.dupe(u8, field));
                }
            }
        }

        var args = std.ArrayList(RecommendedArg).empty;
        if (ep.has_search_param) {
            try args.append(allocator, .{ .name = try allocator.dupe(u8, "keyword"), .arg_type = try allocator.dupe(u8, "str"), .required = true });
        }
        try args.append(allocator, .{ .name = try allocator.dupe(u8, "limit"), .arg_type = try allocator.dupe(u8, "int"), .required = false });
        if (ep.has_pagination_param) {
            try args.append(allocator, .{ .name = try allocator.dupe(u8, "page"), .arg_type = try allocator.dupe(u8, "int"), .required = false });
        }

        const ep_strategy_str = inferStrategy(ep.auth_indicators);
        const store_hint = if (std.mem.eql(u8, ep_strategy_str, "intercept") and manifest.store != null)
            findStoreHint(allocator, cap_name, &[_]StoreInfo{})
        else
            null;

        const strategy_str = if (store_hint != null) "store-action" else ep_strategy_str;

        try capabilities.append(allocator, .{
            .name = cap_name,
            .description = try std.fmt.allocPrint(allocator, "{s} {s}", .{ site_name, cap_name }),
            .strategy = try allocator.dupe(u8, strategy_str),
            .confidence = ep.confidence,
            .endpoint = try allocator.dupe(u8, ep.pattern),
            .item_path = if (ep.response_analysis) |ra|
                if (ra.item_path) |p| try allocator.dupe(u8, p) else null
            else
                null,
            .recommended_columns = if (cols.items.len > 0) try cols.toOwnedSlice(allocator) else try allocator.dupe([]const u8, &[_][]const u8{ "title", "url" }),
            .recommended_args = try args.toOwnedSlice(allocator),
            .store_hint = store_hint,
        });
    }

    return capabilities.toOwnedSlice(allocator);
}
