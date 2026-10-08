"""Decide which AH character should post each sellable non-commodity item (DWM card 0001).

Run by build.ps1, which prepares the work folder. Inputs in --work:
  items.tsv  - Syndicator dump (dump.lua): owner, location, itemID, species, count, bound,
               quality, name, link, expiry
  acct.tsv   - TSM accounting (tsmacct.lua): kind, realm, csv row
  r<id>.bin  - undermine.exchange state.free.bin per connected realm
--appdata is TSM's AppData.lua (AuctionDB). Outputs:
  --plan     Data/AHPlan.lua for the addon
  --report   CSV files and the plan as a table, for a person to read
"""
import argparse
import collections
import gzip
import os
import re
import struct
import sys
import time

ap = argparse.ArgumentParser()
ap.add_argument("--appdata", required=True)
ap.add_argument("--work", required=True)
ap.add_argument("--report", required=True)
ap.add_argument("--plan", required=True)
ARGS = ap.parse_args()
APPDATA = ARGS.appdata
os.chdir(ARGS.work)

# Storage that somebody can open today. Creality's guild banks are out: every member is on an
# unsubscribed account (Rob, 2026-10-07). A copy anywhere else is ignored, so the plan never
# counts on stock that cannot arrive.
REACHABLE_STORAGE = {
    "WARBAND",
    "GUILD:Anything for Profit-Ghostlands",
    "GUILD:Storinator-Aggra(Português)",
    "GUILD:Transmog DOESNT Sell-Shadowsong",
}
# The one guild bank every AH character belongs to; the addon moves items through it.
TRANSPORT_GUILD = "Anything for Profit"
# Storage guild banks the AH characters cannot open, and the character who empties each one
# into the warband bank, where the AH characters pick the items up (card 0004). Guild name as
# GetGuildInfo returns it, without the realm.
FEEDERS = {
    "GUILD:Transmog DOESNT Sell-Shadowsong": ("Jinn-Shadowsong", "Transmog DOESNT Sell"),
    "GUILD:Storinator-Aggra(Português)": ("Pouches-Aggra(Português)", "Storinator"),
}

# Connected realm groups: undermine id, TSM realm name used for AuctionDB, the AH character.
GROUPS = {
    "Aggra": dict(cid=1303, tsm="Aggra (Português)", char="Buyme-Aggra(Português)",
                  realms={"Aggra (Português)", "Grim Batol", "Frostmane", "Aggra(Português)", "GrimBatol"}),
    "Shadowsong": dict(cid=3666, tsm="Shadowsong", char="What-Shadowsong",
                       realms={"Shadowsong", "Aszune"}),
    "Moonglade": dict(cid=1085, tsm="Moonglade", char="Loamint-Moonglade",
                      realms={"Moonglade", "Steamwheedle Cartel", "The Sha'tar"}),
    "Ghostlands": dict(cid=1596, tsm="Ghostlands", char="Hotwheel-Ghostlands",
                       realms={"Ghostlands", "Dragonblight", "Deathwing", "The Maelstrom",
                               "Lightning's Blade", "Karazhan"}),
}
CHAR_GROUP = {g["char"]: k for k, g in GROUPS.items()}


def realm_group(realm):
    for k, g in GROUPS.items():
        if realm in g["realms"]:
            return k
    return None


def base_key(item_string):
    """i:123::i78 -> i:123 ; p:1446:25:3 -> p:1446"""
    parts = item_string.split(":")
    return parts[0] + ":" + parts[1]


# ---------- TSM AuctionDB ----------
tsm = collections.defaultdict(dict)  # (kind, realm) -> base key -> dict of fields (min over variants)
text = open(APPDATA, encoding="utf-8").read()
for m in re.finditer(r'LoadData\("([A-Z_]+)","([^"]*)",\[\[return \{downloadTime=\d+,fields=\{([^}]*)\},data=\{(.*?)\}\}\]\]', text, re.S):
    kind, realm, fields, data = m.groups()
    fields = [f.strip('"') for f in fields.split(",")][1:]
    table = tsm[(kind, realm)]
    for im in re.finditer(r'\{"?([^,"]+)"?,([^}]+)\}', data):
        key = im.group(1)
        if key[0].isdigit():
            key = "i:" + key
        vals = [int(v, 32) for v in im.group(2).split(",")]
        row = dict(zip(fields, vals))
        b = base_key(key)
        if key == b or b not in table:
            # prefer the base entry; otherwise keep the first variant seen
            table[b] = row
commodities = set(tsm[("AUCTIONDB_COMMODITY_DATA", "EU")]) | set(tsm[("AUCTIONDB_COMMODITY_SCAN_STAT", "EU")])
region_sale = tsm[("AUCTIONDB_REGION_SALE", "EU")]
region_stat = tsm[("AUCTIONDB_REGION_STAT", "EU")]


# ---------- undermine.exchange ----------
def read_undermine(path):
    b = open(path, "rb").read()
    if b[:2] == b"\x1f\x8b":
        b = gzip.decompress(b)
    o = 0

    def rd(fmt):
        nonlocal o
        v = struct.unpack_from("<" + fmt, b, o)
        o += struct.calcsize(fmt)
        return v[0] if len(v) == 1 else v

    rd("B")
    rd("I")
    rd("I")
    for _ in range(rd("H")):
        rd("I")
    out = {}
    for _ in range(rd("I")):
        item, level, suffix, snap, price, qty = rd("IHHIII")
        key = f"p:{level}" if item == 82800 else f"i:{item}"
        cur = out.get(key)
        price *= 100
        if cur is None:
            out[key] = dict(price=price, qty=qty, snap=snap)
        else:
            if qty and (not cur["qty"] or price < cur["price"]):
                cur["price"] = price
            cur["qty"] += qty
    return out


um = {k: read_undermine(f"r{g['cid']}.bin") for k, g in GROUPS.items()}

# ---------- holdings ----------
held = []
for line in open("items.tsv", encoding="utf-8"):
    f = line.rstrip("\n").split("\t")
    owner, loc, item_id, species, count, bound, quality, name = f[:8]
    if owner not in CHAR_GROUP and owner not in REACHABLE_STORAGE:
        continue
    key = f"p:{species}" if species else f"i:{item_id}"
    held.append(dict(owner=owner, loc=loc, key=key, count=int(count), bound=bound == "true",
                     quality=int(quality or 0), name=name))

own_listed = collections.Counter()  # (group, key) -> our own auctions
for h in held:
    if h["loc"] == "auction":
        own_listed[(CHAR_GROUP[h["owner"]], h["key"])] += 1

# ---------- own sales history ----------
# TSM logs units, not auctions: 20 food in one stack expiring is 20 units. Thresholds use posting
# ROUNDS instead: expiries of one item on one AH within 2 hours of each other are one round, because
# a round of posts expires together. Sell-through stays a unit ratio (units sold / units listed).
hist = collections.defaultdict(lambda: collections.Counter())  # (group,key) -> counters
exp_times = collections.defaultdict(list)
for line in open("acct.tsv", encoding="utf-8"):
    kind, realm, row = line.rstrip("\n").split("\t", 2)
    g = realm_group(realm)
    if not g:
        continue
    f = row.split(",")
    key = base_key(f[0])
    qty = int(f[2])
    if kind == "Sales":
        hist[(g, key)]["sold_units"] += qty
        hist[(g, key)]["sold"] += 1  # one row per sale
    else:
        hist[(g, key)]["exp_units"] += qty
        exp_times[(g, key)].append(int(f[-1]))
for k, times in exp_times.items():
    times.sort()
    rounds, last = 0, None
    for t in times:
        if last is None or t - last > 7200:
            rounds += 1
        last = t
    hist[k]["expired"] = rounds


def market(group, key):
    """Return (marketValue, minBuyout, competitorAuctions) for one AH."""
    g = GROUPS[group]
    mine = own_listed[(group, key)]
    if g["tsm"]:
        d = tsm[("AUCTIONDB_NON_COMMODITY_DATA", g["tsm"])].get(key, {})
        s = tsm[("AUCTIONDB_NON_COMMODITY_SCAN_STAT", g["tsm"])].get(key, {})
        mv = s.get("marketValue") or d.get("marketValueRecent") or 0
        mb = d.get("minBuyout") or 0
        n = d.get("numAuctions") or 0
    else:
        mv = mb = n = 0
    u = um[group].get(key)
    if u and u["qty"]:
        # undermine is the newer snapshot: use it for live listings
        mb = u["price"]
        n = u["qty"]
        if not mv:
            mv = u["price"]
    elif u is not None and not u["qty"]:
        n = 0
        mb = 0
    return mv, mb, max(0, n - mine)


def score(group, key, region_mv):
    mv, mb, comp = market(group, key)
    # Placeholder listings (10,000,000g and similar) poison a thin market, so a realm's own value
    # only counts when it sits within 3x the EU-wide value. Moonglade has no TSM realm data, so its
    # "market value" is undermine's cheapest listing and gets the same cap.
    cap = region_mv * 3 if region_mv else None
    ref = mv if mv and (cap is None or mv <= cap) else region_mv
    if comp and mb:
        # undercut the cheapest rival, but never ask above 1.5x the reference value
        ask = min(mb, int(ref * 1.5)) if ref else mb
    else:
        ask = ref
    h = hist[(group, key)]
    sold, exp = h["sold"], h["expired"]
    su, eu = h["sold_units"], h["exp_units"]
    track = (su + 1) / (su + eu + 2)  # Laplace-smoothed own unit sell-through on that AH
    return ask / (1 + comp) * (0.5 + track), ask, comp, mv, sold, exp, su, eu


# ---------- plan ----------
# A guild bank is storage, never an AH, even when its realm matches an AH character's: guilds are
# cross-realm now, so the realm in a guild's name says nothing about who posts from it.
LOC_GROUP = {}
for h in held:
    o = h["owner"]
    LOC_GROUP[o] = CHAR_GROUP.get(o, "storage")

# Which character opens each storage guild bank (from Syndicator character details).
OPENED_BY = {
    "GUILD:Storinator-Aggra(Português)": "the addon: Pouches to the warband bank",
    "GUILD:Transmog DOESNT Sell-Shadowsong": "the addon: Jinn to the warband bank",
    "GUILD:Anything for Profit-Ghostlands": "the addon, on any AH character",
    "WARBAND": "the addon, on any AH character",
}

agg = collections.defaultdict(lambda: dict(n=0, where=collections.Counter(), name="", quality=0))
for h in held:
    if h["bound"] or h["key"] in commodities or h["quality"] < 1:
        continue
    a = agg[h["key"]]
    a["n"] += h["count"]
    a["where"][f"{h['owner']}|{h['loc']}"] += h["count"]
    a["name"] = h["name"]
    a["quality"] = h["quality"]

rows = []
for key, a in agg.items():
    rs = region_sale.get(key, {})
    region_mv = region_stat.get(key, {}).get("regionMarketValue", 0)
    per = {g: score(g, key, region_mv) for g in GROUPS}
    ranked = sorted(per, key=lambda g: per[g][0], reverse=True)
    rows.append(dict(key=key, name=a["name"], n=a["n"], where=a["where"], per=per, ranked=ranked,
                     region_mv=region_mv, sale_rate=rs.get("regionSalePercent", 0),
                     sold_per_day=rs.get("regionSoldPerDay", 0)))

os.makedirs(ARGS.report, exist_ok=True)
with open(os.path.join(ARGS.report, "all-items-by-AH.tsv"), "w", encoding="utf-8") as out:
    cols = ["key", "name", "count", "now_at", "best", "second", "region_mv_g", "region_sale_pct", "region_sold_day"]
    for g in GROUPS:
        cols += [f"{g}_ask_g", f"{g}_rivals", f"{g}_mv_g", f"{g}_sold", f"{g}_expired"]
    out.write("\t".join(cols) + "\n")
    for r in sorted(rows, key=lambda r: -r["per"][r["ranked"][0]][1] * r["n"]):
        cells = [r["key"], r["name"], str(r["n"]),
                 "; ".join(f"{k}x{v}" for k, v in r["where"].items()),
                 r["ranked"][0], r["ranked"][1], f"{r['region_mv'] / 10000:.0f}",
                 f"{r['sale_rate'] / 100:.1f}", f"{r['sold_per_day'] / 100:.2f}"]
        for g in GROUPS:
            sc, ask, comp, mv, sold, exp = r["per"][g][:6]
            cells += [f"{ask / 10000:.0f}", str(comp), f"{mv / 10000:.0f}", str(sold), str(exp)]
        out.write("\t".join(cells) + "\n")
print("rows", len(rows), "commodities skipped:",
      sum(1 for h in held if h["key"] in commodities and not h["bound"]))

# ---------- allocation ----------
# Each AH has thin demand for one item, so copies are spread: the k-th copy placed on an AH
# scores that AH at score/(1+k). A copy already on an AH character only moves when the target
# scores at least 1.5x better, or when TSM shows it failing there (10+ expiries, no sale).
MIN_ASK = 100 * 10000  # under 100g a cross-realm move is not worth the effort
GAIN = 3.0             # a posted copy needs a 3x better spot, and must have been tried (3+ expiries)
TRIED = 3
DEAD_EXPIRES = 10
moves, keeps, dead = [], [], []
for r in rows:
    per = r["per"]
    best_ask = max(per[g][1] for g in GROUPS)
    if best_ask < MIN_ASK:
        continue
    # failing wherever we have tried it, and almost nobody in the EU buys it: a price or vendor
    # problem, not a placement one, so it is listed as dead stock and not moved
    total_sold = sum(per[g][4] for g in GROUPS)
    total_exp = sum(per[g][5] for g in GROUPS)
    if total_sold == 0 and total_exp >= 15 and r["sold_per_day"] < 5:  # regionSoldPerDay is x100
        dead.append(r)
        continue
    copies = []
    for where, cnt in r["where"].items():
        owner, loc = where.split("|")
        copies += [(owner, loc, LOC_GROUP[owner])] * cnt
    alloc = collections.Counter()
    targets = []
    for _ in copies:
        g = max(GROUPS, key=lambda g: per[g][0] / (1 + alloc[g]))
        alloc[g] += 1
        targets.append(g)
    left = collections.Counter(targets)
    pending = []
    for c in copies:
        if c[2] in GROUPS and left[c[2]] > 0:
            left[c[2]] -= 1
            keeps.append((r, c))
        else:
            pending.append(c)
    spare = list(left.elements())
    for c in pending:
        t = spare.pop(0)
        cur = c[2]
        if cur in GROUPS:
            failing = per[cur][4] == 0 and per[cur][5] >= DEAD_EXPIRES
            better = per[t][0] >= GAIN * per[cur][0] and per[cur][5] >= TRIED
            su, eu = per[cur][6], per[cur][7]
            selling = su and su / (su + eu) >= 0.2  # it already sells here: leave it alone
            if selling or not (failing or better):
                keeps.append((r, c))
                continue
        moves.append((r, c, t))

OUT = ARGS.report
import csv
import os
os.makedirs(OUT, exist_ok=True)
SHORT = {g: GROUPS[g]["char"].split("-")[0] for g in GROUPS}


def gold(c):
    return f"{c / 10000:,.0f}g"


def why(r, src, t):
    p = r["per"]
    bits = []
    if src in GROUPS:
        bits.append(f"{src}: {p[src][4]} sales, expired in {p[src][5]} posting rounds, {p[src][2]} rivals")
    bits.append(f"{t}: {p[t][2]} rivals, ask {gold(p[t][1])}")
    return "; ".join(bits)


byrow = {r["key"]: r for r in rows}


def write_moves(path, subset):
    with open(path, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["Give to", "Item", "Count", "Take from", "Where now", "Opened by", "Suggested price",
                    "Rivals there", "EU sold/day", "Why"])
        grouped = collections.Counter()
        for r, c, t in subset:
            grouped[(t, r["key"], c[0], c[1])] += 1
        for (t, key, owner, loc), n in sorted(grouped.items(),
                                              key=lambda x: (x[0][0], -byrow[x[0][1]]["per"][x[0][0]][1])):
            r = byrow[key]
            src = LOC_GROUP[owner]
            w.writerow([GROUPS[t]["char"], r["name"], n, owner.replace("GUILD:", "guild bank "), loc,
                        OPENED_BY.get(owner, owner.split("-")[0]), gold(r["per"][t][1]), r["per"][t][2], f"{r['sold_per_day'] / 100:.2f}", why(r, src, t)])


between = [m for m in moves if m[1][0] in CHAR_GROUP]
storage = [m for m in moves if m[1][0] not in CHAR_GROUP]
write_moves(os.path.join(OUT, "1-moves-between-AH-characters.csv"), between)
write_moves(os.path.join(OUT, "2-post-from-storage.csv"), storage)

with open(os.path.join(OUT, "holdings.csv"), "w", newline="", encoding="utf-8-sig") as f:
    w = csv.writer(f)
    w.writerow(["Character", "Where", "Item", "Count", "Commodity", "Bound"])
    agg2 = collections.Counter()
    for h in held:
        if h["owner"] in CHAR_GROUP:
            agg2[(h["owner"], h["loc"], h["name"], h["key"] in commodities, h["bound"])] += h["count"]
    for (o, l, n, com, b), cnt in sorted(agg2.items()):
        w.writerow([o, l, n, cnt, "yes" if com else "", "yes" if b else ""])

with open(os.path.join(OUT, "dead-stock.csv"), "w", newline="", encoding="utf-8-sig") as f:
    w = csv.writer(f)
    w.writerow(["Item", "Count held", "Sales (all 4 AHs)", "Posting rounds expired (all 4 AHs)", "EU market",
                "EU sold/day"])
    for r in sorted(dead, key=lambda r: -sum(r["per"][g][5] for g in GROUPS)):
        w.writerow([r["name"], r["n"], sum(r["per"][g][4] for g in GROUPS), sum(r["per"][g][5] for g in GROUPS),
                    gold(r["region_mv"]), f"{r['sold_per_day'] / 100:.2f}"])

# Commodities sit on one EU-wide AH, so any character can post them. Listed only from storage,
# valued at the TSM EU commodity market value.
com_mv = tsm[("AUCTIONDB_COMMODITY_SCAN_STAT", "EU")]
com_data = tsm[("AUCTIONDB_COMMODITY_DATA", "EU")]
com_rows = collections.defaultdict(lambda: dict(n=0, name=""))
for h in held:
    if h["owner"] in CHAR_GROUP or h["key"] not in commodities or h["bound"]:
        continue
    c = com_rows[(h["owner"], h["key"])]
    c["n"] += h["count"]
    c["name"] = h["name"]
with open(os.path.join(OUT, "3-commodities-in-storage.csv"), "w", newline="", encoding="utf-8-sig") as f:
    w = csv.writer(f)
    w.writerow(["Storage", "Opened by", "Item", "Count", "EU market each", "Stack value", "EU sold/day",
                "EU listed now"])
    out_rows = []
    for (owner, key), c in com_rows.items():
        mv = com_mv.get(key, {}).get("marketValue") or com_data.get(key, {}).get("marketValueRecent") or 0
        out_rows.append((mv * c["n"], owner, key, c, mv))
    for total, owner, key, c, mv in sorted(out_rows, reverse=True, key=lambda x: x[0]):
        if total < MIN_ASK:
            continue
        w.writerow([owner.replace("GUILD:", ""), OPENED_BY.get(owner, "?"), c["name"], c["n"], gold(mv), gold(total),
                    f"{region_sale.get(key, {}).get('regionSoldPerDay', 0) / 100:.0f}",
                    com_data.get(key, {}).get("numAuctions", 0)])
storage_val = collections.Counter()
for total, owner, key, c, mv in out_rows:
    storage_val[owner] += total
print("commodity value in storage", {k: gold(v) for k, v in storage_val.items()})

# summary for the chat
print("moves", len(moves), "keeps", len(keeps), "dead", len(dead))
mv_by = collections.Counter()
val_by = collections.Counter()
for r, c, t in moves:
    mv_by[(LOC_GROUP[c[0]] if LOC_GROUP[c[0]] in GROUPS else "storage", t)] += 1
    val_by[t] += r["per"][t][1]
for k, v in sorted(mv_by.items()):
    print("move", k, v)
src_by = collections.Counter(c[0] for r, c, t in moves if c[0] not in CHAR_GROUP)
print("storage sources", dict(src_by))
for t, v in val_by.items():
    print("value into", t, gold(v))
posted = collections.Counter()
for h in held:
    if h["loc"] == "auction":
        posted[h["owner"]] += 1
print("posted now", dict(posted))

# ---------- plan file for the addon ----------
# How many copies each AH character should hold (bags + posted + mail). Battle pets are left
# out: every caged pet is item 82800, and the addon matches on item ID.
target = collections.defaultdict(collections.Counter)  # char -> itemID -> copies
names = {}
for r, c in keeps:
    if r["key"].startswith("i:"):
        target[GROUPS[c[2]]["char"]][int(r["key"][2:])] += 1
        names[int(r["key"][2:])] = r["name"]
for r, c, t in moves:
    if r["key"].startswith("i:"):
        target[GROUPS[t]["char"]][int(r["key"][2:])] += 1
        names[int(r["key"][2:])] = r["name"]


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def comment(s):
    return re.sub(r"[\r\n]", " ", s)


lines = [
    "-- GENERATED by tools/ahplan/build.ps1 (DWM card 0001). Do not edit by hand: rebuild instead.",
    "local _, ns = ...",
    "ns.AHPlanData = {",
    f"    generated = {lua_str(time.strftime('%Y-%m-%d %H:%M'))},",
    f"    transportGuild = {lua_str(TRANSPORT_GUILD)},",
    "    posters = {",
]
for g in GROUPS.values():
    char = g["char"]
    lines.append(f"        [{lua_str(char)}] = {{")
    for item_id, n in sorted(target[char].items()):
        lines.append(f"            [{item_id}] = {n}, -- {comment(names[item_id])}")
    lines.append("        },")
lines.append("    },")

# What each feeder takes out of its storage guild bank: every planned copy that sits there.
feed = collections.defaultdict(collections.Counter)  # source -> itemID -> copies
for r, c, t in moves:
    if c[0] in FEEDERS and r["key"].startswith("i:"):
        feed[c[0]][int(r["key"][2:])] += 1
lines.append("    feeders = {")
for src, (char, guild) in FEEDERS.items():
    lines.append(f"        [{lua_str(char)}] = {{ guild = {lua_str(guild)}, items = {{")
    for item_id, n in sorted(feed[src].items()):
        lines.append(f"            [{item_id}] = {n}, -- {comment(names[item_id])}")
    lines.append("        } },")
lines += ["    },", "}", ""]
with open(ARGS.plan, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(lines))
print("plan written:", ARGS.plan, {c: sum(v.values()) for c, v in target.items()})
print("feeders:", {FEEDERS[s][0]: sum(v.values()) for s, v in feed.items()})
