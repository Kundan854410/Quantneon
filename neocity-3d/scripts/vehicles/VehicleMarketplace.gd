## VehicleMarketplace
## -----------------------------------------------------------------------------
## Player-to-player marketplace for fully customized vehicles.
##
## Responsibilities:
##   * List, browse and search vehicle listings
##   * Instant-buy and auction flows (with anti-sniping extension)
##   * Trade offers between two specific players (swap configs + deltas)
##   * "Most Popular" trending builds leaderboard driven by views / likes / sales
##   * Offline-capable: all state persists to user:// and optionally syncs to a
##     marketplace backend over HTTP when reachable.
extends Node
class_name VehicleMarketplace

## -----------------------------------------------------------------------------
## Signals
## -----------------------------------------------------------------------------
signal listing_created(listing_id: String)
signal listing_cancelled(listing_id: String)
signal listing_purchased(listing_id: String, buyer_id: String, price: int)
signal bid_placed(listing_id: String, bidder_id: String, amount: int)
signal auction_settled(listing_id: String, winner_id: String, price: int)
signal trade_offered(trade_id: String, from_id: String, to_id: String)
signal trade_accepted(trade_id: String)
signal trade_declined(trade_id: String)
signal leaderboard_refreshed(entries: Array)
signal listings_refreshed(count: int)
signal insufficient_funds(required: int, balance: int)
signal network_error(context: String, message: String)

## -----------------------------------------------------------------------------
## Constants
## -----------------------------------------------------------------------------
const LISTING_KIND_INSTANT: String = "instant"
const LISTING_KIND_AUCTION: String = "auction"

const DEFAULT_AUCTION_DURATION_SEC: int = 60 * 60 * 24 # 24 hours
const ANTI_SNIPE_EXTENSION_SEC: int = 60 * 5           # 5 minutes
const ANTI_SNIPE_THRESHOLD_SEC: int = 60 * 2           # Bid within 2 min → extend
const MIN_BID_INCREMENT_PCT: float = 0.05              # 5% over current
const MARKET_FEE_PCT: float = 0.05                     # 5% seller fee
const MAX_LISTINGS_PER_SELLER: int = 25
const MAX_BIDS_PER_LISTING: int = 500
const TRENDING_WINDOW_SEC: int = 60 * 60 * 24 * 7       # 7 days

const PERSIST_PATH: String = "user://vehicle_marketplace.json"
const API_BASE_URL: String = "http://localhost:3000/v1/world/marketplace"
const DEFAULT_TIMEOUT_SEC: float = 8.0

## -----------------------------------------------------------------------------
## Exported fields
## -----------------------------------------------------------------------------
@export var local_user_id: String = "local_user"
@export var use_backend: bool = true
@export var backend_url: String = API_BASE_URL

## -----------------------------------------------------------------------------
## Runtime state
## -----------------------------------------------------------------------------
var listings: Dictionary = {}    # listing_id -> listing dict
var trades: Dictionary = {}      # trade_id -> trade dict
var view_events: Array = []      # [{listing_id, t}]
var like_events: Array = []      # [{listing_id, user_id, t}]
var sale_events: Array = []      # [{listing_id, buyer, seller, price, t}]
var token_balance: int = 10000

var _http: HTTPRequest = null
var _pending_context: String = ""

## -----------------------------------------------------------------------------
## Lifecycle
## -----------------------------------------------------------------------------
func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = DEFAULT_TIMEOUT_SEC
	add_child(_http)
	_http.request_completed.connect(_on_http_completed)
	_load_from_disk()

## -----------------------------------------------------------------------------
## ID helpers
## -----------------------------------------------------------------------------
func _now() -> int:
	return int(Time.get_unix_time_from_system())

func _new_id(prefix: String) -> String:
	return "%s_%d_%d" % [prefix, _now(), randi() % 1_000_000]

## -----------------------------------------------------------------------------
## Listing creation
## -----------------------------------------------------------------------------
## config: VehicleCustomizer.export_configuration() dictionary (or any dict).
## perf:   PerformanceUpgrades.export_state() dictionary (optional, may be {}).
func create_instant_listing(config: Dictionary, perf: Dictionary, price: int, title: String = "", description: String = "", tags: Array = []) -> String:
	if price <= 0:
		push_warning("[Marketplace] Instant listing price must be > 0.")
		return ""
	if _listings_owned_by(local_user_id).size() >= MAX_LISTINGS_PER_SELLER:
		push_warning("[Marketplace] Max listings per seller reached (%d)." % MAX_LISTINGS_PER_SELLER)
		return ""
	var id := _new_id("LIST")
	listings[id] = {
		"id": id,
		"kind": LISTING_KIND_INSTANT,
		"seller": local_user_id,
		"title": title if title != "" else "Untitled Build",
		"description": description,
		"tags": tags.duplicate(),
		"config": config.duplicate(true),
		"perf": perf.duplicate(true),
		"price": int(price),
		"created_at": _now(),
		"expires_at": 0,
		"status": "active",
		"views": 0,
		"likes": 0,
		"likes_by": [],
		"bids": [],
		"buyer": "",
	}
	_persist()
	_sync_listing_to_backend(id)
	emit_signal("listing_created", id)
	return id

func create_auction_listing(config: Dictionary, perf: Dictionary, opening_bid: int, duration_sec: int = DEFAULT_AUCTION_DURATION_SEC, title: String = "", description: String = "", tags: Array = []) -> String:
	if opening_bid <= 0:
		return ""
	if _listings_owned_by(local_user_id).size() >= MAX_LISTINGS_PER_SELLER:
		return ""
	var id := _new_id("AUC")
	listings[id] = {
		"id": id,
		"kind": LISTING_KIND_AUCTION,
		"seller": local_user_id,
		"title": title if title != "" else "Auction Build",
		"description": description,
		"tags": tags.duplicate(),
		"config": config.duplicate(true),
		"perf": perf.duplicate(true),
		"price": int(opening_bid),
		"created_at": _now(),
		"expires_at": _now() + max(60, int(duration_sec)),
		"status": "active",
		"views": 0,
		"likes": 0,
		"likes_by": [],
		"bids": [],
		"buyer": "",
	}
	_persist()
	_sync_listing_to_backend(id)
	emit_signal("listing_created", id)
	return id

func cancel_listing(listing_id: String) -> bool:
	if not listings.has(listing_id):
		return false
	var l = listings[listing_id]
	if l.seller != local_user_id:
		return false
	if l.status != "active":
		return false
	# If there are bids, we must refund the highest bidder (hold release).
	if l.kind == LISTING_KIND_AUCTION and l.bids.size() > 0:
		# Refunds handled by authoritative backend in production; for local we
		# simulate by leaving token custody intact (no deductions on bid here).
		pass
	l.status = "cancelled"
	_persist()
	emit_signal("listing_cancelled", listing_id)
	return true

func _listings_owned_by(user_id: String) -> Array:
	var out: Array = []
	for id in listings.keys():
		if listings[id].seller == user_id and listings[id].status == "active":
			out.append(listings[id])
	return out

## -----------------------------------------------------------------------------
## Browsing / search
## -----------------------------------------------------------------------------
func list_all_active() -> Array:
	var out: Array = []
	for id in listings.keys():
		if listings[id].status == "active":
			out.append(listings[id])
	return out

func search(query: String = "", tag: String = "", kind: String = "", min_price: int = -1, max_price: int = -1) -> Array:
	var q: String = query.strip_edges().to_lower()
	var results: Array = []
	for l in list_all_active():
		if kind != "" and l.kind != kind:
			continue
		if min_price >= 0 and l.price < min_price:
			continue
		if max_price >= 0 and l.price > max_price:
			continue
		if tag != "" and not (tag in l.tags):
			continue
		if q != "":
			var blob: String = (String(l.title) + " " + String(l.description)).to_lower()
			if blob.find(q) == -1:
				continue
		results.append(l)
	return results

func view_listing(listing_id: String) -> Dictionary:
	if not listings.has(listing_id):
		return {}
	var l = listings[listing_id]
	l.views = int(l.views) + 1
	view_events.append({"listing_id": listing_id, "t": _now()})
	_persist()
	return l.duplicate(true)

func toggle_like(listing_id: String) -> bool:
	if not listings.has(listing_id):
		return false
	var l = listings[listing_id]
	if local_user_id in l.likes_by:
		l.likes_by.erase(local_user_id)
		l.likes = max(0, int(l.likes) - 1)
	else:
		l.likes_by.append(local_user_id)
		l.likes = int(l.likes) + 1
		like_events.append({"listing_id": listing_id, "user_id": local_user_id, "t": _now()})
	_persist()
	return true

## -----------------------------------------------------------------------------
## Instant buy
## -----------------------------------------------------------------------------
func buy_instant(listing_id: String) -> bool:
	if not listings.has(listing_id):
		return false
	var l = listings[listing_id]
	if l.status != "active" or l.kind != LISTING_KIND_INSTANT:
		return false
	if l.seller == local_user_id:
		push_warning("[Marketplace] Cannot buy your own listing.")
		return false
	var price: int = int(l.price)
	if token_balance < price:
		emit_signal("insufficient_funds", price, token_balance)
		return false
	token_balance -= price
	l.status = "sold"
	l.buyer = local_user_id
	sale_events.append({"listing_id": listing_id, "buyer": local_user_id, "seller": l.seller, "price": price, "t": _now()})
	_persist()
	emit_signal("listing_purchased", listing_id, local_user_id, price)
	return true

## -----------------------------------------------------------------------------
## Auction bidding
## -----------------------------------------------------------------------------
func current_high_bid(listing_id: String) -> Dictionary:
	if not listings.has(listing_id):
		return {}
	var l = listings[listing_id]
	if l.bids.size() == 0:
		return {"amount": int(l.price), "bidder": ""}
	return l.bids[-1]

func min_next_bid(listing_id: String) -> int:
	if not listings.has(listing_id):
		return 0
	var high = current_high_bid(listing_id)
	var cur: int = int(high.get("amount", 0))
	return int(round(float(cur) * (1.0 + MIN_BID_INCREMENT_PCT)))

func place_bid(listing_id: String, amount: int) -> bool:
	if not listings.has(listing_id):
		return false
	var l = listings[listing_id]
	if l.status != "active" or l.kind != LISTING_KIND_AUCTION:
		return false
	if _now() >= int(l.expires_at):
		_settle_auction(listing_id)
		return false
	if l.seller == local_user_id:
		return false
	var floor_amt: int = max(int(l.price), min_next_bid(listing_id))
	if amount < floor_amt:
		return false
	if token_balance < amount:
		emit_signal("insufficient_funds", amount, token_balance)
		return false
	if l.bids.size() >= MAX_BIDS_PER_LISTING:
		return false
	l.bids.append({"amount": int(amount), "bidder": local_user_id, "t": _now()})
	# Anti-sniping extension if the bid lands in the final window.
	var remaining: int = int(l.expires_at) - _now()
	if remaining <= ANTI_SNIPE_THRESHOLD_SEC:
		l.expires_at = int(l.expires_at) + ANTI_SNIPE_EXTENSION_SEC
	_persist()
	emit_signal("bid_placed", listing_id, local_user_id, int(amount))
	return true

func settle_expired_auctions() -> int:
	var n := 0
	for id in listings.keys():
		var l = listings[id]
		if l.kind == LISTING_KIND_AUCTION and l.status == "active" and _now() >= int(l.expires_at):
			_settle_auction(id)
			n += 1
	return n

func _settle_auction(listing_id: String) -> void:
	if not listings.has(listing_id):
		return
	var l = listings[listing_id]
	if l.status != "active":
		return
	if l.bids.size() == 0:
		l.status = "expired"
		_persist()
		emit_signal("auction_settled", listing_id, "", 0)
		return
	var top = l.bids[-1]
	var winner: String = String(top.get("bidder", ""))
	var price: int = int(top.get("amount", 0))
	l.status = "sold"
	l.buyer = winner
	# Only deduct from the local user's balance if they are the winner. In a
	# real backend balances are held on bid placement; this local mock only
	# touches the player's balance at settlement to keep accounting simple.
	if winner == local_user_id:
		if token_balance >= price:
			token_balance -= price
		else:
			# Edge case: balance changed between bid and settle; demote listing
			# back to runner-up if present, else mark as disputed.
			l.bids.pop_back()
			if l.bids.size() > 0:
				_settle_auction(listing_id)
				return
			else:
				l.status = "disputed"
				_persist()
				emit_signal("auction_settled", listing_id, "", 0)
				return
	sale_events.append({"listing_id": listing_id, "buyer": winner, "seller": l.seller, "price": price, "t": _now()})
	_persist()
	emit_signal("auction_settled", listing_id, winner, price)

func seller_payout(price: int) -> int:
	# Net payout after marketplace fee.
	return int(round(float(price) * (1.0 - MARKET_FEE_PCT)))

## -----------------------------------------------------------------------------
## Trades (direct player-to-player swap)
## -----------------------------------------------------------------------------
func propose_trade(to_user_id: String, offered_config: Dictionary, offered_perf: Dictionary, requested_config: Dictionary, token_delta: int = 0, note: String = "") -> String:
	if to_user_id == "" or to_user_id == local_user_id:
		return ""
	var id := _new_id("TRADE")
	trades[id] = {
		"id": id,
		"from": local_user_id,
		"to": to_user_id,
		"offered_config": offered_config.duplicate(true),
		"offered_perf": offered_perf.duplicate(true),
		"requested_config": requested_config.duplicate(true),
		"token_delta": int(token_delta),  # + means "from" pays "to"; - means inverse.
		"note": note,
		"created_at": _now(),
		"status": "pending",
	}
	_persist()
	emit_signal("trade_offered", id, local_user_id, to_user_id)
	return id

func accept_trade(trade_id: String) -> bool:
	if not trades.has(trade_id):
		return false
	var t = trades[trade_id]
	if t.status != "pending":
		return false
	if t.to != local_user_id:
		return false
	var delta: int = int(t.token_delta)
	# Token flow: positive means initiator pays acceptor.
	if delta < 0:
		if token_balance < -delta:
			emit_signal("insufficient_funds", -delta, token_balance)
			return false
		token_balance -= -delta
	else:
		token_balance += delta
	t.status = "accepted"
	_persist()
	emit_signal("trade_accepted", trade_id)
	return true

func decline_trade(trade_id: String) -> bool:
	if not trades.has(trade_id):
		return false
	var t = trades[trade_id]
	if t.status != "pending":
		return false
	if t.to != local_user_id:
		return false
	t.status = "declined"
	_persist()
	emit_signal("trade_declined", trade_id)
	return true

func list_trades_for_user(user_id: String) -> Array:
	var out: Array = []
	for id in trades.keys():
		var t = trades[id]
		if t.from == user_id or t.to == user_id:
			out.append(t)
	return out

## -----------------------------------------------------------------------------
## Trending / leaderboard
## -----------------------------------------------------------------------------
func leaderboard_trending(limit: int = 20) -> Array:
	# Score = 3*sales + 1*likes + 0.1*views within the trending window.
	var cutoff: int = _now() - TRENDING_WINDOW_SEC
	var score_by_id: Dictionary = {}
	for ev in view_events:
		if int(ev.t) < cutoff:
			continue
		score_by_id[ev.listing_id] = float(score_by_id.get(ev.listing_id, 0.0)) + 0.1
	for ev in like_events:
		if int(ev.t) < cutoff:
			continue
		score_by_id[ev.listing_id] = float(score_by_id.get(ev.listing_id, 0.0)) + 1.0
	for ev in sale_events:
		if int(ev.t) < cutoff:
			continue
		score_by_id[ev.listing_id] = float(score_by_id.get(ev.listing_id, 0.0)) + 3.0
	var entries: Array = []
	for id in score_by_id.keys():
		if not listings.has(id):
			continue
		var l = listings[id]
		entries.append({
			"listing_id": id,
			"title": l.title,
			"seller": l.seller,
			"score": float(score_by_id[id]),
			"views": l.views,
			"likes": l.likes,
		})
	entries.sort_custom(func(a, b): return a.score > b.score)
	if entries.size() > limit:
		entries = entries.slice(0, limit)
	emit_signal("leaderboard_refreshed", entries)
	return entries

func leaderboard_top_sellers(limit: int = 10) -> Array:
	var totals: Dictionary = {}  # seller -> total revenue
	var cutoff: int = _now() - TRENDING_WINDOW_SEC
	for ev in sale_events:
		if int(ev.t) < cutoff:
			continue
		totals[ev.seller] = int(totals.get(ev.seller, 0)) + int(ev.price)
	var out: Array = []
	for seller in totals.keys():
		out.append({"seller": seller, "revenue": int(totals[seller])})
	out.sort_custom(func(a, b): return a.revenue > b.revenue)
	if out.size() > limit:
		out = out.slice(0, limit)
	return out

## -----------------------------------------------------------------------------
## Persistence
## -----------------------------------------------------------------------------
func _persist() -> void:
	var f := FileAccess.open(PERSIST_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"version": 1,
		"listings": listings,
		"trades": trades,
		"views": view_events,
		"likes": like_events,
		"sales": sale_events,
		"balance": token_balance,
	}))
	f.close()

func _load_from_disk() -> void:
	if not FileAccess.file_exists(PERSIST_PATH):
		return
	var f := FileAccess.open(PERSIST_PATH, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	listings = parsed.get("listings", {})
	trades = parsed.get("trades", {})
	view_events = parsed.get("views", [])
	like_events = parsed.get("likes", [])
	sale_events = parsed.get("sales", [])
	token_balance = int(parsed.get("balance", token_balance))
	emit_signal("listings_refreshed", listings.size())

## -----------------------------------------------------------------------------
## Backend sync (best-effort)
## -----------------------------------------------------------------------------
func refresh_from_backend() -> void:
	if not use_backend:
		return
	_pending_context = "refresh"
	var err := _http.request(backend_url + "/listings")
	if err != OK:
		emit_signal("network_error", "refresh", "request failed: " + str(err))

func _sync_listing_to_backend(listing_id: String) -> void:
	if not use_backend:
		return
	if not listings.has(listing_id):
		return
	_pending_context = "sync_" + listing_id
	var body := JSON.stringify(listings[listing_id])
	var headers := ["Content-Type: application/json"]
	var err := _http.request(backend_url + "/listings", headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		emit_signal("network_error", "sync", "request failed: " + str(err))

func _on_http_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		emit_signal("network_error", _pending_context, "transport_error=" + str(result))
		_pending_context = ""
		return
	if response_code < 200 or response_code >= 300:
		emit_signal("network_error", _pending_context, "http=" + str(response_code))
		_pending_context = ""
		return
	if _pending_context == "refresh":
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		if typeof(parsed) == TYPE_ARRAY:
			# Merge server-side listings, preferring the server's version.
			for item in parsed:
				if typeof(item) == TYPE_DICTIONARY and item.has("id"):
					listings[item.id] = item
			_persist()
			emit_signal("listings_refreshed", listings.size())
	_pending_context = ""

## -----------------------------------------------------------------------------
## Convenience / debugging
## -----------------------------------------------------------------------------
func total_listings_count() -> int:
	return listings.size()

func active_listings_count() -> int:
	var n := 0
	for id in listings.keys():
		if listings[id].status == "active":
			n += 1
	return n

func set_token_balance(value: int) -> void:
	token_balance = max(0, value)
	_persist()

func add_tokens(amount: int) -> void:
	token_balance = max(0, token_balance + amount)
	_persist()

func describe_listing(listing_id: String) -> String:
	if not listings.has(listing_id):
		return ""
	var l = listings[listing_id]
	var kind_label: String = ("Auction" if l.kind == LISTING_KIND_AUCTION else "Buy Now")
	return "[%s] %s — %d QNT by %s (views %d, likes %d)" % [kind_label, l.title, int(l.price), l.seller, int(l.views), int(l.likes)]
