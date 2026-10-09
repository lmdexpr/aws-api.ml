(* No HTTP: the loop is driven through a transport that answers from a fixed script. *)

open Aws_api_lambda

let response ?(headers = []) status body : Response.t = { status; headers; body }

let test_error_type_sanitized () =
  Alcotest.(check string)
    "header-safe" "Bad_Request__X__y" (Error.v ~error_type:"Bad Request\r\nX: y" "m").error_type;
  Alcotest.(check string) "empty" "Error" (Error.v ~error_type:"" "m").error_type;
  Alcotest.(check string)
    "token kept" "Runtime.Timeout-1" (Error.v ~error_type:"Runtime.Timeout-1" "m").error_type;
  let literal : Error.t = { error_type = "X\r\nY: z"; error_message = ""; stack_trace = [] } in
  Alcotest.(check (option string))
    "record literal is sanitized at the header" (Some "X__Y__z")
    (List.assoc_opt "Lambda-Runtime-Function-Error-Type" (Request.init_error literal).headers)

let next_headers =
  [
    "Lambda-Runtime-Aws-Request-Id", "req-1";
    "Lambda-Runtime-Deadline-Ms", "1542409706888";
    "Lambda-Runtime-Invoked-Function-Arn", "arn:aws:lambda:ap-northeast-1:123456789012:function:f";
    "Lambda-Runtime-Trace-Id", "Root=1-5bef4de7;Sampled=1";
    "Lambda-Runtime-Invocation-Id", "inv-1";
  ]

let event = response ~headers:next_headers 200 {|{"n":1}|}
let accepted = response 202 {|{"status":"OK"}|}

let with_transport (transport : Request.t -> Response.t) k =
  let open Effect.Deep in
  try k ()
  with effect Transport.Call request, k -> (
    match transport request with
    | response -> continue k response
    | exception exn -> discontinue k exn)

(* Runs [f] under a transport answering GETs with [on_next] and POSTs with [on_post]; returns [f]'s
   result together with every request the transport saw, in order. *)
let with_scripted_transport ?(on_next = event) ?(on_post = accepted) f =
  let seen = ref [] in
  let transport (request : Request.t) =
    seen := request :: !seen;
    match request.meth with `GET -> on_next | `POST -> on_post
  in
  let result = with_transport transport f in
  result, List.rev !seen

let only_post seen =
  match List.filter (fun (r : Request.t) -> r.meth = `POST) seen with
  | [ post ] -> post
  | posts -> Alcotest.failf "expected exactly one POST, got %d" (List.length posts)

let invocation () =
  match Invocation.of_response event with
  | Ok invocation -> invocation
  | Error e -> Alcotest.failf "unexpected parse error: %s" (Invocation.parse_error_to_string e)

let fatal_t = Alcotest.testable (fun fmt f -> Format.pp_print_string fmt (fatal_to_string f)) ( = )
let step_result = Alcotest.(result unit fatal_t)

(* Invocation *)

let test_of_response_full () =
  let inv = invocation () in
  Alcotest.(check string) "request_id" "req-1" inv.request_id;
  Alcotest.(check int) "deadline_ms" 1542409706888 inv.deadline_ms;
  Alcotest.(check (option string)) "trace_id" (Some "Root=1-5bef4de7;Sampled=1") inv.trace_id;
  Alcotest.(check (option string)) "client_context" None inv.client_context;
  Alcotest.(check (option string)) "invocation_id" (Some "inv-1") inv.invocation_id;
  Alcotest.(check string) "payload" {|{"n":1}|} inv.payload

let test_of_response_missing_header () =
  let headers = List.remove_assoc "Lambda-Runtime-Aws-Request-Id" next_headers in
  Alcotest.(check step_result)
    "missing request id"
    (Error (Malformed_invocation (Invocation.Missing_header "Lambda-Runtime-Aws-Request-Id")))
    (Invocation.of_response (response ~headers 200 "")
    |> Result.map ignore
    |> Result.map_error (fun e -> Malformed_invocation e))

let test_of_response_invalid_deadline () =
  let headers =
    ("Lambda-Runtime-Deadline-Ms", "soon")
    :: List.remove_assoc "Lambda-Runtime-Deadline-Ms" next_headers
  in
  Alcotest.(check step_result)
    "invalid deadline"
    (Error
       (Malformed_invocation
          (Invocation.Invalid_header { name = "Lambda-Runtime-Deadline-Ms"; value = "soon" })))
    (Invocation.of_response (response ~headers 200 "")
    |> Result.map ignore
    |> Result.map_error (fun e -> Malformed_invocation e))

let test_remaining_ms () =
  let inv = invocation () in
  Alcotest.(check int) "before deadline" 1000 (Invocation.remaining_ms ~now_ms:1542409705888 inv);
  Alcotest.(check int) "past deadline" (-5) (Invocation.remaining_ms ~now_ms:1542409706893 inv)

(* Context *)

let full_env =
  [
    "AWS_LAMBDA_FUNCTION_NAME", "f";
    "AWS_LAMBDA_FUNCTION_VERSION", "$LATEST";
    "AWS_LAMBDA_FUNCTION_MEMORY_SIZE", "512";
    "AWS_REGION", "ap-northeast-1";
    "AWS_LAMBDA_LOG_GROUP_NAME", "/aws/lambda/f";
    "AWS_LAMBDA_LOG_STREAM_NAME", "2026/09/08/[$LATEST]abc";
  ]

let context_error =
  Alcotest.testable
    (fun fmt e -> Format.pp_print_string fmt (Context.parse_error_to_string e))
    ( = )

let test_context_of_env_full () =
  match Context.of_env (Fun.flip List.assoc_opt full_env) with
  | Error e -> Alcotest.failf "unexpected: %s" (Context.parse_error_to_string e)
  | Ok ctx ->
    Alcotest.(check string) "function_name" "f" ctx.function_name;
    Alcotest.(check string) "function_version" "$LATEST" ctx.function_version;
    Alcotest.(check int) "memory_size_mb" 512 ctx.memory_size_mb;
    Alcotest.(check string) "region" "ap-northeast-1" ctx.region;
    Alcotest.(check (option string)) "log_group_name" (Some "/aws/lambda/f") ctx.log_group_name;
    Alcotest.(check (option string))
      "log_stream_name" (Some "2026/09/08/[$LATEST]abc") ctx.log_stream_name

let test_context_of_env_snapstart () =
  let env =
    List.filter
      (fun (k, _) -> k <> "AWS_LAMBDA_LOG_GROUP_NAME" && k <> "AWS_LAMBDA_LOG_STREAM_NAME")
      full_env
  in
  match Context.of_env (Fun.flip List.assoc_opt env) with
  | Error e -> Alcotest.failf "unexpected: %s" (Context.parse_error_to_string e)
  | Ok ctx ->
    Alcotest.(check (option string)) "no log group" None ctx.log_group_name;
    Alcotest.(check (option string)) "no log stream" None ctx.log_stream_name

let test_context_of_env_missing () =
  let env = List.remove_assoc "AWS_REGION" full_env in
  Alcotest.(check (result reject context_error))
    "missing region" (Error (Context.Missing_variable "AWS_REGION"))
    (Context.of_env (Fun.flip List.assoc_opt env))

let test_context_of_env_invalid_memory () =
  let env = ("AWS_LAMBDA_FUNCTION_MEMORY_SIZE", "lots") :: full_env in
  Alcotest.(check (result reject context_error))
    "invalid memory"
    (Error (Context.Invalid_variable { name = "AWS_LAMBDA_FUNCTION_MEMORY_SIZE"; value = "lots" }))
    (Context.of_env (Fun.flip List.assoc_opt env))

(* Request *)

let test_request_next () =
  Alcotest.(check string)
    "url" "http://127.0.0.1:9001/2018-06-01/runtime/invocation/next"
    (Request.url ~endpoint:"127.0.0.1:9001" Request.next);
  Alcotest.(check bool) "GET" true (Request.next.meth = `GET);
  Alcotest.(check (option string)) "no body" None Request.next.body

let test_request_response () =
  let request = Request.response (invocation ()) "SUCCESS" in
  Alcotest.(check string) "path" "/runtime/invocation/req-1/response" request.path;
  Alcotest.(check (list (pair string string)))
    "echoes invocation id"
    [ "Lambda-Runtime-Invocation-Id", "inv-1" ]
    request.headers;
  Alcotest.(check (option string)) "body" (Some "SUCCESS") request.body

let test_request_response_without_invocation_id () =
  let inv = { (invocation ()) with invocation_id = None } in
  Alcotest.(check (list (pair string string))) "no echo" [] (Request.response inv "x").headers

let test_request_error () =
  let error = Error.v ~error_type:"Function.InvalidInput" "bad \"event\"\n" in
  let request = Request.error (invocation ()) error in
  Alcotest.(check string) "path" "/runtime/invocation/req-1/error" request.path;
  Alcotest.(check (list (pair string string)))
    "headers"
    [
      "Lambda-Runtime-Function-Error-Type", "Function.InvalidInput";
      "Lambda-Runtime-Invocation-Id", "inv-1";
    ]
    request.headers;
  Alcotest.(check (option string))
    "body"
    (Some {|{"errorMessage":"bad \"event\"\n","errorType":"Function.InvalidInput","stackTrace":[]}|})
    request.body

let test_request_init_error () =
  let request = Request.init_error (Error.v ~error_type:"Runtime.ConfigInvalid" "no token") in
  Alcotest.(check string) "path" "/runtime/init/error" request.path;
  Alcotest.(check (list (pair string string)))
    "headers"
    [ "Lambda-Runtime-Function-Error-Type", "Runtime.ConfigInvalid" ]
    request.headers

(* Error *)

let test_error_of_exn () =
  let error = Error.of_exn (Failure "boom") in
  Alcotest.(check string) "type" "Failure" error.error_type;
  Alcotest.(check string) "message" "Failure(\"boom\")" error.error_message

let test_error_of_exn_backtrace () =
  Printexc.record_backtrace true;
  let error =
    match failwith "boom" with
    | () -> assert false
    | exception exn -> Error.of_exn ~backtrace:(Printexc.get_raw_backtrace ()) exn
  in
  Alcotest.(check bool) "has stack trace" true (error.stack_trace <> []);
  Alcotest.(check bool)
    "lines are non-empty" true
    (List.for_all (fun l -> l <> "") error.stack_trace)

let test_error_json_escaping () =
  let error = Error.v ~stack_trace:[ "a\tb"; "\001" ] ~error_type:"T" "back\\slash" in
  Alcotest.(check string)
    "json" {|{"errorMessage":"back\\slash","errorType":"T","stackTrace":["a\tb","\u0001"]}|}
    (Error.to_json error)

let test_run_raises_on_transport_failure () =
  let raised =
    match
      with_transport (fun _ -> failwith "connection refused") @@ fun () -> run (fun _ -> Ok "")
    with
    | _ -> false
    | exception Failure msg -> msg = "connection refused"
  in
  Alcotest.(check bool) "transport failure escapes run" true raised

(* Transport *)

let test_call_unhandled () =
  let unhandled =
    match Transport.call Request.next with _ -> false | exception Effect.Unhandled _ -> true
  in
  Alcotest.(check bool) "raises Effect.Unhandled" true unhandled

let test_transport_exception_surfaces_at_call () =
  let raised =
    with_transport (fun _ -> failwith "connection refused") @@ fun () ->
    match Transport.call Request.next with _ -> None | exception Failure msg -> Some msg
  in
  Alcotest.(check (option string)) "caught at call site" (Some "connection refused") raised

(* Loop *)

let test_step_success () =
  let result, seen =
    with_scripted_transport @@ fun () ->
    step @@ fun invocation -> Ok (Printf.sprintf {|{"echo":%s}|} invocation.payload)
  in
  Alcotest.(check step_result) "ok" (Ok ()) result;
  let post = only_post seen in
  Alcotest.(check string) "response path" "/runtime/invocation/req-1/response" post.path;
  Alcotest.(check (option string)) "response body" (Some {|{"echo":{"n":1}}|}) post.body;
  Alcotest.(check (list (pair string string)))
    "invocation id echoed"
    [ "Lambda-Runtime-Invocation-Id", "inv-1" ]
    post.headers

let test_step_handler_error () =
  let result, seen =
    with_scripted_transport @@ fun () ->
    step @@ fun _ -> Error (Error.v ~error_type:"Function.Nope" "nope")
  in
  Alcotest.(check step_result) "ok" (Ok ()) result;
  let post = only_post seen in
  Alcotest.(check string) "error path" "/runtime/invocation/req-1/error" post.path;
  Alcotest.(check (option string))
    "error type header" (Some "Function.Nope")
    (List.assoc_opt "Lambda-Runtime-Function-Error-Type" post.headers);
  Alcotest.(check (option string))
    "error body" (Some {|{"errorMessage":"nope","errorType":"Function.Nope","stackTrace":[]}|})
    post.body

let test_step_handler_exception () =
  let result, seen =
    with_scripted_transport @@ fun () ->
    step @@ fun _ -> failwith "boom"
  in
  Alcotest.(check step_result) "ok" (Ok ()) result;
  let post = only_post seen in
  Alcotest.(check string) "error path" "/runtime/invocation/req-1/error" post.path;
  Alcotest.(check (option string))
    "error type header" (Some "Failure")
    (List.assoc_opt "Lambda-Runtime-Function-Error-Type" post.headers)

exception Cancelled

let test_step_propagate () =
  let propagate = function Cancelled -> true | _ -> false in
  let raised, seen =
    with_scripted_transport @@ fun () ->
    match step ~propagate (fun _ -> raise Cancelled) with _ -> false | exception Cancelled -> true
  in
  Alcotest.(check bool) "escaped step" true raised;
  Alcotest.(check int) "nothing posted" 1 (List.length seen)

let test_container_error_on_next () =
  let result, _ =
    with_scripted_transport ~on_next:(response 500 "") @@ fun () -> step (fun _ -> Ok "x")
  in
  Alcotest.(check step_result) "500 on next" (Error Container_error) result

let test_container_error_on_post () =
  let result, _ =
    with_scripted_transport ~on_post:(response 500 "") @@ fun () -> step (fun _ -> Ok "x")
  in
  Alcotest.(check step_result) "500 on post" (Error Container_error) result

let test_malformed_next () =
  let result, _ =
    with_scripted_transport ~on_next:(response 200 "{}") @@ fun () -> step (fun _ -> Ok "x")
  in
  Alcotest.(check step_result)
    "malformed"
    (Error (Malformed_invocation (Invocation.Missing_header "Lambda-Runtime-Aws-Request-Id")))
    result

let test_unexpected_status_on_post () =
  let result, _ =
    with_scripted_transport ~on_post:(response 400 "") @@ fun () -> step (fun _ -> Ok "x")
  in
  match result with
  | Error (Unexpected_status { request; status = 400 }) ->
    Alcotest.(check string) "request" "/runtime/invocation/req-1/response" request.path
  | other ->
    Alcotest.failf "unexpected: %s" (Result.fold ~ok:(Fun.const "Ok") ~error:fatal_to_string other)

let test_run_until_fatal () =
  let served = ref 0 in
  let transport (request : Request.t) =
    match request.meth with
    | `GET when !served < 3 ->
      incr served;
      event
    | `GET -> response 500 ""
    | `POST -> accepted
  in
  let handled = ref 0 in
  let outcome =
    with_transport transport @@ fun () ->
    run @@ fun _ ->
    incr handled;
    Ok "x"
  in
  Alcotest.(check fatal_t) "stops on 500" Container_error outcome;
  Alcotest.(check int) "handled every event first" 3 !handled

let test_report_init_error () =
  let result, seen =
    with_scripted_transport @@ fun () ->
    report_init_error (Error.v ~error_type:"Runtime.ConfigInvalid" "no token")
  in
  Alcotest.(check step_result) "accepted" (Ok ()) result;
  let post = only_post seen in
  Alcotest.(check string) "init error path" "/runtime/init/error" post.path;
  Alcotest.(check (option string))
    "error type header" (Some "Runtime.ConfigInvalid")
    (List.assoc_opt "Lambda-Runtime-Function-Error-Type" post.headers)

let () =
  Alcotest.run "aws-api-lambda"
    [
      ( "Invocation",
        [
          Alcotest.test_case "of_response full" `Quick test_of_response_full;
          Alcotest.test_case "of_response missing header" `Quick test_of_response_missing_header;
          Alcotest.test_case "of_response invalid deadline" `Quick test_of_response_invalid_deadline;
          Alcotest.test_case "remaining_ms" `Quick test_remaining_ms;
        ] );
      ( "Context",
        [
          Alcotest.test_case "of_env full" `Quick test_context_of_env_full;
          Alcotest.test_case "of_env without log names" `Quick test_context_of_env_snapstart;
          Alcotest.test_case "of_env missing variable" `Quick test_context_of_env_missing;
          Alcotest.test_case "of_env invalid memory" `Quick test_context_of_env_invalid_memory;
        ] );
      ( "Request",
        [
          Alcotest.test_case "next" `Quick test_request_next;
          Alcotest.test_case "response" `Quick test_request_response;
          Alcotest.test_case "response without invocation id" `Quick
            test_request_response_without_invocation_id;
          Alcotest.test_case "error" `Quick test_request_error;
          Alcotest.test_case "init_error" `Quick test_request_init_error;
        ] );
      ( "Error",
        [
          Alcotest.test_case "of_exn" `Quick test_error_of_exn;
          Alcotest.test_case "of_exn with backtrace" `Quick test_error_of_exn_backtrace;
          Alcotest.test_case "json escaping" `Quick test_error_json_escaping;
          Alcotest.test_case "error type sanitized" `Quick test_error_type_sanitized;
        ] );
      ( "Transport",
        [
          Alcotest.test_case "call without handler" `Quick test_call_unhandled;
          Alcotest.test_case "run raises on transport failure" `Quick
            test_run_raises_on_transport_failure;
          Alcotest.test_case "exception surfaces at call" `Quick
            test_transport_exception_surfaces_at_call;
        ] );
      ( "loop",
        [
          Alcotest.test_case "success posts response" `Quick test_step_success;
          Alcotest.test_case "handler error posts error" `Quick test_step_handler_error;
          Alcotest.test_case "handler exception posts error" `Quick test_step_handler_exception;
          Alcotest.test_case "propagate lets exceptions through" `Quick test_step_propagate;
          Alcotest.test_case "500 on next" `Quick test_container_error_on_next;
          Alcotest.test_case "500 on post" `Quick test_container_error_on_post;
          Alcotest.test_case "malformed next" `Quick test_malformed_next;
          Alcotest.test_case "unexpected status on post" `Quick test_unexpected_status_on_post;
          Alcotest.test_case "run until fatal" `Quick test_run_until_fatal;
          Alcotest.test_case "report_init_error" `Quick test_report_init_error;
        ] );
    ]
