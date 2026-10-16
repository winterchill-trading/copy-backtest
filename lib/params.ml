open! Core
open Hl_copy_core

type t =
  { follow : Follower_config.t
  ; start_equity : float
  ; leader_equity : float
  ; copy_delay : Time_ns.Span.t
  ; latency : Time_ns.Span.t
  ; resync : Time_ns.Span.t
  ; tick : Time_ns.Span.t
  ; sample : Time_ns.Span.t
  ; taker_fee_bps : float
  ; maker_fee_bps : float
  ; funding : bool
  ; specs : Specs.t
  }
[@@deriving sexp_of]

let create
  ?(start_equity = 10_000.)
  ?(leader_equity = 1_000_000.)
  ?(copy_delay = Time_ns.Span.of_int_ms 200)
  ?(latency = Time_ns.Span.of_int_ms 50)
  ?(resync = Time_ns.Span.of_int_sec 30)
  ?(tick = Time_ns.Span.of_int_ms 500)
  ?(sample = Time_ns.Span.of_int_sec 10)
  ?(taker_fee_bps = 4.5)
  ?(maker_fee_bps = 1.5)
  ?(funding = true)
  ~follow
  ~specs
  ()
  =
  { follow
  ; start_equity
  ; leader_equity
  ; copy_delay
  ; latency
  ; resync
  ; tick
  ; sample
  ; taker_fee_bps
  ; maker_fee_bps
  ; funding
  ; specs
  }
;;

let mode_label : Scale.Mode.t -> string = function
  | Equity_ratio -> "equity"
  | Multiplier k -> sprintf "mult:%g" k
  | Fixed_notional n -> sprintf "fixed:%s" (Usd.to_string n)
;;

(* [band:ra20] for the default shape with risk aversion 20; quadratic bands add the
   impact, an [Impact] slippage an [i]. *)
let band_label (b : No_trade_band.t) =
  sprintf
    "band:ra%g%s%s"
    b.risk_aversion
    (match b.cost_model with
     | Proportional -> ""
     | Quadratic { impact } -> sprintf ":q%g" impact)
    (match b.slippage with
     | Fixed_bps _ -> ""
     | Impact _ -> ":i")
;;

let label t =
  let caps = t.follow.caps in
  String.concat
    ~sep:" "
    (List.filter_opt
       [ Some (Execution_algos.Algo.to_string (Copy_algo.to_algo t.follow.algo))
       ; Some (mode_label t.follow.mode)
       ; Option.map caps.max_leverage ~f:(sprintf "lev<=%g")
       ; Option.map caps.max_notional_per_symbol ~f:(fun n ->
           sprintf "notional<=%s" (Usd.to_string n))
       ; Option.map caps.max_daily_loss ~f:(fun n -> sprintf "loss<=%s" (Usd.to_string n))
       ; Option.map t.follow.band ~f:band_label
       ])
;;
