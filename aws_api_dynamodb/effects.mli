(** Effects performed by the library. *)

type _ Effect.t +=
  | Call : { action : string; body : string } -> (Yojson.Safe.t, string) result Effect.t
      (** One per operation. [action] is e.g. ["PutItem"], [body] the JSON request. [Ok]: decoded
          2xx body. [Error]: raw 4xx body. *)
