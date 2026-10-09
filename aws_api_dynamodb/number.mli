type t
(** Exact decimals: up to 38 significant digits, adjusted exponent -130 to 125, or zero. No
    floating-point conversion on the wire. *)

val of_string : string -> (t, string) result
(** Decimal notation with optional sign, fraction and exponent. Normalizes insignificant zeroes;
    rejects non-decimal and out-of-range input. *)

val of_string_exn : string -> t
(** Raises [Invalid_argument] on invalid input. *)

val to_string : t -> string
val of_int : int -> t

val to_integer_string : t -> (string, string) result
(** Exact integer notation, or an error for a fractional number. *)

val to_int : t -> (int, string) result

val of_float : float -> (t, string) result
(** Round-trippable decimal representation. Rejects non-finite and out-of-range values. *)

val to_float : t -> float
(** May round. Use [to_string] to retain decimal precision. *)

val equal : t -> t -> bool

val compare : t -> t -> int
(** Exact numerical ordering, without conversion to float. *)
