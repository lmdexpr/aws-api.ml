type t = {
  request_id : string;
  deadline_ms : int;
  invoked_function_arn : string;
  trace_id : string option;
  client_context : string option;
  cognito_identity : string option;
  invocation_id : string option;
  payload : string;
}

type parse_error = Missing_header of string | Invalid_header of { name : string; value : string }

let parse_error_to_string = function
  | Missing_header name -> Printf.sprintf "missing header %s" name
  | Invalid_header { name; value } -> Printf.sprintf "invalid header %s: %S" name value

let request_id_header = "Lambda-Runtime-Aws-Request-Id"
let deadline_ms_header = "Lambda-Runtime-Deadline-Ms"
let function_arn_header = "Lambda-Runtime-Invoked-Function-Arn"
let trace_id_header = "Lambda-Runtime-Trace-Id"
let client_context_header = "Lambda-Runtime-Client-Context"
let cognito_identity_header = "Lambda-Runtime-Cognito-Identity"
let invocation_id_header = "Lambda-Runtime-Invocation-Id"

let of_response (response : Response.t) =
  let headers name = Response.header name response in
  let body = response.body in
  let open Result.Syntax in
  let required name = headers name |> Option.to_result ~none:(Missing_header name) in
  let* request_id = required request_id_header in
  let* deadline = required deadline_ms_header in
  let* deadline_ms =
    int_of_string_opt deadline
    |> Option.to_result ~none:(Invalid_header { name = deadline_ms_header; value = deadline })
  in
  let* invoked_function_arn = required function_arn_header in
  Ok
    {
      request_id;
      deadline_ms;
      invoked_function_arn;
      trace_id = headers trace_id_header;
      client_context = headers client_context_header;
      cognito_identity = headers cognito_identity_header;
      invocation_id = headers invocation_id_header;
      payload = body;
    }

let remaining_ms ~now_ms t = t.deadline_ms - now_ms
