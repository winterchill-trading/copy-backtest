(** The follow's algorithm ({!Hl_copy_core.Exec_algo}) as the scheduler's
    [Execution_algos.Algo.t]: the same constructors and fields. *)

open! Core

val to_algo : Hl_copy_core.Exec_algo.t -> Execution_algos.Algo.t
val of_algo : Execution_algos.Algo.t -> Hl_copy_core.Exec_algo.t
