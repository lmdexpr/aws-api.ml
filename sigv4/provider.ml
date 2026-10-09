(* A provider yields the raw credential fields ([Ok]) or a decline reason ([Error]).
   It never builds a [Sigv4.Credentials.t]; [Sigv4] does the wrapping. *)

type raw = access_key:string * secret_key:string * session_token:string option
type t = { name : string option; run : unit -> (raw, string) result }

let v ?name run = { name; run }

let label name reason =
  match name with Some n -> Printf.sprintf "[%s] %s" n reason | None -> reason

let run p = p.run () |> Result.map_error (label p.name)

let chain providers =
  v @@ fun () ->
  let rec go acc = function
    | [] -> (
      Result.error
      @@
      match List.rev acc with
      | [] -> "empty provider chain"
      | reasons -> "no provider resolved credentials: " ^ String.concat "; " reasons)
    | p :: rest ->
      p.run () |> Result.fold ~ok:Result.ok ~error:(fun r -> go (label p.name r :: acc) rest)
  in
  go [] providers

module Http = struct
  type request = { meth : [ `GET | `PUT ]; url : string; headers : (string * string) list }
  type response = { status : int; body : string }
end

module Static = struct
  let make ~access_key ~secret_key ?session_token () =
    v ~name:"static" @@ fun () -> Result.ok (~access_key, ~secret_key, ~session_token)
end

module Env = struct
  let var_access_key = "AWS_ACCESS_KEY_ID"
  let var_secret_key = "AWS_SECRET_ACCESS_KEY"
  let var_session_token = "AWS_SESSION_TOKEN"

  let make ?(getenv = Sys.getenv_opt) () =
    let resolved =
      match getenv var_access_key, getenv var_secret_key with
      | Some access_key, Some secret_key ->
        Result.ok (~access_key, ~secret_key, ~session_token:(getenv var_session_token))
      | _ ->
        Result.error @@ Printf.sprintf "%s and %s must both be set" var_access_key var_secret_key
    in
    v ~name:"env" @@ fun () -> resolved
end

let read_file_from_disk path =
  if Sys.file_exists path then
    Some (In_channel.with_open_bin path In_channel.input_all)
  else
    None

module Profile = struct
  (* Comments start with # or ; at the beginning of a line. Continuation lines and nested blocks
     (e.g. s3 =) are not needed for static keys and are ignored. Section names are kept verbatim:
     the config file distinguishes [profile x] from [x]. *)
  let parse text =
    let add_section sections current =
      match current with Some (name, kvs) -> (name, List.rev kvs) :: sections | None -> sections
    in
    let step (sections, current) line =
      let line = String.trim line in
      if line = "" || String.starts_with ~prefix:"#" line || String.starts_with ~prefix:";" line
      then
        sections, current
      else if String.starts_with ~prefix:"[" line && String.ends_with ~suffix:"]" line then
        ( add_section sections current,
          Some (String.trim (String.drop_last 1 (String.drop_first 1 line)), []) )
      else
        match
          String.split_first ~sep:"=" line, current
        with
        | Some (key, value), Some (name, kvs) ->
          sections, Some (name, (String.trim key, String.trim value) :: kvs)
        | _ -> sections, current
    in
    let sections, current = List.fold_left step ([], None) (String.split_on_char '\n' text) in
    List.rev (add_section sections current)

  let credentials_of section =
    match
      List.assoc_opt "aws_access_key_id" section, List.assoc_opt "aws_secret_access_key" section
    with
    | Some access_key, Some secret_key ->
      Some (~access_key, ~secret_key, ~session_token:(List.assoc_opt "aws_session_token" section))
    | _ -> None

  (* The credentials file names profiles bare; the config file as [profile <name>], except
     [default]. *)
  let section_names ~profile = function
    | `Credentials -> [ profile ]
    | `Config ->
      if profile = "default" then [ "default"; "profile default" ] else [ "profile " ^ profile ]

  let make ?(getenv = Sys.getenv_opt) ~read_file () =
    v ~name:"profile" @@ fun () ->
    let profile = Option.value (getenv "AWS_PROFILE") ~default:"default" in
    let path var default =
      match getenv var, getenv "HOME" with
      | Some p, _ -> Some p
      | None, Some home -> Some (Filename.concat (Filename.concat home ".aws") default)
      | None, None -> None
    in
    let lookup kind var default =
      let names = section_names ~profile kind in
      Option.bind (path var default) read_file
      |> Option.map parse |> Option.to_list
      |> List.concat_map (List.filter (fun (name, _) -> List.mem name names))
      |> List.find_map (fun (_, section) -> credentials_of section)
    in
    [
      (fun () -> lookup `Credentials "AWS_SHARED_CREDENTIALS_FILE" "credentials");
      (fun () -> lookup `Config "AWS_CONFIG_FILE" "config");
    ]
    |> List.find_map (fun f -> f ())
    |> Option.to_result ~none:(Printf.sprintf "no static keys for profile %S" profile)
end

(* Shared by the HTTP providers: the JSON credential document and the expiry cache. *)
module Fetched = struct
  (* Refresh this many seconds before the reported expiry. *)
  let refresh_margin = 300.

  (* Documents without [Expiration] are kept this long, as the AWS SDKs do. *)
  let default_ttl = 15. *. 60.

  (* "YYYY-MM-DDThh:mm:ss[.fff]Z" -> Unix-epoch seconds; None on any other shape. *)
  let epoch_of_iso8601 s =
    match
      Scanf.sscanf s "%4d-%2d-%2dT%2d:%2d:%2d%_[.0-9]Z%!" (fun y m d hh mm ss ->
        if
          m < 1 || m > 12 || d < 1 || d > 31 || hh < 0 || hh > 23 || mm < 0 || mm > 59 || ss < 0
          || ss > 60
        then
          None
        else
          let y = if m <= 2 then y - 1 else y in
          let era = (if y >= 0 then y else y - 399) / 400 in
          let yoe = y - (era * 400) in
          let doy = (((153 * (m + if m > 2 then -3 else 9)) + 2) / 5) + d - 1 in
          let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
          let days = (era * 146097) + doe - 719468 in
          Some (float_of_int ((days * 86400) + (hh * 3600) + (mm * 60) + ss)))
    with
    | result -> result
    | exception (Scanf.Scan_failure _ | End_of_file | Failure _) -> None

  (* Never raises, and never puts document contents in the error: the document holds secrets. *)
  let parse body =
    match Yojson.Safe.from_string body with
    | exception Yojson.Json_error _ -> Error "credential document is not JSON"
    | `Assoc fields -> (
      let field name =
        match List.assoc_opt name fields with Some (`String s) -> Some s | _ -> None
      in
      match field "AccessKeyId", field "SecretAccessKey" with
      | Some access_key, Some secret_key ->
        let session_token = field "Token" in
        Ok
          ( (~access_key, ~secret_key, ~session_token),
            Option.bind (field "Expiration") epoch_of_iso8601 )
      | _ -> Error "credential document lacks AccessKeyId or SecretAccessKey")
    | _ -> Error "credential document is not a JSON object"

  (* The cache is a private ref captured per provider, so build the provider once and reuse it.
     Credentials are refreshed [refresh_margin] before expiry; if the refresh fails they are still
     served until they actually expire. [fetch] returns the document body or a decline reason;
     its exceptions become declines too. *)
  let cached ~name ~now ~(fetch : unit -> (string, string) result) =
    let cache = ref None in
    v ~name @@ fun () ->
    let t = now () in
    match !cache with
    | Some (creds, expiry) when t +. refresh_margin < expiry -> Ok creds
    | stale -> (
      let fetched =
        match fetch () with
        | Ok body -> parse body
        | Error reason -> Error reason
        | exception exn -> Error (Printexc.to_string exn)
      in
      match fetched, stale with
      | Ok (creds, expiry), _ ->
        cache := Some (creds, Option.value expiry ~default:(t +. default_ttl));
        Ok creds
      | Error _, Some (creds, expiry) when t < expiry -> Ok creds
      | Error reason, _ -> Error reason)

  (* Decline reasons travel in exceptions and error reports: keep the URL's query and most of the
     body out of them. *)
  let describe url status body =
    let url = match String.split_first ~sep:"?" url with Some (u, _) -> u | None -> url in
    let body = if String.length body > 120 then String.take_first 120 body ^ "..." else body in
    Printf.sprintf "%s answered %d: %s" url status body

  let get ~(http : Http.request -> Http.response) ?(headers = []) url =
    match http { meth = `GET; url; headers } with
    | { status; body } when status >= 200 && status < 300 -> Ok body
    | { status; body } -> Error (describe url status body)
end

module Ecs = struct
  let ecs_endpoint_host = "169.254.170.2"

  (* RELATIVE_URI (joined with the link-local host) takes precedence over FULL_URI. *)
  let endpoint_url ~getenv =
    match getenv "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI" with
    | Some path -> Some (Printf.sprintf "http://%s%s" ecs_endpoint_host path)
    | None -> getenv "AWS_CONTAINER_CREDENTIALS_FULL_URI"

  (* As the AWS SDKs: plain HTTP only to loopback or the ECS / EKS link-local agents, so an
     environment variable cannot redirect the credential fetch to an arbitrary host. *)
  let allowed_http_hosts =
    [ "localhost"; "::1"; ecs_endpoint_host; "169.254.170.23"; "fd00:ec2::23" ]

  (* 127.0.0.0/8 as four decimal octets; a string prefix would let 127.evil.example through. *)
  let is_ipv4_loopback host =
    match String.split_on_char '.' host with
    | [ "127"; b; c; d ] ->
      List.for_all
        (fun o ->
          o <> ""
          && String.for_all Char.Ascii.is_digit o
          && String.length o <= 3
          && int_of_string o <= 255)
        [ b; c; d ]
    | _ -> false

  let allowed url =
    let uri = Uri.of_string url in
    match Uri.scheme uri, Uri.host uri with
    | Some "https", Some _ -> true
    | Some "http", Some host -> List.mem host allowed_http_hosts || is_ipv4_loopback host
    | _ -> false

  (* As the SDKs: the token file takes precedence, and an unreadable file is an error rather than
     an unauthenticated request. *)
  let authorization ~getenv ~read_file =
    let token =
      match getenv "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE" with
      | Some path -> (
        match read_file path with
        | Some token -> Ok (Some token)
        | None -> Error "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE cannot be read")
      | None -> Ok (getenv "AWS_CONTAINER_AUTHORIZATION_TOKEN")
    in
    (* A token file ends with a newline; a line break inside the token would inject a header. *)
    match Result.map (Option.map String.trim) token with
    | Error reason -> Error reason
    | Ok None -> Ok []
    | Ok (Some token) when String.contains token '\r' || String.contains token '\n' ->
      Error "AWS_CONTAINER_AUTHORIZATION_TOKEN contains a line break"
    | Ok (Some token) -> Ok [ "Authorization", token ]

  let make ?(getenv = Sys.getenv_opt) ?(read_file = read_file_from_disk) ~now ~http () =
    Fetched.cached ~name:"ecs" ~now ~fetch:(fun () ->
      match endpoint_url ~getenv with
      | None -> Error "no AWS_CONTAINER_CREDENTIALS_* variable set"
      | Some url when not (allowed url) ->
        Error
          "AWS_CONTAINER_CREDENTIALS_FULL_URI must be https, or http to a loopback or link-local \
           host"
      | Some url ->
        Result.bind (authorization ~getenv ~read_file) (fun headers ->
          Fetched.get ~http ~headers url))
end

module Imds = struct
  let default_endpoint = "http://169.254.169.254"
  let token_ttl_seconds = "21600"

  let endpoint ~getenv =
    Option.value (getenv "AWS_EC2_METADATA_SERVICE_ENDPOINT") ~default:default_endpoint

  let disabled ~getenv =
    match getenv "AWS_EC2_METADATA_DISABLED" with
    | Some v -> String.lowercase_ascii v = "true"
    | None -> false

  (* IMDSv2: a session token from PUT /latest/api/token authenticates the metadata reads. *)
  let fetch ~getenv ~(http : Http.request -> Http.response) () =
    let open Result.Syntax in
    if disabled ~getenv then
      Error "AWS_EC2_METADATA_DISABLED is true"
    else
      let base = endpoint ~getenv in
      let* token =
        match
          http
            {
              meth = `PUT;
              url = base ^ "/latest/api/token";
              headers = [ "X-aws-ec2-metadata-token-ttl-seconds", token_ttl_seconds ];
            }
        with
        | { status; body } when status >= 200 && status < 300 -> Ok body
        | { status; _ } -> Error (Printf.sprintf "token request answered %d" status)
      in
      let headers = [ "X-aws-ec2-metadata-token", token ] in
      let path = base ^ "/latest/meta-data/iam/security-credentials/" in
      let* role = Fetched.get ~http ~headers path in
      let role = String.trim role in
      if role = "" then Error "no IAM role attached" else Fetched.get ~http ~headers (path ^ role)

  let make ?(getenv = Sys.getenv_opt) ~now ~http () =
    Fetched.cached ~name:"imds" ~now ~fetch:(fetch ~getenv ~http)
end

let default ?(getenv = Sys.getenv_opt) ?(read_file = read_file_from_disk) ~now ~http () =
  chain
    [
      Env.make ~getenv ();
      Profile.make ~getenv ~read_file ();
      Ecs.make ~getenv ~read_file ~now ~http ();
      Imds.make ~getenv ~now ~http ();
    ]
