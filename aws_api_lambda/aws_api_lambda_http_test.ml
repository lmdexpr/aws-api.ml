(* The loop itself is covered in aws_api_lambda_test; here [Http.run] is exercised end to end, against
   a fake Runtime API on the loopback interface, through the cohttp-eio handler. *)

type recorded = { meth : string; path : string; headers : Http.Header.t; body : string }

(* [respond ~meth ~path ~body] yields (status, headers, body); every request is recorded. *)
let with_fake_runtime ~env ~respond f =
  let recorded = ref [] in
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen ~sw ~backlog:4 ~reuse_addr:true env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with `Tcp (_, port) -> port | `Unix _ -> assert false
  in
  let callback _conn (request : Http.Request.t) body =
    let body = Eio.Buf_read.of_flow ~max_size:1_000_000 body |> Eio.Buf_read.take_all in
    let meth = Http.Method.to_string (Http.Request.meth request) in
    let path = Http.Request.resource request in
    recorded := { meth; path; headers = Http.Request.headers request; body } :: !recorded;
    let status, headers, body = respond ~meth ~path ~body in
    Cohttp_eio.Server.respond_string ~headers:(Http.Header.of_list headers) ~status ~body ()
  in
  let server = Cohttp_eio.Server.make ~callback () in
  Eio.Fiber.fork_daemon ~sw (fun () -> Cohttp_eio.Server.run socket server ~on_error:raise);
  let client = Cohttp_eio.Client.make ~https:None env#net in
  let endpoint = Printf.sprintf "127.0.0.1:%d" port in
  let result = f ~client ~endpoint in
  result, List.rev !recorded

let next_path = "/2018-06-01/runtime/invocation/next"

let next_headers =
  [
    "Lambda-Runtime-Aws-Request-Id", "req-1";
    "Lambda-Runtime-Deadline-Ms", "1542409706888";
    "Lambda-Runtime-Invoked-Function-Arn", "arn:aws:lambda:ap-northeast-1:123456789012:function:f";
    "Lambda-Runtime-Invocation-Id", "inv-1";
    "Lambda-Runtime-Trace-Id", "Root=1-test";
  ]

(* One pending event, then 202 for the first post and 500 for the next GET so [run] terminates. *)
let single_event_runtime () =
  let served = ref false in
  fun ~meth ~path ~body:_ ->
    match meth, path with
    | "GET", p when p = next_path && not !served ->
      served := true;
      `OK, next_headers, {|{"n":1}|}
    | "GET", _ -> `Internal_server_error, [], ""
    | "POST", _ -> `Accepted, [ "Content-Type", "application/json" ], {|{"status":"OK"}|}
    | _ -> `Not_found, [], ""

let test_handle_maps_request_and_response env () =
  let (response : Aws_api_lambda.Response.t), recorded =
    with_fake_runtime ~env ~respond:(single_event_runtime ()) @@ fun ~client ~endpoint ->
    Aws_api_cohttp_eio.run ~client @@ fun () ->
    Aws_api_lambda.Http.handle ~endpoint @@ fun () ->
    Aws_api_lambda.Transport.call
      {
        meth = `POST;
        path = "/runtime/invocation/req-1/response";
        headers = [ "X-Test", "1" ];
        body = Some "hi";
      }
  in
  Alcotest.(check int) "status" 202 response.status;
  Alcotest.(check string) "body" {|{"status":"OK"}|} response.body;
  Alcotest.(check (option string))
    "header lookup is case-insensitive" (Some "application/json")
    (Aws_api_lambda.Response.header "CONTENT-TYPE" response);
  match recorded with
  | [ post ] ->
    Alcotest.(check string) "method" "POST" post.meth;
    Alcotest.(check string) "path" "/2018-06-01/runtime/invocation/req-1/response" post.path;
    Alcotest.(check string) "body" "hi" post.body;
    Alcotest.(check (option string)) "header" (Some "1") (Http.Header.get post.headers "x-test")
  | _ -> Alcotest.fail "expected exactly one request"

let test_run env () =
  let fatal, recorded =
    with_fake_runtime ~env ~respond:(single_event_runtime ()) @@ fun ~client ~endpoint ->
    Aws_api_cohttp_eio.run ~client @@ fun () ->
    Aws_api_lambda.Http.run ~propagate:Aws_api_cohttp_eio.is_cancelled ~endpoint
    @@ fun invocation ->
    Alcotest.(check (option string))
      "trace id exported before handler" (Some "Root=1-test")
      (Sys.getenv_opt "_X_AMZN_TRACE_ID");
    Ok (Printf.sprintf {|{"echo":%s}|} invocation.payload)
  in
  Alcotest.(check bool) "stops on 500" true (fatal = Aws_api_lambda.Container_error);
  match List.filter (fun r -> r.meth = "POST") recorded with
  | [ post ] ->
    Alcotest.(check string)
      "response path" "/2018-06-01/runtime/invocation/req-1/response" post.path;
    Alcotest.(check string) "response body" {|{"echo":{"n":1}}|} post.body
  | posts -> Alcotest.failf "expected exactly one POST, got %d" (List.length posts)

exception Unwind

let test_propagate_unwinds env () =
  let unwound, recorded =
    with_fake_runtime ~env ~respond:(single_event_runtime ()) @@ fun ~client ~endpoint ->
    match
      Aws_api_cohttp_eio.run ~client @@ fun () ->
      Aws_api_lambda.Http.run ~propagate:(( = ) Unwind) ~endpoint @@ fun _ -> raise Unwind
    with
    | _ -> false
    | exception Unwind -> true
  in
  Alcotest.(check bool) "propagated exception escapes run" true unwound;
  Alcotest.(check int)
    "nothing posted" 0
    (List.length (List.filter (fun r -> r.meth = "POST") recorded))

let () =
  Eio_main.run @@ fun env ->
  Alcotest.run "aws-api-lambda http"
    [
      ( "handle",
        [
          Alcotest.test_case "maps request and response" `Quick
            (test_handle_maps_request_and_response env);
        ] );
      ( "run",
        [
          Alcotest.test_case "drives the loop" `Quick (test_run env);
          Alcotest.test_case "propagate unwinds" `Quick (test_propagate_unwinds env);
        ] );
    ]
