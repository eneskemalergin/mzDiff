//! Renders the view as one self-contained HTML page: a header with both files and the verdict, a
//! filter bar (severity, search, layout, expand and collapse), and one collapsible section per
//! differing record, its differences side by side or unified, with tooltips that explain every
//! key, kind, and severity.
//!
//! The page needs nothing from the network: its CSS and script are inline, and the script only
//! hides, shows, and moves focus; it never builds markup. Every value from the files is escaped,
//! in text and in attributes, so a hostile mzML cannot put markup or script into the page. Like
//! the text view, the page is built in a bounded buffer while the comparison runs; past `records`
//! records or `bytes` bytes it becomes a page that says how large the view would be and how to
//! narrow it.

const std = @import("std");

const compare = @import("compare.zig");
const output = @import("output.zig");
const rules_mod = @import("rules.zig");

const Difference = compare.Difference;
const Kind = compare.Kind;
const Severity = rules_mod.Severity;

pub const Page = struct {
    out: *std.Io.Writer,
    selection: output.Selection,
    tally: output.Tally,
    bytes: usize = 16 << 20,
    allocator: std.mem.Allocator,
    // Finished records, and the record being built (its markup waits for its severity counts).
    body: std.Io.Writer.Allocating,
    record: std.Io.Writer.Allocating,
    record_id: std.ArrayList(u8) = .empty,
    last_path: std.ArrayList(u8) = .empty,
    // The current record's shown differences per severity: critical, major, minor.
    counts: [3]usize = .{ 0, 0, 0 },
    // Every shown difference per severity, for the filter bar.
    rows: [3]usize = .{ 0, 0, 0 },

    pub fn init(allocator: std.mem.Allocator, out: *std.Io.Writer, selection: output.Selection) Page {
        return .{
            .out = out,
            .selection = selection,
            .tally = .{ .allocator = allocator, .records = 500 },
            .allocator = allocator,
            .body = .init(allocator),
            .record = .init(allocator),
        };
    }

    pub fn deinit(self: *Page) void {
        self.tally.deinit();
        self.body.deinit();
        self.record.deinit();
        self.record_id.deinit(self.allocator);
        self.last_path.deinit(self.allocator);
    }

    pub fn sink(self: *Page) compare.Sink {
        return .{ .context = self, .emit = emit };
    }

    fn emit(context: *anyopaque, difference: Difference) anyerror!void {
        const self: *Page = @ptrCast(@alignCast(context));
        if (!self.selection.shows(difference.severity, difference.key, difference.record)) return;
        if (try self.tally.note(difference)) {
            try self.flush();
            if (self.tally.too_large) return self.drop();
            try self.record_id.appendSlice(self.allocator, difference.record);
            self.counts = .{ 0, 0, 0 };
            self.last_path.clearRetainingCapacity();
        }
        if (self.tally.too_large) return;
        const w = &self.record.writer;
        // Arrays sit under their own heading, apart from the record's parameters.
        const arrays = std.mem.startsWith(u8, difference.key, "array:");
        const path_matches = std.mem.startsWith(u8, self.last_path.items, difference.path) and
            std.mem.eql(u8, self.last_path.items[difference.path.len..], if (arrays) "/binaryDataArray" else "");
        if (!path_matches) {
            self.last_path.clearRetainingCapacity();
            try self.last_path.appendSlice(self.allocator, difference.path);
            if (arrays) try self.last_path.appendSlice(self.allocator, "/binaryDataArray");
            try w.writeAll("<tr class=\"p\"><td colspan=\"3\">");
            var path: std.Io.Writer.Allocating = .init(self.allocator);
            defer path.deinit();
            try output.writeShortPath(&path.writer, self.last_path.items);
            try writeEscaped(w, path.written());
            try w.writeAll("</td></tr>\n");
        }
        try row(w, difference);
        if (difference.severity != .ignored) {
            self.counts[@intFromEnum(difference.severity)] += 1;
            self.rows[@intFromEnum(difference.severity)] += 1;
        }
        if (self.body.written().len + self.record.written().len > self.bytes) self.drop();
    }

    // Too much to show: keep counting, stop rendering.
    fn drop(self: *Page) void {
        self.tally.too_large = true;
        self.body.clearRetainingCapacity();
        self.record.clearRetainingCapacity();
        self.record_id.clearRetainingCapacity();
    }

    // Moves the finished record into the body, under a summary line with its counts.
    fn flush(self: *Page) !void {
        if (self.record_id.items.len == 0) return;
        defer {
            self.record.clearRetainingCapacity();
            self.record_id.clearRetainingCapacity();
        }
        if (self.tally.too_large) return;
        const w = &self.body.writer;
        const worst: Severity = if (self.counts[0] != 0) .critical else if (self.counts[1] != 0) .major else .minor;
        try w.print("<details class=\"rec\" open data-s=\"{s}\"><summary><span class=\"id\">", .{@tagName(worst)});
        try writeEscaped(w, self.record_id.items);
        try w.writeAll("</span>");
        inline for (.{ .{ 0, "critical" }, .{ 1, "major" }, .{ 2, "minor" } }) |entry| {
            if (self.counts[entry[0]] != 0) try w.print("<span class=\"n {s}\">{d}</span>", .{ entry[1], self.counts[entry[0]] });
        }
        try w.writeAll("</summary><table>\n");
        try w.writeAll(self.record.written());
        try w.writeAll("</table></details>\n");
    }

    /// Writes the page: the view, or, when it grew too large, why and how to narrow it.
    pub fn finish(self: *Page, outcome: output.Outcome) !void {
        try self.flush();
        self.tally.close();
        const out = self.out;
        try out.writeAll("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n" ++
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>mzdiff: ");
        try writeEscaped(out, std.fs.path.basename(outcome.a.path));
        try out.writeAll(" against ");
        try writeEscaped(out, std.fs.path.basename(outcome.b.path));
        try out.writeAll("</title>\n<style>" ++ CSS ++ "</style></head><body>\n");
        try writeHeader(out, outcome, self.rows);
        if (self.tally.too_large) {
            var refusal: std.Io.Writer.Allocating = .init(self.allocator);
            defer refusal.deinit();
            try self.tally.writeRefusal(&refusal.writer);
            try out.writeAll("<main><pre class=\"refuse\">");
            try writeEscaped(out, std.mem.trimEnd(u8, refusal.written(), "\n"));
            try out.writeAll("</pre></main>\n");
        } else if (self.tally.total() == 0) {
            try out.writeAll("<main><p class=\"same\">Nothing selected differs.</p></main>\n");
        } else {
            try out.writeAll("<main>\n");
            try out.writeAll(self.body.written());
            try out.writeAll("</main>\n");
        }
        try out.writeAll(FOOTER ++ "<script>");
        try writeMeanings(out);
        try out.writeAll(SCRIPT ++ "</script>\n</body></html>\n");
    }
};

fn writeHeader(out: *std.Io.Writer, outcome: output.Outcome, rows: [3]usize) !void {
    try out.writeAll("<header><div class=\"files\">");
    inline for (.{ .{ "a", "A", outcome.a, "the reference" }, .{ "b", "B", outcome.b, "the output under test" } }) |entry| {
        try out.print("<div class=\"file {s}\" title=\"{s}: {s}\"><b>{s}</b> ", .{ entry[0], entry[1], entry[3], entry[1] });
        try writeEscaped(out, entry[2].path);
        if (entry[2].software.len != 0) {
            try out.writeAll(" <i>");
            try writeEscaped(out, entry[2].software);
            try out.writeAll("</i>");
        }
        try out.print(" <span class=\"dim\">{d} spectra, {d} chromatograms</span></div>", .{ entry[2].spectra, entry[2].chromatograms });
    }
    try out.print("</div>\n<div class=\"verdict\"><span class=\"st {s}\" title=\"{s}\">{s}</span>", .{
        @tagName(outcome.status), statusMeaning(outcome.status), @tagName(outcome.status),
    });
    try out.print(" <span class=\"dim\">{s}; difference classes: critical {d}, major {d}, minor {d};" ++
        " paired {d} spectra and {d} chromatograms; exit 1 at {s} or above</span></div>\n", .{
        @tagName(outcome.completion), outcome.totals[0],            outcome.totals[1],         outcome.totals[2],
        outcome.paired_spectra,       outcome.paired_chromatograms, @tagName(outcome.fail_on),
    });
    try out.writeAll("<div class=\"bar\"><input id=\"q\" type=\"search\" placeholder=\"Search keys, names, values, records  ( / )\"" ++
        " title=\"Shows the rows whose key, name, or values contain this text, and every row of a record whose id contains it\">");
    inline for (.{ Severity.critical, Severity.major, Severity.minor }) |severity| {
        const name = @tagName(severity);
        try out.print("<label class=\"f {s}\" title=\"{s}: {s}\">", .{ name, name, severityMeaning(severity) });
        try out.print("<input type=\"checkbox\" data-f=\"{s}\" checked> {s} <span>{d}</span></label>", .{
            name,
            name,
            rows[@intFromEnum(severity)],
        });
    }
    try out.writeAll("<button id=\"lay\" title=\"Switch between A and B side by side and A above B (u)\">Unified</button>" ++
        "<button id=\"ex\" title=\"Open every record (e)\">Expand all</button>" ++
        "<button id=\"co\" title=\"Close every record (c)\">Collapse all</button>" ++
        "<span id=\"cnt\" class=\"dim\"></span></div>" ++
        "<div class=\"legend dim\"><span class=\"a\">A</span> left or <code>-</code>," ++
        " <span class=\"b\">B</span> right or <code>+</code>," ++
        " <span class=\"tol\">within a tolerance</span> <code>~</code>; the filters count differences, the badges on a record" ++
        " count its own</div></header>\n");
}

fn row(w: *std.Io.Writer, difference: Difference) !void {
    var label_buffer: [160]u8 = undefined;
    const label = output.describe(&label_buffer, difference);
    const tolerated = output.isTolerance(difference.kind);
    // Tooltips for the severity and the kind come from the script's table on first hover, so the
    // page does not repeat them on every row.
    try w.print("<tr data-s=\"{s}\" data-k=\"{s}\"><td title=\"", .{ @tagName(difference.severity), @tagName(difference.kind) });
    try writeEscaped(w, difference.key);
    try w.writeAll("\">");
    try writeEscaped(w, label);
    try w.print("</td><td class=\"v{s}\">", .{if (tolerated) " tol" else ""});
    try value(w, "a", difference.a, difference.kind == .missing or difference.kind == .record_missing);
    try value(w, "b", difference.b, difference.kind == .extra or difference.kind == .record_extra);
    if (difference.array) |array| {
        try w.writeAll("<div class=\"note\">");
        var note: [256]u8 = undefined;
        var fixed = std.Io.Writer.fixed(&note);
        fixed.print("{d} of {d} values differ", .{ array.differing, array.values }) catch {};
        if (array.largest != array.shown) output.writeLargest(&fixed, array) catch {};
        try writeEscaped(w, fixed.buffered());
        try w.writeAll("</div>");
    }
    try w.print("</td><td><b>{s}</b> {s}</td></tr>\n", .{ difference.severity.label(), difference.kind.label() });
}

// One side of a difference. A term with no value that only this side has reads "(present)".
fn value(w: *std.Io.Writer, side: []const u8, text: []const u8, present: bool) !void {
    try w.print("<div class=\"{s}", .{side});
    if (text.len == 0) {
        try w.print(" none\">{s}</div>", .{if (present) "(present)" else "-"});
        return;
    }
    // Long values are cut by the stylesheet; the tooltip keeps all of it.
    if (text.len > 40) {
        try w.writeAll("\" title=\"");
        try writeEscaped(w, text);
    }
    try w.writeAll("\">");
    try writeEscaped(w, text);
    try w.writeAll("</div>");
}

/// Writes `text` safe for HTML text and quoted attributes alike.
pub fn writeEscaped(w: *std.Io.Writer, text: []const u8) !void {
    var start: usize = 0;
    for (text, 0..) |c, i| {
        const entity: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => continue,
        };
        try w.writeAll(text[start..i]);
        try w.writeAll(entity);
        start = i + 1;
    }
    try w.writeAll(text[start..]);
}

// The tooltip tables the script reads: severity and kind meanings, keyed by their tags.
fn writeMeanings(out: *std.Io.Writer) !void {
    try out.writeAll("var MEANING={");
    inline for (.{ Severity.critical, Severity.major, Severity.minor }) |severity| {
        try out.print("\"{s}\":\"{s}: {s}\",", .{ @tagName(severity), @tagName(severity), severityMeaning(severity) });
    }
    inline for (std.meta.fields(Kind)) |field| {
        const kind: Kind = @enumFromInt(field.value);
        try out.print("\"{s}\":\"{s}\",", .{ field.name, kindMeaning(kind) });
    }
    try out.writeAll("};\n");
}

fn statusMeaning(status: output.Status) []const u8 {
    return switch (status) {
        .same => "no difference at all",
        .tolerated => "differences, none at or above the --fail-on level",
        .differs => "a difference at or above the --fail-on level",
    };
}

fn severityMeaning(severity: Severity) []const u8 {
    return switch (severity) {
        .critical => "the data itself or what it means",
        .major => "a value search engines and readers commonly use",
        .minor, .ignored => "everything else, or a difference within a tolerance",
    };
}

fn kindMeaning(kind: Kind) []const u8 {
    return switch (kind) {
        .missing => "in A, not in B",
        .extra => "in B, not in A",
        .value => "the values differ beyond every tolerance",
        .rounding => "the same value printed with different rounding",
        .narrow => "equal at 32-bit precision: one side stored or printed a 32-bit float",
        .ppm => "m/z values within the --ppm tolerance",
        .count => "a different number of these",
        .unit => "the units differ, or only one side has one",
        .record_missing => "this record is in A only",
        .record_extra => "this record is in B only",
        .peak_count => "the arrays have different lengths",
        .peak_values => "the array values differ beyond every tolerance",
        .peak_order => "the same peaks in another order",
        .precision => "stored as 32-bit floats on one side and 64-bit on the other",
        .array_missing => "this array is in A only",
        .array_extra => "this array is in B only",
        .id_mismatch => "spectra paired by scan number carry different native ids",
        .regrouped => "values moved between repeated elements such as two precursors",
        .order => "this spectrum sits in another place in B than in A",
    };
}

const FOOTER =
    \\<footer class="dim">Keys: <kbd>j</kbd>/<kbd>k</kbd> next and previous record, <kbd>/</kbd> search,
    \\<kbd>e</kbd>/<kbd>c</kbd> expand and collapse all, <kbd>u</kbd> unified or side by side.
    \\Made by mzdiff; hover a cell for what it means.</footer>
    \\
;

const CSS =
    \\:root{--bg:#fff;--fg:#1f2328;--dim:#656d76;--line:#d0d7de;--head:#f6f8fa;--a:#cf222e;--abg:#ffebe9;
    \\--b:#1a7f37;--bbg:#dafbe1;--tol:#9a6700;--tolbg:#fff8c5;--crit:#cf222e;--maj:#bc4c00;--min:#656d76}
    \\@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--dim:#8d96a0;--line:#30363d;
    \\--head:#161b22;--a:#ff7b72;--abg:#3a1d1d;--b:#7ee787;--bbg:#12351d;--tol:#e3b341;--tolbg:#2e2614;
    \\--crit:#ff7b72;--maj:#ffa657;--min:#8d96a0}}
    \\*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);
    \\font:13px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
    \\header{position:sticky;top:0;z-index:2;background:var(--head);border-bottom:1px solid var(--line);padding:8px 16px}
    \\.files{display:grid;gap:2px}.file b{display:inline-block;width:1.4em}.file.a b{color:var(--a)}.file.b b{color:var(--b)}
    \\.verdict{margin:6px 0}.st{font-weight:700;padding:1px 8px;border-radius:10px;border:1px solid}
    \\.st.same{color:var(--b)}.st.tolerated{color:var(--tol)}.st.differs{color:var(--crit)}
    \\.bar{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
    \\#q{flex:1 1 280px;min-width:200px;padding:4px 8px;font:inherit;color:var(--fg);background:var(--bg);
    \\border:1px solid var(--line);border-radius:6px}
    \\button{font:inherit;color:var(--fg);background:var(--bg);border:1px solid var(--line);border-radius:6px;
    \\padding:3px 10px;cursor:pointer}button:hover{border-color:var(--dim)}
    \\.f{cursor:pointer;user-select:none}.f span{color:var(--dim)}.f.critical{color:var(--crit)}.f.major{color:var(--maj)}
    \\.legend{margin-top:4px}.legend .a{color:var(--a)}.legend .b{color:var(--b)}.legend .tol{color:var(--tol)}
    \\.dim{color:var(--dim)}code,kbd{background:var(--bg);border:1px solid var(--line);border-radius:4px;padding:0 4px}
    \\main{padding:8px 16px}.rec{border:1px solid var(--line);border-radius:6px;margin:8px 0;overflow:hidden}
    \\.rec.cur{outline:2px solid var(--maj)}summary{cursor:pointer;padding:5px 10px;background:var(--head);
    \\display:flex;gap:8px;align-items:center}.rec[open] summary{border-bottom:1px solid var(--line)}
    \\.id{font-weight:600;flex:1;overflow-wrap:anywhere}.n{border-radius:8px;padding:0 7px;font-size:12px;border:1px solid}
    \\.n.critical{color:var(--crit)}.n.major{color:var(--maj)}.n.minor{color:var(--min)}
    \\table{width:100%;border-collapse:collapse;table-layout:fixed}td{padding:2px 10px;vertical-align:top}
    \\tr.p td{color:var(--dim);padding-top:6px;font-size:12px}tr[data-s] td:first-child{width:28%;overflow-wrap:anywhere}
    \\tr[data-s] td:last-child{width:22%;text-align:right}
    \\td.v{display:grid;grid-template-columns:1fr 1fr;gap:2px 8px}
    \\.a,.b{padding:0 6px;border-radius:4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    \\.a{background:var(--abg);color:var(--a)}.b{background:var(--bbg);color:var(--b)}
    \\.tol .a,.tol .b{background:var(--tolbg);color:var(--tol)}.none{opacity:.7;font-style:italic}
    \\.note{grid-column:1/-1;color:var(--dim);font-size:12px}
    \\body.unified td.v{grid-template-columns:1fr}body.unified td .a:before{content:"- "}body.unified td .b:before{content:"+ "}
    \\body.unified td.tol .a:before,body.unified td.tol .b:before{content:"~ "}
    \\tr[data-s=critical] b{color:var(--crit)}tr[data-s=major] b{color:var(--maj)}tr[data-s=minor] b{color:var(--min)}
    \\tr[data-s]:hover td{background:var(--head)}[hidden]{display:none!important}
    \\.refuse{white-space:pre-wrap;border:1px solid var(--maj);border-radius:6px;padding:10px}.same{color:var(--b)}
    \\footer{padding:8px 16px 16px}
;

const SCRIPT =
    \\(function(){"use strict";
    \\var d=document,q=d.getElementById("q"),cnt=d.getElementById("cnt"),lay=d.getElementById("lay");
    \\if(!q)return;
    \\var recs=Array.prototype.slice.call(d.querySelectorAll("details.rec"));
    \\var boxes=Array.prototype.slice.call(d.querySelectorAll("input[data-f]"));
    \\var rows=null,ids=null,cur=-1,timer=0;
    \\function index(){ids=recs.map(function(r){return r.querySelector(".id").textContent.toLowerCase();});
    \\rows=recs.map(function(r){var head=null;return Array.prototype.slice.call(r.querySelectorAll("tr"))
    \\.map(function(t){if(t.className==="p"){head=t;return [t,null,null];}return [t,t.textContent.toLowerCase(),head];});});}
    \\function apply(){if(!rows)index();var s=q.value.trim().toLowerCase(),on={},n=0;
    \\boxes.forEach(function(b){on[b.getAttribute("data-f")]=b.checked;});
    \\recs.forEach(function(r,i){var all=s!==""&&ids[i].indexOf(s)>=0,any=false;
    \\rows[i].forEach(function(p){if(p[1]===null){p[0].hidden=true;return;}
    \\var ok=on[p[0].getAttribute("data-s")]&&(s===""||all||p[1].indexOf(s)>=0);
    \\p[0].hidden=!ok;if(ok){any=true;if(p[2])p[2].hidden=false;}});r.hidden=!any;if(any)n++;});
    \\cnt.textContent=n+" of "+recs.length+" records shown";}
    \\q.addEventListener("input",function(){clearTimeout(timer);timer=setTimeout(apply,120);});
    \\boxes.forEach(function(b){b.addEventListener("change",apply);});
    \\lay.addEventListener("click",function(){var u=d.body.classList.toggle("unified");
    \\lay.textContent=u?"Side by side":"Unified";});
    \\function open(o){recs.forEach(function(r){r.open=o;});}
    \\d.getElementById("ex").addEventListener("click",function(){open(true);});
    \\d.getElementById("co").addEventListener("click",function(){open(false);});
    \\function go(step){var v=recs.filter(function(r){return !r.hidden;});if(!v.length)return;
    \\var i=v.indexOf(recs[cur]);i=i<0?(step>0?0:v.length-1):Math.max(0,Math.min(v.length-1,i+step));
    \\if(cur>=0)recs[cur].classList.remove("cur");cur=recs.indexOf(v[i]);v[i].classList.add("cur");
    \\v[i].open=true;v[i].scrollIntoView({block:"center"});}
    \\d.addEventListener("keydown",function(e){if(e.target===q){if(e.key==="Escape")q.blur();return;}
    \\if(e.ctrlKey||e.metaKey||e.altKey)return;var k=e.key;
    \\if(k==="j")go(1);else if(k==="k")go(-1);else if(k==="/"){e.preventDefault();q.focus();}
    \\else if(k==="e")open(true);else if(k==="c")open(false);else if(k==="u")lay.click();});
    \\d.addEventListener("mouseover",function(e){var t=e.target.closest&&e.target.closest("tr[data-s] td:last-child");
    \\if(!t||t.title)return;var r=t.parentNode;t.title=MEANING[r.getAttribute("data-s")]+"\n"+
    \\MEANING[r.getAttribute("data-k")];});
    \\apply();})();
;

// --- Tests ---

test "[edge] - [html]: values from the files cannot put markup into the page" {
    var buffer: [128]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try writeEscaped(&out, "<script>alert('x')</script>\" & ");
    try std.testing.expectEqualStrings("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;&quot; &amp; ", out.buffered());
}

test "[unit] - [html]: a differing record becomes one section with its rows and counts" {
    var buffer: [64 * 1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var page = Page.init(std.testing.allocator, &out, .{});
    defer page.deinit();
    const sink = page.sink();
    try sink.emit(sink.context, .{
        .record = "scan=5",
        .severity = .critical,
        .kind = .value,
        .path = "spectrum",
        .key = "MS:1000511",
        .name = "ms level",
        .a = "2",
        .b = "<3>",
    });
    try sink.emit(sink.context, .{
        .record = "scan=5",
        .severity = .minor,
        .kind = .narrow,
        .path = "spectrum",
        .key = "MS:1000285",
        .name = "total ion current",
        .a = "1.5",
        .b = "1.5000001",
    });
    const side: output.Side = .{ .path = "a.mzML", .software = "", .spectra = 1, .chromatograms = 0 };
    try page.finish(.{
        .a = side,
        .b = side,
        .paired_spectra = 1,
        .paired_chromatograms = 0,
        .completion = .complete,
        .status = .differs,
        .fail_on = .major,
        .totals = .{ 1, 0, 1 },
        .seconds = null,
    });
    const html = out.buffered();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, html, "<details class=\"rec\""));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, html, "<tr data-s="));
    const first = "<details class=\"rec\" open data-s=\"critical\"><summary><span class=\"id\">scan=5</span>";
    try std.testing.expect(std.mem.indexOf(u8, html, first) != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;3&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<3>") == null);
    try std.testing.expect(std.mem.endsWith(u8, html, "</html>\n"));
}

test "[edge] - [html]: a view past its cap becomes a page that says how to narrow it" {
    var buffer: [32 * 1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var page = Page.init(std.testing.allocator, &out, .{});
    defer page.deinit();
    page.tally.records = 1;
    const sink = page.sink();
    for ([_][]const u8{ "scan=1", "scan=2" }) |record| {
        try sink.emit(sink.context, .{
            .record = record,
            .severity = .major,
            .kind = .value,
            .path = "spectrum/scan",
            .key = "MS:1000512",
            .name = "filter string",
            .a = "x",
            .b = "y",
        });
    }
    const side: output.Side = .{ .path = "a.mzML", .software = "", .spectra = 2, .chromatograms = 0 };
    try page.finish(.{
        .a = side,
        .b = side,
        .paired_spectra = 2,
        .paired_chromatograms = 0,
        .completion = .complete,
        .status = .differs,
        .fail_on = .major,
        .totals = .{ 0, 1, 0 },
        .seconds = null,
    });
    const html = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, html, "<pre class=\"refuse\">mzdiff: too large to view: 2 records differ") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, html, "<details class=\"rec\""));
}
