module Error = Error
module Response = Response
module Invocation = Invocation
module Context = Context
module Request = Request
module Transport = Transport

let api_version = Request.api_version

type handler = Invocation.t -> (string, Error.t) result

type fatal =
  | Container_error
  | Malformed_invocation of Invocation.parse_error
  | Unexpected_status of { request : Request.t; status : int }

let fatal_to_string = function
  | Container_error -> "Runtime API answered 500: the execution environment is unrecoverable"
  | Malformed_invocation e -> "malformed /next response: " ^ Invocation.parse_error_to_string e
  | Unexpected_status { request; status } ->
    Printf.sprintf "%s %s: unexpected status %d"
      (Aws_api.Http.string_of_meth (request.meth :> Aws_api.Http.meth))
      request.path status

let next () =
  let response = Transport.call Request.next in
  match response.status with
  | 200 -> Invocation.of_response response |> Result.map_error (fun e -> Malformed_invocation e)
  | 500 -> Error Container_error
  | status -> Error (Unexpected_status { request = Request.next; status })

let post request =
  match (Transport.call request).status with
  | 202 -> Ok ()
  | 500 -> Error Container_error
  | status -> Error (Unexpected_status { request; status })

let respond invocation = function
  | Ok payload -> post (Request.response invocation payload)
  | Error error -> post (Request.error invocation error)

let report_init_error error = post (Request.init_error error)

let step ?(propagate = fun _ -> false) (handler : handler) =
  let open Result.Syntax in
  let* invocation = next () in
  let outcome =
    match handler invocation with
    | outcome -> outcome
    | exception exn when propagate exn -> raise exn
    | exception exn -> Error (Error.of_exn ~backtrace:(Printexc.get_raw_backtrace ()) exn)
  in
  respond invocation outcome

let rec run ?propagate handler =
  match step ?propagate handler with Ok () -> run ?propagate handler | Error fatal -> fatal

module Http = struct
  let endpoint_from_env () = Sys.getenv_opt "AWS_LAMBDA_RUNTIME_API"

  let perform ~endpoint (request : Request.t) : Response.t =
    let response =
      Aws_api.Http.call
        {
          meth = (request.meth :> Aws_api.Http.meth);
          uri = Uri.of_string (Request.url ~endpoint request);
          headers = request.headers;
          body = request.body;
        }
    in
    { status = response.status; headers = response.headers; body = response.body }

  let handle ~endpoint k =
    let open Effect.Deep in
    try k ()
    with effect Transport.Call request, k -> (
      match perform ~endpoint request with
      | response -> continue k response
      | exception exn -> discontinue k exn)

  let export_trace_id (handler : handler) (invocation : Invocation.t) =
    Option.iter (Unix.putenv "_X_AMZN_TRACE_ID") invocation.trace_id;
    handler invocation

  let run ?propagate ~endpoint handler =
    handle ~endpoint @@ fun () -> run ?propagate (export_trace_id handler)
end
