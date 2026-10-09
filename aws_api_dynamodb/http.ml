let signed_headers ~now ~region ~uri ~action ~body =
  let base =
    [ "Content-Type", "application/x-amz-json-1.0"; "X-Amz-Target", "DynamoDB_20120810." ^ action ]
  in
  let credentials = Sigv4.Credentials.fetch () in
  let signed =
    Sigv4.sign ~now ~credentials ~region ~service:"dynamodb" ~http_method:"POST" ~payload:body ~uri
      base
  in
  base @ signed

let handle ~now ~config:Config.{ endpoint; region } k =
  let uri = if Uri.path endpoint = "" then Uri.with_path endpoint "/" else endpoint in
  try k ()
  with effect Effects.Call { action; body }, k -> (
    (* Exceptions go to the perform site via [discontinue], not out of the handler frame. *)
    match
      let headers = signed_headers ~now ~region ~uri ~action ~body in
      let response = Aws_api.Http.call { meth = `POST; uri; headers; body = Some body } in
      match response.status with
      | status when status < 300 -> Ok (Yojson.Safe.from_string response.body)
      | status when status < 500 -> Error response.body
      | status ->
        failwith @@ Printf.sprintf "DynamoDB request failed with status %d: %s" status response.body
    with
    | response -> Effect.Deep.continue k response
    | exception exn -> Effect.Deep.discontinue k exn)

(* Credential fetches (ECS, IMDS) go through the same HTTP effect as the API calls. *)
let http ({ meth; url; headers } : Sigv4.Provider.Http.request) : Sigv4.Provider.Http.response =
  let response =
    Aws_api.Http.call { meth :> Aws_api.Http.meth; uri = Uri.of_string url; headers; body = None }
  in
  { status = response.status; body = response.body }

let default_provider ?getenv ?read_file ~now () =
  Sigv4.Provider.default ?getenv ?read_file ~now ~http ()

let run ?provider ~now ~config k =
  let provider = match provider with Some p -> p | None -> default_provider ~now () in
  Sigv4.with_provider provider @@ fun () -> handle ~now ~config k
