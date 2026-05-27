const std = @import("std");

/// Escape a string for safe inclusion in single-quoted JS strings.
/// Replaces \ → \\ and ' → \'.
fn escapeJsString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var count: usize = 0;
    for (s) |c| {
        if (c == '\\' or c == '\'') count += 1;
    }
    if (count == 0) return try allocator.dupe(u8, s);

    const buf = try allocator.alloc(u8, s.len + count);
    var i: usize = 0;
    for (s) |c| {
        if (c == '\\' or c == '\'') {
            buf[i] = '\\';
            i += 1;
        }
        buf[i] = c;
        i += 1;
    }
    return buf;
}

/// Escape a string for safe inclusion in JS template literals (backtick strings).
/// Replaces \ → \\, ` → \`, and ${ → \${.
pub fn escapeJsTemplateLiteral(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' or s[i] == '`') {
            count += 1;
        } else if (s[i] == '$' and i + 1 < s.len and s[i + 1] == '{') {
            count += 1;
            i += 1;
        }
    }
    if (count == 0) return try allocator.dupe(u8, s);

    const buf = try allocator.alloc(u8, s.len + count);
    var j: usize = 0;
    i = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' or s[i] == '`') {
            buf[j] = '\\';
            j += 1;
            buf[j] = s[i];
            j += 1;
        } else if (s[i] == '$' and i + 1 < s.len and s[i + 1] == '{') {
            buf[j] = '\\';
            j += 1;
            buf[j] = '$';
            j += 1;
            i += 1;
            buf[j] = '{';
            j += 1;
        } else {
            buf[j] = s[i];
            j += 1;
        }
    }
    return buf;
}

/// Generate JS to click an element by CSS selector.
pub fn clickJs(allocator: std.mem.Allocator, selector: []const u8) ![]const u8 {
    const esc = try escapeJsString(allocator, selector);
    defer allocator.free(esc);
    return std.fmt.allocPrint(allocator,
        \\\(() => {{
        \\  const el = document.querySelector('{s}');
        \\  if (!el) throw new Error('Element not found: {s}');
        \\  el.click();
        \\  return true;
        \\}})()
    , .{ esc, esc });
}

/// Generate JS to type text into an element by CSS selector.
pub fn typeTextJs(allocator: std.mem.Allocator, selector: []const u8, text: []const u8) ![]const u8 {
    const sel = try escapeJsString(allocator, selector);
    defer allocator.free(sel);
    const txt = try escapeJsString(allocator, text);
    defer allocator.free(txt);
    return std.fmt.allocPrint(allocator,
        \\\(() => {{
        \\  const el = document.querySelector('{s}');
        \\  if (!el) throw new Error('Element not found: {s}');
        \\  el.focus();
        \\  el.value = '{s}';
        \\  el.dispatchEvent(new Event('input', {{ bubbles: true }}));
        \\  el.dispatchEvent(new Event('change', {{ bubbles: true }}));
        \\  return true;
        \\}})()
    , .{ sel, sel, txt });
}

/// Generate JS to simulate a key press.
pub fn pressKeyJs(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
    const k = try escapeJsString(allocator, key);
    defer allocator.free(k);
    return std.fmt.allocPrint(allocator,
        \\\(() => {{
        \\  const target = document.activeElement || document.body;
        \\  const opts = {{ key: '{s}', code: '{s}', bubbles: true, cancelable: true }};
        \\  target.dispatchEvent(new KeyboardEvent('keydown', opts));
        \\  target.dispatchEvent(new KeyboardEvent('keypress', opts));
        \\  target.dispatchEvent(new KeyboardEvent('keyup', opts));
        \\  return true;
        \\}})()
    , .{ k, k });
}

/// Generate JS to scroll in a given direction by an amount of pixels.
pub fn scrollJs(allocator: std.mem.Allocator, direction: []const u8, amount: i32) ![]const u8 {
    const y = if (std.mem.eql(u8, direction, "up")) -amount else amount;
    return std.fmt.allocPrint(allocator,
        \\\(() => {{
        \\  window.scrollBy({{ top: {d}, behavior: 'smooth' }});
        \\  return {{ scrollY: window.scrollY, scrollHeight: document.body.scrollHeight }};
        \\}})()
    , .{y});
}

/// Generate JS to auto-scroll the page repeatedly.
pub fn autoScrollJs(allocator: std.mem.Allocator, max_scrolls: u32, delay_ms: u64) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\\(async () => {{
        \\  let prev = -1;
        \\  let scrolls = 0;
        \\  const max = {d};
        \\  const delay = {d};
        \\  while (scrolls < max) {{
        \\    window.scrollBy(0, window.innerHeight);
        \\    await new Promise(r => setTimeout(r, delay));
        \\    const cur = window.scrollY;
        \\    if (cur === prev) break;
        \\    prev = cur;
        \\    scrolls++;
        \\  }}
        \\  return {{ scrolls, scrollY: window.scrollY, scrollHeight: document.body.scrollHeight }};
        \\}})()
    , .{ max_scrolls, delay_ms });
}

/// Generate JS that waits for DOM stability (no mutations for a period).
pub fn waitForDomStableJs(allocator: std.mem.Allocator) ![]const u8 {
    return try allocator.dupe(u8,
        \\\(async () => {{
        \\  return new Promise((resolve) => {{
        \\    let timer;
        \\    const observer = new MutationObserver(() => {{
        \\      clearTimeout(timer);
        \\      timer = setTimeout(() => {{ observer.disconnect(); resolve(true); }}, 500);
        \\    }});
        \\    observer.observe(document.body, {{ childList: true, subtree: true, attributes: true }});
        \\    timer = setTimeout(() => {{ observer.disconnect(); resolve(true); }}, 2000);
        \\  }});
        \\}})()
    );
}

/// Generate JS to capture network request information from Performance API.
pub fn networkRequestsJs(allocator: std.mem.Allocator) ![]const u8 {
    return try allocator.dupe(u8,
        \\\(() => {{
        \\  const entries = performance.getEntriesByType('resource');
        \\  return entries.map(e => ({{
        \\    url: e.name,
        \\    method: 'GET',
        \\    status: null,
        \\    headers: {{}},
        \\    body: null,
        \\    response_body: null,
        \\    duration: e.duration,
        \\    type: e.initiatorType,
        \\  }}));
        \\}})()
    );
}

/// Convert a glob-like pattern to a regex pattern.
fn globToRegex(allocator: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    var count: usize = 0;
    for (pattern) |c| {
        switch (c) {
            '*', '?' => count += 1,
            '.', '+', '^', '$', '{', '}', '(', ')', '|', '[', ']' => count += 1,
            else => {},
        }
    }
    const buf = try allocator.alloc(u8, pattern.len + count);
    var i: usize = 0;
    for (pattern) |c| {
        switch (c) {
            '*' => { buf[i] = '.'; buf[i + 1] = '*'; i += 2; },
            '?' => { buf[i] = '.'; i += 1; },
            '.', '+', '^', '$', '{', '}', '(', ')', '|', '[', ']' => {
                buf[i] = '\\';
                buf[i + 1] = c;
                i += 2;
            },
            else => { buf[i] = c; i += 1; },
        }
    }
    return buf[0..i];
}

/// Generate JS to install a network request interceptor for a URL pattern.
pub fn installInterceptorJs(allocator: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    const needs_glob = for (pattern) |c| {
        if (c == '*' or c == '?') break true;
    } else false;

    const regex_pat = if (needs_glob)
        try globToRegex(allocator, pattern)
    else
        try allocator.dupe(u8, pattern);
    defer allocator.free(regex_pat);

    const pat = try escapeJsString(allocator, regex_pat);
    defer allocator.free(pat);

    return std.fmt.allocPrint(allocator,
        \\\(() => {{
        \\  if (!window.__autocli_intercepted) window.__autocli_intercepted = [];
        \\  const regex = new RegExp('{s}');
        \\  const origFetch = window.fetch;
        \\  window.fetch = async function(...args) {{
        \\    const resp = await origFetch.apply(this, args);
        \\    try {{
        \\      const url = typeof args[0] === 'string' ? args[0]
        \\        : (args[0] instanceof Request ? args[0].url : String(args[0]));
        \\      if (regex.test(url)) {{
        \\        try {{
        \\          const json = await resp.clone().json();
        \\          window.__autocli_intercepted.push(json);
        \\        }} catch {{
        \\          window.__autocli_intercepted.push({{
        \\            url, method: (args[0]?.method || 'GET'),
        \\            body: await resp.clone().text().catch(() => null),
        \\          }});
        \\        }}
        \\      }}
        \\    }} catch {{}}
        \\    return resp;
        \\  }};
        \\  const origXhr = XMLHttpRequest.prototype.open;
        \\  XMLHttpRequest.prototype.open = function(method, url, ...rest) {{
        \\    if (regex.test(String(url))) {{
        \\      this.__autocli_url = String(url);
        \\      this.__autocli_method = method;
        \\    }}
        \\    return origXhr.call(this, method, url, ...rest);
        \\  }};
        \\  const origSend = XMLHttpRequest.prototype.send;
        \\  XMLHttpRequest.prototype.send = function(body) {{
        \\    if (this.__autocli_url) {{
        \\      this.addEventListener('load', function() {{
        \\        try {{
        \\          window.__autocli_intercepted.push(JSON.parse(this.responseText));
        \\        }} catch {{
        \\          window.__autocli_intercepted.push({{
        \\            url: this.__autocli_url,
        \\            body: this.responseText,
        \\          }});
        \\        }}
        \\      }});
        \\    }}
        \\    return origSend.call(this, body);
        \\  }};
        \\  return true;
        \\}})()
    , .{pat});
}

/// Generate JS to retrieve intercepted requests.
pub fn getInterceptedRequestsJs(allocator: std.mem.Allocator) ![]const u8 {
    return try allocator.dupe(u8,
        \\\(() => {{
        \\  const reqs = window.__autocli_intercepted || [];
        \\  window.__autocli_intercepted = [];
        \\  return reqs;
        \\}})()
    );
}

/// Generate JS to get a DOM snapshot as simplified accessibility tree.
pub fn snapshotJs(allocator: std.mem.Allocator, selector: ?[]const u8, include_hidden: bool) ![]const u8 {
    const root = if (selector) |s| blk: {
        const esc = try escapeJsString(allocator, s);
        defer allocator.free(esc);
        break :blk try std.fmt.allocPrint(allocator, "document.querySelector('{s}') || document.body", .{esc});
    } else
        try allocator.dupe(u8, "document.body");
    defer allocator.free(root);

    const hidden_check = if (include_hidden) "false" else
        "getComputedStyle(el).display === 'none' || getComputedStyle(el).visibility === 'hidden'";

    return std.fmt.allocPrint(allocator,
        \\\(() => {{
        \\  function walk(el, depth) {{
        \\    if ({s}) return null;
        \\    const tag = el.tagName ? el.tagName.toLowerCase() : '';
        \\    const role = el.getAttribute && el.getAttribute('role') || '';
        \\    const text = el.childNodes.length === 1 && el.childNodes[0].nodeType === 3
        \\      ? el.childNodes[0].textContent.trim().slice(0, 200) : '';
        \\    const children = [];
        \\    for (const child of el.children || []) {{
        \\      const c = walk(child, depth + 1);
        \\      if (c) children.push(c);
        \\    }}
        \\    if (!tag && !text && children.length === 0) return null;
        \\    const node = {{ tag }};
        \\    if (role) node.role = role;
        \\    if (text) node.text = text;
        \\    if (el.id) node.id = el.id;
        \\    if (el.className && typeof el.className === 'string') node.class = el.className.slice(0, 100);
        \\    if (el.href) node.href = el.href;
        \\    if (el.src) node.src = el.src;
        \\    if (children.length > 0) node.children = children;
        \\    return node;
        \\  }}
        \\  const root = {s};
        \\  return walk(root, 0);
        \\}})()
    , .{ hidden_check, root });
}

/// Generate JS to wait for a selector to appear.
pub fn waitForSelectorJs(allocator: std.mem.Allocator, selector: []const u8, timeout_ms: u64, visible: bool) ![]const u8 {
    const sel = try escapeJsString(allocator, selector);
    defer allocator.free(sel);
    const visible_check = if (visible) " && el.offsetParent !== null" else "";
    return std.fmt.allocPrint(allocator,
        \\\(async () => {{
        \\  const deadline = Date.now() + {d};
        \\  while (Date.now() < deadline) {{
        \\    const el = document.querySelector('{s}');
        \\    if (el{s}) return true;
        \\    await new Promise(r => setTimeout(r, 100));
        \\  }}
        \\  throw new Error('Timeout waiting for selector: {s}');
        \\}})()
    , .{ timeout_ms, sel, visible_check, sel });
}

// ─── Tests ───────────────────────────────────────────────────────────

test "clickJs contains selector" {
    const gpa = std.testing.allocator;
    const js = try clickJs(gpa, "#btn");
    defer gpa.free(js);
    try std.testing.expect(std.mem.indexOf(u8, js, "#btn") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "querySelector") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, ".click()") != null);
}

test "typeTextJs contains text" {
    const gpa = std.testing.allocator;
    const js = try typeTextJs(gpa, "input.name", "hello world");
    defer gpa.free(js);
    try std.testing.expect(std.mem.indexOf(u8, js, "input.name") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, ".value =") != null);
}

test "pressKeyJs" {
    const gpa = std.testing.allocator;
    const js = try pressKeyJs(gpa, "Enter");
    defer gpa.free(js);
    try std.testing.expect(std.mem.indexOf(u8, js, "Enter") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "keydown") != null);
}

test "scrollJs up" {
    const gpa = std.testing.allocator;
    const js = try scrollJs(gpa, "up", 500);
    defer gpa.free(js);
    try std.testing.expect(std.mem.indexOf(u8, js, "-500") != null);
}

test "scrollJs down" {
    const gpa = std.testing.allocator;
    const js = try scrollJs(gpa, "down", 300);
    defer gpa.free(js);
    try std.testing.expect(std.mem.indexOf(u8, js, "300") != null);
}

test "autoScrollJs" {
    const gpa = std.testing.allocator;
    const js = try autoScrollJs(gpa, 10, 200);
    defer gpa.free(js);
    try std.testing.expect(std.mem.indexOf(u8, js, "10") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "200") != null);
}

test "networkRequestsJs" {
    const gpa = std.testing.allocator;
    const js = try networkRequestsJs(gpa);
    defer gpa.free(js);
    try std.testing.expect(std.mem.indexOf(u8, js, "getEntriesByType") != null);
}

test "installInterceptorJs" {
    const gpa = std.testing.allocator;
    const js = try installInterceptorJs(gpa, "api\\.example\\.com");
    defer gpa.free(js);
    try std.testing.expect(std.mem.indexOf(u8, js, "__autocli_intercepted") != null);
}

test "getInterceptedRequestsJs" {
    const gpa = std.testing.allocator;
    const js = try getInterceptedRequestsJs(gpa);
    defer gpa.free(js);
    try std.testing.expect(std.mem.indexOf(u8, js, "__autocli_intercepted") != null);
}

test "snapshotJs" {
    const gpa = std.testing.allocator;
    const js = try snapshotJs(gpa, null, false);
    defer gpa.free(js);
    try std.testing.expect(std.mem.indexOf(u8, js, "document.body") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "walk") != null);
}

test "waitForSelectorJs" {
    const gpa = std.testing.allocator;
    const js = try waitForSelectorJs(gpa, ".loading", 5000, true);
    defer gpa.free(js);
    try std.testing.expect(std.mem.indexOf(u8, js, ".loading") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "5000") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "offsetParent") != null);
}

test "escapeJsString handles backslash and quote" {
    const gpa = std.testing.allocator;
    const esc = try escapeJsString(gpa, "a\\b'c");
    defer gpa.free(esc);
    try std.testing.expect(std.mem.eql(u8, esc, "a\\\\b\\'c"));
}

test "globToRegex" {
    const gpa = std.testing.allocator;
    const r = try globToRegex(gpa, "api*.json");
    defer gpa.free(r);
    try std.testing.expect(std.mem.eql(u8, r, "api.*\\.json"));
}
