(* Builds [perform] for an action definition. *)

module type S = sig
  val action : string

  type request [@@deriving yojson_of]
  type response [@@deriving of_yojson]
end

module type Write = sig
  val action : string

  type request [@@deriving yojson_of]
end

module Make (X : S) = struct
  let perform request =
    let body = X.yojson_of_request request |> Yojson.Safe.to_string in
    match Effect.perform (Effects.Call { action = X.action; body }) with
    | Ok json -> Ok (X.response_of_yojson json)
    | Error body -> Error (Error.of_body body)
end

module Make_write (X : Write) = struct
  type response = unit

  let response_of_yojson (_ : Yojson.Safe.t) = ()

  include Make (struct
    include X

    type nonrec response = response

    let response_of_yojson = response_of_yojson
  end)
end
