(* The handler against a fake server on the loopback interface: request mapping, response mapping,
   and the body size bound. *)

type recorded = { meth : string; path : string; headers : Http.Header.t; body : string }

let with_fake_server ~env ~respond f =
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
  let base = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d" port) in
  let result = f ~client ~base in
  result, List.rev !recorded

let echo ~meth:_ ~path:_ ~body = `Accepted, [ "Content-Type", "text/plain" ], "echo:" ^ body

let test_maps_request_and_response env () =
  let (response : Aws_api.Http.response), recorded =
    with_fake_server ~env ~respond:echo @@ fun ~client ~base ->
    Aws_api_cohttp_eio.run ~client @@ fun () ->
    Aws_api.Http.call
      {
        meth = `POST;
        uri = Uri.with_path base "/things";
        headers = [ "X-Test", "1" ];
        body = Some "hi";
      }
  in
  Alcotest.(check int) "status" 202 response.status;
  Alcotest.(check string) "body" "echo:hi" response.body;
  Alcotest.(check (option string))
    "header lookup is case-insensitive" (Some "text/plain")
    (Aws_api.Http.header "CONTENT-TYPE" response.headers);
  match recorded with
  | [ post ] ->
    Alcotest.(check string) "method" "POST" post.meth;
    Alcotest.(check string) "path" "/things" post.path;
    Alcotest.(check string) "body" "hi" post.body;
    Alcotest.(check (option string)) "header" (Some "1") (Http.Header.get post.headers "x-test")
  | _ -> Alcotest.fail "expected exactly one request"

let test_body_bound_raises_at_call_site env () =
  let raised, _ =
    with_fake_server ~env ~respond:echo @@ fun ~client ~base ->
    Aws_api_cohttp_eio.run ~max_response_size:4 ~client @@ fun () ->
    match Aws_api.Http.call { meth = `GET; uri = base; headers = []; body = None } with
    | _ -> false
    | exception _ -> true
  in
  Alcotest.(check bool) "oversized body raises where the call was performed" true raised

let test_connection_refused_raises_at_call_site env () =
  let client = Cohttp_eio.Client.make ~https:None env#net in
  let port =
    Eio.Switch.run @@ fun sw ->
    let socket =
      Eio.Net.listen ~sw ~backlog:1 ~reuse_addr:true env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
    in
    match Eio.Net.listening_addr socket with `Tcp (_, port) -> port | `Unix _ -> assert false
  in
  (* The switch closed the socket, so nothing listens on [port] any more. *)
  let raised =
    Aws_api_cohttp_eio.run ~client @@ fun () ->
    match
      Aws_api.Http.call
        {
          meth = `GET;
          uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/" port);
          headers = [];
          body = None;
        }
    with
    | _ -> false
    | exception _ -> true
  in
  Alcotest.(check bool) "raised where the call was performed" true raised

let test_is_cancelled () =
  Alcotest.(check bool)
    "cancelled" true
    (Aws_api_cohttp_eio.is_cancelled (Eio.Cancel.Cancelled Exit));
  Alcotest.(check bool) "other" false (Aws_api_cohttp_eio.is_cancelled Exit)

let () =
  Eio_main.run @@ fun env ->
  Alcotest.run "aws-api-cohttp-eio"
    [
      ( "run",
        [
          Alcotest.test_case "maps request and response" `Quick (test_maps_request_and_response env);
          Alcotest.test_case "bounds the response body" `Quick
            (test_body_bound_raises_at_call_site env);
          Alcotest.test_case "connection refused raises at call site" `Quick
            (test_connection_refused_raises_at_call_site env);
          Alcotest.test_case "is_cancelled" `Quick test_is_cancelled;
        ] );
    ]
