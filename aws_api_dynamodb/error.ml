open Ppx_yojson_conv_lib.Yojson_conv.Primitives

type t = {
  code : string;
  message : string option;
  cancellation_reasons : string list;
  body : string;
}

module Body = struct
  type cancellation_reason = { code : string [@key "Code"] }
  [@@deriving of_yojson] [@@yojson.allow_extra_fields]

  (* Service errors use "message"; the shared auth layer (AccessDeniedException,
     UnrecognizedClientException, ExpiredTokenException) uses "Message". *)
  type t = {
    type_ : string; [@key "__type"]
    message : string option; [@key "message"] [@yojson.option]
    message_ : string option; [@key "Message"] [@yojson.option]
    cancellation_reasons : cancellation_reason list; [@key "CancellationReasons"] [@default []]
  }
  [@@deriving of_yojson] [@@yojson.allow_extra_fields]
end

(* [__type] is [<namespace>#<code>]. *)
let code_of_type type_ =
  match String.split_last ~sep:"#" type_ with Some (_, code) -> code | None -> type_

let of_body body =
  match Yojson.Safe.from_string body |> Body.t_of_yojson with
  | Body.{ type_; message; message_; cancellation_reasons } ->
    {
      code = code_of_type type_;
      message = (match message with Some _ -> message | None -> message_);
      cancellation_reasons = List.map (fun Body.{ code } -> code) cancellation_reasons;
      body;
    }
  | exception (Yojson.Json_error _ | Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error _) ->
    { code = ""; message = None; cancellation_reasons = []; body }

let too_many_pages_code = "TooManyPages"

let too_many_pages ~max_pages =
  {
    code = too_many_pages_code;
    message = Some (Printf.sprintf "stopped after %d pages" max_pages);
    cancellation_reasons = [];
    body = "";
  }

let is_too_many_pages { code; _ } = String.equal code too_many_pages_code

let is_conditional_check_failed { code; cancellation_reasons; _ } =
  String.equal code "ConditionalCheckFailedException"
  || String.equal code "TransactionCanceledException"
     && List.exists (String.equal "ConditionalCheckFailed") cancellation_reasons

let to_string { code; message; body; _ } =
  match code, message with
  | "", _ -> body
  | code, Some message -> code ^ ": " ^ message
  | code, None -> code
