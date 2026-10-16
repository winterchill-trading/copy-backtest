(** Statistics of backtest results from [backtest-stats]: one {!Backtest_stats.Report.t}
    per run, and one per sweep for the configuration a sweep would pick.

    The return series is the follower's curve: one simple return per sample (the curve's
    spacing, [Params.t.sample]), annualized with the number of samples in a year. The
    leader's curve over the same samples is the benchmark.

    - Per run: Sharpe ratios, PSR, drawdowns; in a sweep of two or more runs, the deflated
      Sharpe ratio counts every run of the sweep as a trial.
    - Per sweep: the run with the highest per-sample Sharpe ratio is the pick; its report
      has every run as a candidate, so it carries the probability of backtest overfitting
      (combinatorially symmetric cross-validation across the parameter grid), the reality
      check and the SPA p-values against the leader, and the DSR.

    Annualizing ten-second samples multiplies a per-sample Sharpe ratio by about 1,776:
    over a window of minutes or hours the annualized figures are large and say little;
    PSR, DSR, PBO and the SPA p-value are the numbers to read. *)

open! Core

module Row : sig
  type t =
    { scope : [ `Run | `Sweep ]
    ; run : int (** the run's index; for [`Sweep], the picked run *)
    ; label : string
    ; report : Backtest_stats.Report.t
    }
  [@@deriving sexp_of]

  (** ["accept"], ["reject"] or [None] without a policy. *)
  val verdict : t -> string option

  (** The rejection reasons, one line each ({!Backtest_stats.Gate.Reason.to_string_hum}). *)
  val reasons : t -> string list
end

(** Per-sample returns of the follower's curve (and of the leader's), from consecutive
    points with positive equity. *)
val returns : Backtest.t -> float array

val leader_returns : Backtest.t -> float array

(** One row per run (in order), then, with two or more runs, the sweep row. Runs whose
    curve has fewer than four points (three returns) get no row. [policy] gives single
    runs a verdict, and in a sweep only the sweep row. [bootstrap_samples] (default 1000)
    and [seed] (default 0) make the reports reproducible. *)
val rows
  :  ?policy:Backtest_stats.Gate.Policy.t
  -> ?bootstrap_samples:int
  -> ?seed:int
  -> sample:Time_ns.Span.t
  -> Backtest.t list
  -> Row.t list

(** Whether a policy rejected the decisive row: the run's for one run, the sweep's for
    several. *)
val rejected : Row.t list -> Row.t option
