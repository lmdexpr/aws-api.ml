(* Signed POST of one AWS JSON 1.0 / 1.1 operation through [Aws_api.Http]. Copied into each
   generated service package by [copy_files]; no effects of its own. *)

type version = Json_1_0 | Json_1_1

(* What the service's Smithy model says about its protocol binding. *)
type protocol = {
  version : version;
  (* [X-Amz-Target] is [target_prefix.Operation]: the service shape name. *)
  target_prefix : string;
  (* [aws.auth#sigv4] name. *)
  signing_name : string;
  (* [aws.api#service] endpointPrefix. *)
  endpoint_prefix : string;
}

type t = {
  protocol : protocol;
  region : string;
  endpoint : Uri.t;
  now : unit -> float;
  credentials : unit -> Sigv4.Credentials.t;
}

(* Credential fetches (ECS, IMDS) go through the same HTTP effect as the API calls. *)
let http ({ meth; url; headers } : Sigv4.Provider.Http.request) : Sigv4.Provider.Http.response =
  let response =
    Aws_api.Http.call { meth :> Aws_api.Http.meth; uri = Uri.of_string url; headers; body = None }
  in
  { status = response.status; body = response.body }

(* [Sigv4.Credentials.t] is abstract and only obtainable through its own effect, so that effect
   is handled right here rather than by the caller. Raises [Sigv4.No_credentials]. *)
let credentials_of_provider provider () : Sigv4.Credentials.t =
  Sigv4.with_provider provider Sigv4.Credentials.fetch

(* [region] becomes part of the host name, so anything but [a-z0-9-] would redirect the signed
   request (and its credentials) elsewhere. *)
let check_region region =
  let ok = function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false in
  if region = "" || not (String.for_all ok region) then
    invalid_arg (Printf.sprintf "Transport.make: invalid region %S" region)

(* [provider] defaults to the SDK chain (env, profile, ECS, IMDS); it caches, so build [t] once.
   Raises [Invalid_argument] on a malformed [region]. *)
let make ?endpoint ?provider ~protocol ~region ~now () =
  check_region region;
  let endpoint =
    match endpoint with
    | Some uri -> if Uri.path uri = "" then Uri.with_path uri "/" else uri
    | None ->
      Uri.of_string (Printf.sprintf "https://%s.%s.amazonaws.com/" protocol.endpoint_prefix region)
  in
  let provider = match provider with Some p -> p | None -> Sigv4.Provider.default ~now ~http () in
  { protocol; region; endpoint; now; credentials = credentials_of_provider provider }

let content_type = function
  | Json_1_0 -> "application/x-amz-json-1.0"
  | Json_1_1 -> "application/x-amz-json-1.1"

let call { protocol; region; endpoint = uri; now; credentials } ~action ~body =
  let base =
    [
      "Content-Type", content_type protocol.version;
      "X-Amz-Target", protocol.target_prefix ^ "." ^ action;
    ]
  in
  let signed =
    Sigv4.sign ~now ~credentials:(credentials ()) ~region ~service:protocol.signing_name
      ~http_method:"POST" ~payload:body ~uri base
  in
  let response =
    Aws_api.Http.call { meth = `POST; uri; headers = base @ signed; body = Some body }
  in
  match response.status with
  | status when status >= 200 && status < 300 -> Ok response.body
  | status when status >= 400 && status < 500 -> Error (Error.of_body response.body)
  | status -> Error (Error.http_status ~status ~body:response.body)

(* Decoding failures never escape with the body attached; see [Error.deserialization]. *)
let decode of_yojson body =
  match Yojson.Safe.from_string body |> of_yojson with
  | response -> Ok response
  | exception ((Yojson.Json_error _ | Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error _) as exn) ->
    Error (Error.deserialization exn)

(* Builds [perform] for one operation. *)
module type Operation = sig
  val action : string

  type request [@@deriving yojson_of]
  type response [@@deriving of_yojson]
end

module Make (X : Operation) = struct
  let perform t request =
    let body = X.yojson_of_request request |> Yojson.Safe.to_string in
    Result.bind (call t ~action:X.action ~body) (decode X.response_of_yojson)
end
