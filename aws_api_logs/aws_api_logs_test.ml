(* Answers Aws_api.Http.Call from a script; records every request. *)
let with_http ~(respond : Aws_api.Http.request -> Aws_api.Http.response) k =
  let seen = ref [] in
  let result =
    try k ()
    with effect Aws_api.Http.Call request, k ->
      seen := request :: !seen;
      Effect.Deep.continue k (respond request)
  in
  result, List.rev !seen

let provider = Sigv4.Provider.Static.make ~access_key:"AKIDEXAMPLE" ~secret_key:"secret" ()
let logs = Aws_api_logs.make ~provider ~region:"ap-northeast-1" ~now:(fun () -> 0.) ()
let reply ?(status = 200) body _ : Aws_api.Http.response = { status; headers = []; body }
let parse = Yojson.Safe.from_string
let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal
let error_string = function Ok _ -> "ok" | Error e -> Aws_api_logs.Error.to_string e

let put_log_events () =
  let result, seen =
    with_http
      ~respond:
        (reply {|{"nextSequenceToken":"t","rejectedLogEventsInfo":{"tooOldLogEventEndIndex":0}}|})
    @@ fun () ->
    Aws_api_logs.Put_log_events.perform logs
      (Aws_api_logs.put_log_events_request ~log_group_name:"/app" ~log_stream_name:"s1"
         ~log_events:
           [
             Aws_api_logs.input_log_event ~timestamp:1_700_000_000_000 ~message:"started";
             Aws_api_logs.input_log_event ~timestamp:1_700_000_000_001 ~message:"ready";
           ]
         ())
  in
  (match seen with
  | [ request ] ->
    let header name = Aws_api.Http.header name request.headers in
    Alcotest.(check string)
      "uri" "https://logs.ap-northeast-1.amazonaws.com/" (Uri.to_string request.uri);
    Alcotest.(check (option string))
      "target" (Some "Logs_20140328.PutLogEvents") (header "X-Amz-Target");
    Alcotest.(check (option string))
      "content type" (Some "application/x-amz-json-1.1") (header "Content-Type");
    Alcotest.(check bool)
      "signed" true
      (Option.fold ~none:false
         ~some:
           (String.starts_with
              ~prefix:"AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/19700101/ap-northeast-1/logs/")
         (header "Authorization"));
    Alcotest.(check (option json))
      "body"
      (Some
         (parse
            {|{"logGroupName":"/app","logStreamName":"s1","logEvents":[
                {"timestamp":1700000000000,"message":"started"},
                {"timestamp":1700000000001,"message":"ready"}]}|}))
      (Option.map parse request.body)
  | _ -> Alcotest.fail "expected one request");
  match result with
  | Ok r ->
    Alcotest.(check (option string)) "sequence token" (Some "t") r.next_sequence_token;
    Alcotest.(check (option (option int)))
      "rejected" (Some (Some 0))
      (Option.map
         (fun (i : Aws_api_logs.rejected_log_events_info) -> i.too_old_log_event_end_index)
         r.rejected_log_events_info)
  | Error e -> Alcotest.fail (Aws_api_logs.Error.to_string e)

let filter_log_events () =
  let result, seen =
    with_http
      ~respond:
        (reply
           {|{"events":[{"logStreamName":"s1","timestamp":1700000000000,"message":"boom",
               "ingestionTime":1700000000005,"eventId":"e1"}],"nextToken":"n"}|})
    @@ fun () ->
    Aws_api_logs.Filter_log_events.perform logs
      (Aws_api_logs.filter_log_events_request ~log_group_name:"/app" ~filter_pattern:"ERROR"
         ~start_time:1_700_000_000_000 ())
  in
  Alcotest.(check (list (option json)))
    "body"
    [ Some (parse {|{"logGroupName":"/app","startTime":1700000000000,"filterPattern":"ERROR"}|}) ]
    (List.map (fun (r : Aws_api.Http.request) -> Option.map parse r.body) seen);
  match result with
  | Ok { events = Some [ e ]; next_token; _ } ->
    Alcotest.(check (option string)) "message" (Some "boom") e.message;
    Alcotest.(check (option int)) "timestamp" (Some 1_700_000_000_000) e.timestamp;
    Alcotest.(check (option string)) "next token" (Some "n") next_token
  | Ok _ -> Alcotest.fail "expected one event"
  | Error e -> Alcotest.fail (Aws_api_logs.Error.to_string e)

let get_query_results () =
  let result, _ =
    with_http
      ~respond:
        (reply
           {|{"status":"Complete","results":[[{"field":"@message","value":"boom"}]],
               "statistics":{"recordsMatched":1.0,"recordsScanned":10.0,"bytesScanned":100.0}}|})
    @@ fun () ->
    Aws_api_logs.Get_query_results.perform logs
      (Aws_api_logs.get_query_results_request ~query_id:"q" ())
  in
  match result with
  | Ok r ->
    Alcotest.(check bool) "status" true (r.status = Some `Complete);
    Alcotest.(check (option (list (list (option string)))))
      "values" (Some [ [ Some "boom" ] ])
      (Option.map (List.map (List.map (fun (f : Aws_api_logs.result_field) -> f.value))) r.results)
  | Error e -> Alcotest.fail (Aws_api_logs.Error.to_string e)

let error () =
  let result, _ =
    with_http
      ~respond:
        (reply ~status:400
           {|{"__type":"com.amazonaws.cloudwatchlogs#ResourceNotFoundException",
               "message":"The specified log group does not exist."}|})
    @@ fun () ->
    Aws_api_logs.Get_log_events.perform logs
      (Aws_api_logs.get_log_events_request ~log_group_name:"/missing" ~log_stream_name:"s1" ())
  in
  Alcotest.(check string)
    "error" "ResourceNotFoundException: The specified log group does not exist."
    (error_string result)

let () =
  Alcotest.run "aws-api-logs"
    [
      ( "generated",
        [
          Alcotest.test_case "PutLogEvents signs and encodes" `Quick put_log_events;
          Alcotest.test_case "FilterLogEvents decodes events" `Quick filter_log_events;
          Alcotest.test_case "GetQueryResults decodes enum and rows" `Quick get_query_results;
          Alcotest.test_case "4xx error body" `Quick error;
        ] );
    ]
