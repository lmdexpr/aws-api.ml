(** Conversion between values and ordinary JSON, distinct from the wire format. JSON does not carry
    set or binary tags, and floats do not carry decimal precision. *)

type error = { path : string; message : string }

exception Conversion_error of error

val error_to_string : error -> string

type numbers = [ `Exact | `Float | `String ]
(** Integers become [Int] / [Intlit] under [Exact] and [Float] (default). Fractions become floats
    under [Float], are rejected under [Exact]. [String]: every number becomes its decimal string,
    which imports back as [S]. *)

type sets = [ `Reject | `Lists ]
type binary = [ `Reject | `Base64 ]

val value_of_yojson : Yojson.Safe.t -> (Value.t, error) result
val value_of_yojson_exn : Yojson.Safe.t -> Value.t
val item_of_yojson : Yojson.Safe.t -> (Item.t, error) result

val item_of_yojson_exn : Yojson.Safe.t -> Item.t
(** Objects become maps, arrays become lists and strings become strings, even if they look like
    DynamoDB envelopes. Invalid numbers and duplicate names are rejected. Float input retains its
    float precision, not arbitrary decimals. *)

val yojson_of_value :
  ?numbers:numbers -> ?sets:sets -> ?binary:binary -> Value.t -> (Yojson.Safe.t, error) result

val yojson_of_value_exn :
  ?numbers:numbers -> ?sets:sets -> ?binary:binary -> Value.t -> Yojson.Safe.t

val yojson_of_item :
  ?numbers:numbers -> ?sets:sets -> ?binary:binary -> Item.t -> (Yojson.Safe.t, error) result

val yojson_of_item_exn : ?numbers:numbers -> ?sets:sets -> ?binary:binary -> Item.t -> Yojson.Safe.t
(** Sets and binary are rejected by default. [_exn] functions raise [Conversion_error]; result
    functions report the same attribute path. *)
