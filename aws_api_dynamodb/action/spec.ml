(* Builds [perform] for an action definition. *)

module type S = Aws_json_transport.Operation

module type Write = sig
  val action : string

  type request [@@deriving yojson_of]
end

module Make (X : S) = Aws_json_transport.Make (X)

module Make_write (X : Write) = struct
  type response = unit

  let response_of_yojson (_ : Yojson.Safe.t) = ()

  include Make (struct
    include X

    type nonrec response = response

    let response_of_yojson = response_of_yojson
  end)
end
