type _ Effect.t +=
  | Call : { action : string; body : string } -> (Yojson.Safe.t, string) result Effect.t
