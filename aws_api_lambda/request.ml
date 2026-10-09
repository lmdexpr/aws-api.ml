let api_version = "2018-06-01"

type meth = [ `GET | `POST ]
type t = { meth : meth; path : string; headers : (string * string) list; body : string option }

let function_error_type_header = "Lambda-Runtime-Function-Error-Type"
let next = { meth = `GET; path = "/runtime/invocation/next"; headers = []; body = None }

let echo_invocation_id (invocation : Invocation.t) =
  invocation.invocation_id
  |> Option.map (fun id -> Invocation.invocation_id_header, id)
  |> Option.to_list

let response (invocation : Invocation.t) payload =
  {
    meth = `POST;
    path = Printf.sprintf "/runtime/invocation/%s/response" invocation.request_id;
    headers = echo_invocation_id invocation;
    body = Some payload;
  }

let error (invocation : Invocation.t) (error : Error.t) =
  {
    meth = `POST;
    path = Printf.sprintf "/runtime/invocation/%s/error" invocation.request_id;
    headers =
      (function_error_type_header, Error.sanitize_error_type error.error_type)
      :: echo_invocation_id invocation;
    body = Some (Error.to_json error);
  }

let init_error (error : Error.t) =
  {
    meth = `POST;
    path = "/runtime/init/error";
    headers = [ function_error_type_header, Error.sanitize_error_type error.error_type ];
    body = Some (Error.to_json error);
  }

let url ~endpoint t = Printf.sprintf "http://%s/%s%s" endpoint api_version t.path
