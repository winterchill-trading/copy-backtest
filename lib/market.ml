open! Core
module Book = Execution_algos.Book

type t =
  { mutable l2 : Market_data.L2_book.t
  ; mutable has_l2 : bool
  ; mutable book : Book.t
  ; mutable traded : Market_data.Size.t
  ; mutable last_trade : Market_data.Price.t option
  ; mutable funding_rate : float option
  }

let create () =
  { l2 = Market_data.L2_book.empty
  ; has_l2 = false
  ; book = Book.empty
  ; traded = Market_data.Size.zero
  ; last_trade = None
  ; funding_rate = None
  }
;;

let apply t (e : Market_data.Event.t) =
  match e with
  | L2 u ->
    t.l2 <- Market_data.L2_book.apply t.l2 u;
    t.has_l2 <- true;
    if Market_data.L2_book.has_snapshot t.l2 then t.book <- Book.of_l2_book t.l2
  | Bbo b -> if not t.has_l2 then t.book <- Book.of_bbo b
  | Trade tr ->
    t.traded <- Market_data.Size.( + ) t.traded tr.size;
    t.last_trade <- Some tr.price
  | Funding f -> t.funding_rate <- Some f.rate
;;

let book t = t.book
let traded t = t.traded

let mark t =
  match Book.mid t.book with
  | This m -> Some m
  | Null -> t.last_trade
;;

let funding_rate t = t.funding_rate
