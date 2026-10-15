open! Core
module Price = Market_data.Price
module Size = Market_data.Size

module Config = struct
  type t =
    { seed : int
    ; coin : string
    ; start : Time_ns.t
    ; duration : Time_ns.Span.t
    ; start_px : float
    ; step_bps : float
    ; book_every : Time_ns.Span.t
    ; level_size : float
    ; trades_per_book : int
    ; decide_every : Time_ns.Span.t
    ; max_position : float
    ; funding_rate : float
    }
  [@@deriving sexp]

  let default =
    { seed = 1
    ; coin = "BTC"
    ; start = Time_ns.of_string_with_utc_offset "2026-10-16T00:30:00Z"
    ; duration = Time_ns.Span.hour
    ; start_px = 100_000.
    ; step_bps = 0.5
    ; book_every = Time_ns.Span.of_int_ms 250
    ; level_size = 1.
    ; trades_per_book = 2
    ; decide_every = Time_ns.Span.of_int_sec 30
    ; max_position = 2.
    ; funding_rate = 0.0000125
    }
  ;;
end

type t =
  { events : Market_data.Event.t list
  ; fills : Hl_protocol.User_fill.t list
  ; leader : Hl_protocol.Address.t
  }

let leader = Hl_protocol.Address.of_string "0x5e1ec7ed00000000000000000000000000000001"

(* Prices and sizes are rounded to whole units of the grid so every value is exact. *)
let price x = (Price.of_float [@alert "-lossy"]) (Float.round_decimal x ~decimal_digits:0)
let size x = (Size.of_float [@alert "-lossy"]) (Float.round_decimal x ~decimal_digits:5)

let generate (c : Config.t) =
  let rand = Random.State.make [| c.seed |] in
  let instrument =
    Market_data.Instrument.create Market_data.Venue.Hyperliquid c.coin
  in
  let start = Time_ns.to_int_ns_since_epoch c.start in
  let stop = start + Time_ns.Span.to_int_ns c.duration in
  let book_ns = Time_ns.Span.to_int_ns c.book_every in
  let decide_ns = Time_ns.Span.to_int_ns c.decide_every in
  let hour_ns = Time_ns.Span.to_int_ns Time_ns.Span.hour in
  let events = Queue.create () in
  let fills = Queue.create () in
  let mid = ref c.start_px in
  let tid = ref 0 in
  (* the leader's book: position and average entry *)
  let pos = ref 0. in
  let entry = ref 0. in
  let next_decision = ref (start + Random.State.int rand decide_ns) in
  let at ns = Time_ns.of_int_ns_since_epoch ns in
  let now = ref start in
  while !now < stop do
    let t = !now in
    let step = c.step_bps /. 10_000. *. !mid in
    (mid := !mid +. if Random.State.bool rand then step else -.step);
    let best_bid = Float.round_down !mid in
    let best_ask = best_bid +. 1. in
    let level i side =
      let px = if side then best_bid -. Float.of_int i else best_ask +. Float.of_int i in
      { Market_data.L2_update.Level.price = price px
      ; size = size (c.level_size *. (0.5 +. Random.State.float rand 1.))
      }
    in
    Queue.enqueue
      events
      (Market_data.Event.L2
         { instrument
         ; exch_ts = at t
         ; recv_ts = at t
         ; kind = Snapshot
         ; bids = List.init 10 ~f:(fun i -> level i true)
         ; asks = List.init 10 ~f:(fun i -> level i false)
         });
    for k = 1 to c.trades_per_book do
      let ts = t + (book_ns * k / (c.trades_per_book + 1)) in
      let buy = Random.State.bool rand in
      incr tid;
      Queue.enqueue
        events
        (Market_data.Event.Trade
           { instrument
           ; exch_ts = at ts
           ; recv_ts = at ts
           ; price = price (if buy then best_ask else best_bid)
           ; size = size (Random.State.float rand (c.level_size /. 2.))
           ; side = (if buy then Buy else Sell)
           ; trade_id = Int.to_string !tid
           })
    done;
    if t / hour_ns <> (t + book_ns) / hour_ns
    then (
      let ts = (t + book_ns) / hour_ns * hour_ns in
      Queue.enqueue
        events
        (Market_data.Event.Funding
           { instrument
           ; exch_ts = at ts
           ; recv_ts = at ts
           ; rate = c.funding_rate
           ; next_funding_time = at (ts + hour_ns)
           ; mark_price = price !mid
           ; index_price = price !mid
           }));
    if t >= !next_decision
    then (
      next_decision := t + (decide_ns / 2) + Random.State.int rand decide_ns;
      let target =
        Float.round_decimal
          ((Random.State.float rand 2. -. 1.) *. c.max_position)
          ~decimal_digits:3
      in
      let delta = target -. !pos in
      if Float.(abs delta >= 0.001)
      then (
        let buy = Float.(delta > 0.) in
        let px = if buy then best_ask else best_bid in
        let q = Float.abs delta in
        (* realized pnl of the part that reduces the position *)
        let closing =
          if Float.(!pos *. delta < 0.)
          then Float.min q (Float.abs !pos)
          else 0.
        in
        let closed_pnl =
          closing *. (px -. !entry) *. if Float.(!pos > 0.) then 1. else -1.
        in
        let start_position = !pos in
        let new_pos = !pos +. delta in
        (if Float.(Float.abs new_pos < 1e-9)
         then entry := 0.
         else if Float.(closing < q)
         then
           (* grew the position, or flipped: new entry from the opening part *)
           if Float.(closing > 0.)
           then entry := px
           else
             entry := ((Float.abs !pos *. !entry) +. (q *. px)) /. Float.abs new_pos);
        pos := Float.round_decimal new_pos ~decimal_digits:5;
        incr tid;
        Queue.enqueue
          fills
          { Hl_protocol.User_fill.coin = Hl_protocol.Coin.of_string c.coin
          ; px = price px
          ; sz = size q
          ; side = (if buy then Buy else Sell)
          ; time = (t + 1) / 1_000_000
          ; start_position = size start_position
          ; dir = (if buy then "Buy" else "Sell")
          ; closed_pnl = (Hl_protocol.Usd.of_float [@alert "-lossy"]) (Float.round_decimal closed_pnl ~decimal_digits:6)
          ; hash = "0x"
          ; oid = Hl_protocol.Order_id.of_int !tid
          ; crossed = true
          ; fee =
              (Hl_protocol.Usd.of_float [@alert "-lossy"])
                (Float.round_decimal (q *. px *. 0.00045) ~decimal_digits:6)
          ; tid = !tid
          ; fee_token = Some "USDC"
          ; cloid = None
          }));
    now := t + book_ns
  done;
  { events = Queue.to_list events; fills = Queue.to_list fills; leader }
;;

let write ~dir t =
  let open Async in
  let%bind () = Unix.mkdir ~p:() dir in
  let w = Market_data.Event_log.Writer.create ~dir () in
  List.iter t.events ~f:(Market_data.Event_log.Writer.append w);
  let%bind () = Market_data.Event_log.Writer.close w in
  Writer.save (dir ^/ "leader-fills.ndjson") ~contents:(Leader_fills.to_ndjson t.fills)
;;
