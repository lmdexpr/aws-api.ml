open Ppx_yojson_conv_lib.Yojson_conv.Primitives

(* [code] is the service's exception name, or one of the [*_code] constants below for failures
   that are not a 4xx service error. [body] is the raw response body, empty when it could carry
   secrets (see [deserialization]). *)
type t = { code : string; message : string option; body : string }

module Body = struct
  (* Service errors use "message"; the shared auth layer uses "Message". *)
  type t = {
    type_ : string; [@key "__type"]
    message : string option; [@key "message"] [@yojson.option]
    message_ : string option; [@key "Message"] [@yojson.option]
  }
  [@@deriving of_yojson] [@@yojson.allow_extra_fields]
end

(* [__type] is [<namespace>#<code>] or just [<code>]. *)
let code_of_type type_ =
  match String.split_last ~sep:"#" type_ with Some (_, code) -> code | None -> type_

let of_body body =
  match Yojson.Safe.from_string body |> Body.t_of_yojson with
  | Body.{ type_; message; message_ } ->
    {
      code = code_of_type type_;
      message = (match message with Some _ -> message | None -> message_);
      body;
    }
  | exception (Yojson.Json_error _ | Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error _) ->
    { code = ""; message = None; body }

(* Any status outside 2xx and 4xx: redirects, throttling pages from proxies, 5xx. *)
let http_status_code = "HttpStatus"

let http_status ~status ~body =
  { code = http_status_code; message = Some (Printf.sprintf "status %d" status); body }

(* A 2xx body the generated types could not read. The body is dropped: responses carry
   secrets (SSM SecureString values, ...), and [Of_yojson_error] holds the whole value. *)
let deserialization_code = "Deserialization"

let deserialization exn =
  let message =
    match exn with
    | Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error (Failure msg, _) -> msg
    | Yojson.Json_error msg -> msg
    | exn -> Printexc.to_string exn
  in
  { code = deserialization_code; message = Some message; body = "" }

let is_http_status { code; _ } = String.equal code http_status_code
let is_deserialization { code; _ } = String.equal code deserialization_code

(* Bodies are unbounded (proxy HTML pages, ...); keep log lines bounded. *)
let body_preview_bytes = 256

let to_string { code; message; body } =
  let body =
    if String.length body <= body_preview_bytes then
      body
    else
      String.sub body 0 body_preview_bytes ^ "..."
  in
  match code, message with
  | "", _ -> body
  | code, Some message -> code ^ ": " ^ message
  | code, None -> code
