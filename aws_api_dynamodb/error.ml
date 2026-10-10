open Ppx_yojson_conv_lib.Yojson_conv.Primitives
include Aws_json_error

module Body = struct
  type cancellation_reason = { code : string [@key "Code"] }
  [@@deriving of_yojson] [@@yojson.allow_extra_fields]

  type t = {
    cancellation_reasons : cancellation_reason list; [@key "CancellationReasons"] [@default []]
  }
  [@@deriving of_yojson] [@@yojson.allow_extra_fields]
end

(* [TransactionCanceledException] lists one reason per transact item. *)
let cancellation_reasons { body; _ } =
  match Yojson.Safe.from_string body |> Body.t_of_yojson with
  | Body.{ cancellation_reasons } -> List.map (fun Body.{ code } -> code) cancellation_reasons
  | exception (Yojson.Json_error _ | Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error _) -> []

let too_many_pages_code = "TooManyPages"

let too_many_pages ~max_pages =
  {
    code = too_many_pages_code;
    message = Some (Printf.sprintf "stopped after %d pages" max_pages);
    body = "";
  }

let is_too_many_pages { code; _ } = String.equal code too_many_pages_code

let is_conditional_check_failed ({ code; _ } as e) =
  String.equal code "ConditionalCheckFailedException"
  || String.equal code "TransactionCanceledException"
     && List.exists (String.equal "ConditionalCheckFailed") (cancellation_reasons e)
