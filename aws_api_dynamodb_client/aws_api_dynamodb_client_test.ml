module Item = Aws_api_dynamodb_client.Item
module Client = Aws_api_dynamodb_client.Client
module Value = Aws_api_dynamodb_client.Value
module Number = Aws_api_dynamodb_client.Number
module Projection = Aws_api_dynamodb_client.Projection

let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal
let encode item = Aws_api_dynamodb_client.Envelope.(of_item item |> yojson_of_attrs)
let decode json = Aws_api_dynamodb_client.Envelope.(attrs_of_yojson json |> to_item)
let item = Alcotest.testable (fun fmt i -> Yojson.Safe.pp fmt (encode i)) Item.equal
let parse = Yojson.Safe.from_string
let static = Sigv4.Provider.Static.make ~access_key:"AKIDEXAMPLE" ~secret_key:"secret" ()
let now () = 0.
let api = Aws_api_dynamodb.make ~provider:static ~region:"us-east-1" ~now ()

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

(* Same, at the action level: [respond] sees the action name and JSON body, answers with a 2xx
   JSON or a 4xx body. *)
let with_stub ~(respond : action:string -> body:string -> (Yojson.Safe.t, string) result) k =
  let respond (request : Aws_api.Http.request) : Aws_api.Http.response =
    let action =
      match Aws_api.Http.header "X-Amz-Target" request.headers with
      | Some target -> (
        match String.split_last ~sep:"." target with Some (_, a) -> a | None -> target)
      | None -> ""
    in
    match respond ~action ~body:(Option.value ~default:"" request.body) with
    | Ok json -> { status = 200; headers = []; body = Yojson.Safe.to_string json }
    | Error body -> { status = 400; headers = []; body }
  in
  fst (with_http ~respond k)

let record ~response =
  let seen = ref [] in
  let respond ~action ~body =
    seen := (action, parse body) :: !seen;
    response
  in
  seen, respond

let db = Client.make api ~table:"example-table"
let alice = Item.(empty |> add "pk" (Value.String "alice") |> add "age" (Value.int 30))
let alice_key = Item.singleton "pk" (Value.String "alice")
let json_item xs = Projection.item_of_yojson_exn (`Assoc xs)
let unwrap = function Ok x -> x | Error e -> Alcotest.fail e

(* Wire envelope *)

let test_wire_encodes_every_json_kind () =
  let item =
    json_item
      [
        "s", `String "x";
        "i", `Int 1;
        "f", `Float 1.5;
        "b", `Bool true;
        "n", `Null;
        "l", `List [ `Int 1; `String "y" ];
        "m", `Assoc [ "k", `Bool false ];
      ]
  in
  Alcotest.check json "PutItem body"
    (parse
       {|{"TableName":"example-table","Item":{"b":{"BOOL":true},"f":{"N":"1.5"},"i":{"N":"1"},
          "l":{"L":[{"N":"1"},{"S":"y"}]},"m":{"M":{"k":{"BOOL":false}}},"n":{"NULL":true},"s":{"S":"x"}}}|})
    Aws_api_dynamodb.(
      put_item_input ~table_name:"example-table"
        ~item:(Aws_api_dynamodb_client.Envelope.of_item item)
        ()
      |> yojson_of_put_item_input)

let test_wire_decodes_numbers_and_sets () =
  let decoded =
    Some
      (decode
         (parse {|{"i":{"N":"42"},"f":{"N":"0.5"},"ss":{"SS":["a","b"]},"ns":{"NS":["1","2.5"]}}|}))
  in
  Alcotest.(check (option item))
    "decoded"
    (Some
       (Item.of_list
          [
            "i", Value.int 42;
            "f", Value.Number (Number.of_string_exn "0.5");
            "ss", Value.String_set (unwrap (Value.String_set.of_list [ "a"; "b" ]));
            ( "ns",
              Value.Number_set
                (unwrap (Value.Number_set.of_list [ Number.of_int 1; Number.of_string_exn "2.5" ]))
            );
          ]))
    decoded

let test_wire_numbers_round_trip () =
  let big = "12345678901234567890123456789012345678" in
  let third = 1.0 /. 3.0 in
  let numbers = json_item [ "big", `Intlit big; "third", `Float third; "tenth", `Float 0.1 ] in
  let wire = encode numbers in
  Alcotest.check json "encoded"
    (parse
       {|{"big":{"N":"12345678901234567890123456789012345678"},"tenth":{"N":"0.1"},"third":{"N":"0.33333333333333331"}}|})
    wire;
  Alcotest.(check (option item)) "decoded" (Some numbers) (Some (decode wire))

(* Absent optional fields must be omitted, not null. *)

let query ?limit ?scan_index_forward ?exclusive_start_key () =
  Aws_api_dynamodb.(
    query_input ?limit ?scan_index_forward
      ?exclusive_start_key:(Option.map Aws_api_dynamodb_client.Envelope.of_item exclusive_start_key)
      ~table_name:"example-table" ~key_condition_expression:"#pk = :pk"
      ~expression_attribute_names:[ "#pk", "pk" ]
      ~expression_attribute_values:
        (Aws_api_dynamodb_client.Envelope.of_item (Item.singleton ":pk" (Value.String "alice")))
      ()
    |> yojson_of_query_input)

let query_output json =
  let (o : Aws_api_dynamodb.query_output) = Aws_api_dynamodb.query_output_of_yojson json in
  Aws_api_dynamodb_client.Envelope.(items o.items, Option.map to_item o.last_evaluated_key)

let test_query_omits_absent_fields () =
  Alcotest.(check string)
    "unchanged bytes without optional fields"
    {|{"TableName":"example-table","KeyConditionExpression":"#pk = :pk","ExpressionAttributeNames":{"#pk":"pk"},"ExpressionAttributeValues":{":pk":{"S":"alice"}}}|}
    (query () |> Yojson.Safe.to_string)

let test_query_emits_limit_and_direction () =
  Alcotest.check json "Limit and ScanIndexForward"
    (parse
       {|{"TableName":"example-table","KeyConditionExpression":"#pk = :pk","ExpressionAttributeNames":{"#pk":"pk"},"ExpressionAttributeValues":{":pk":{"S":"alice"}},"Limit":10,"ScanIndexForward":false}|})
    (query ~limit:10 ~scan_index_forward:false ())

let test_query_emits_exclusive_start_key () =
  Alcotest.check json "ExclusiveStartKey"
    (parse
       {|{"TableName":"example-table","KeyConditionExpression":"#pk = :pk","ExpressionAttributeNames":{"#pk":"pk"},"ExpressionAttributeValues":{":pk":{"S":"alice"}},"ExclusiveStartKey":{"pk":{"S":"alice"}}}|})
    (query ~exclusive_start_key:alice_key ())

let test_query_decodes_last_evaluated_key () =
  let items, last_evaluated_key =
    query_output
      (parse
         {|{"Items":[{"pk":{"S":"alice"},"age":{"N":"30"}}],"LastEvaluatedKey":{"pk":{"S":"alice"}},"Count":1}|})
  in
  Alcotest.(check (list item)) "items" [ alice ] items;
  Alcotest.(check (option item)) "LastEvaluatedKey" (Some alice_key) last_evaluated_key

let test_query_decodes_absent_last_evaluated_key () =
  let items, last_evaluated_key = query_output (parse {|{"Items":[{"pk":{"S":"alice"}}]}|}) in
  Alcotest.(check (list item)) "items" [ alice_key ] items;
  Alcotest.(check (option item)) "no LastEvaluatedKey" None last_evaluated_key

(* Client helpers through the effect *)

let test_get () =
  let seen, respond =
    record ~response:(Ok (parse {|{"Item":{"pk":{"S":"alice"},"age":{"N":"30"}}}|}))
  in
  let result = with_stub ~respond @@ fun () -> Client.get db ~key:alice_key in
  Alcotest.(check (list (pair string json)))
    "request"
    [ "GetItem", parse {|{"TableName":"example-table","Key":{"pk":{"S":"alice"}}}|} ]
    !seen;
  Alcotest.(check (result (option item) reject)) "response" (Ok (Some alice)) result

let test_query_follows_pagination () =
  let pages =
    ref
      [
        {|{"Items":[{"pk":{"S":"a"}},{"pk":{"S":"b"}}],"LastEvaluatedKey":{"pk":{"S":"b"}}}|};
        {|{"Items":[{"pk":{"S":"c"}},{"pk":{"S":"d"}}]}|};
      ]
  in
  let requests = ref [] in
  let respond ~action ~body =
    Alcotest.(check string) "action" "Query" action;
    requests := parse body :: !requests;
    match !pages with
    | page :: rest ->
      pages := rest;
      Ok (parse page)
    | [] -> Alcotest.fail "queried past the last page"
  in
  let result =
    with_stub ~respond @@ fun () ->
    Client.query db ~key_condition_expression:"#pk = :pk"
      ~expression_attribute_names:[ "#pk", "pk" ]
      ~expression_attribute_values:(Item.singleton ":pk" (Value.String "alice"))
      ~filter_expression:"attribute_exists(age)" ~scan_index_forward:false
  in
  Alcotest.(check (result (list item) reject))
    "all items in order"
    (Ok (List.map (fun pk -> Item.singleton "pk" (Value.String pk)) [ "a"; "b"; "c"; "d" ]))
    result;
  Alcotest.(check (list json))
    "continuation key and query options"
    [
      parse
        {|{"TableName":"example-table","KeyConditionExpression":"#pk = :pk","ExpressionAttributeNames":{"#pk":"pk"},"ExpressionAttributeValues":{":pk":{"S":"alice"}},"FilterExpression":"attribute_exists(age)","ScanIndexForward":false}|};
      parse
        {|{"TableName":"example-table","KeyConditionExpression":"#pk = :pk","ExpressionAttributeNames":{"#pk":"pk"},"ExpressionAttributeValues":{":pk":{"S":"alice"}},"FilterExpression":"attribute_exists(age)","ScanIndexForward":false,"ExclusiveStartKey":{"pk":{"S":"b"}}}|};
    ]
    (List.rev !requests)

let test_query_limit_returns_one_page () =
  let seen, record_response =
    record
      ~response:
        (Ok
           (parse
              {|{"Items":[{"pk":{"S":"alice"},"age":{"N":"30"}}],"LastEvaluatedKey":{"pk":{"S":"alice"}}}|}))
  in
  let respond ~action ~body =
    if !seen <> [] then Alcotest.fail "queried past the first page with limit";
    record_response ~action ~body
  in
  let result =
    with_stub ~respond @@ fun () ->
    Client.query ~limit:10 db ~key_condition_expression:"#pk = :pk"
      ~expression_attribute_names:[ "#pk", "pk" ]
      ~expression_attribute_values:(Item.singleton ":pk" (Value.String "alice"))
  in
  Alcotest.(check (result (list item) reject)) "first page only" (Ok [ alice ]) result;
  Alcotest.(check (list (pair string json)))
    "one request with Limit"
    [ "Query", query ~limit:10 () ]
    !seen

let test_scan_follows_pagination () =
  let pages =
    ref
      [
        {|{"Items":[{"pk":{"S":"a"}}],"LastEvaluatedKey":{"pk":{"S":"a"}}}|};
        {|{"Items":[{"pk":{"S":"b"}}]}|};
      ]
  in
  let requests = ref [] in
  let respond ~action:_ ~body =
    requests := parse body :: !requests;
    match !pages with
    | page :: rest ->
      pages := rest;
      Ok (parse page)
    | [] -> Alcotest.fail "scanned past the last page"
  in
  let result = with_stub ~respond @@ fun () -> Client.scan db in
  Alcotest.(check (result (list item) reject))
    "all items in order"
    (Ok [ Item.singleton "pk" (Value.String "a"); Item.singleton "pk" (Value.String "b") ])
    result;
  Alcotest.(check (list json))
    "second request carries ExclusiveStartKey"
    [
      parse {|{"TableName":"example-table"}|};
      parse {|{"TableName":"example-table","ExclusiveStartKey":{"pk":{"S":"a"}}}|};
    ]
    (List.rev !requests)

let test_update_requests_all_new () =
  let seen, respond =
    record ~response:(Ok (parse {|{"Attributes":{"pk":{"S":"alice"},"age":{"N":"31"}}}|}))
  in
  let result =
    with_stub ~respond @@ fun () ->
    Client.update db ~key:alice_key ~update_expression:"SET age = :age"
      ~expression_attribute_values:(Item.singleton ":age" (Value.int 31))
  in
  Alcotest.(check (list (pair string json)))
    "request"
    [
      ( "UpdateItem",
        parse
          {|{"TableName":"example-table","Key":{"pk":{"S":"alice"}},"UpdateExpression":"SET age = :age","ExpressionAttributeValues":{":age":{"N":"31"}},"ReturnValues":"ALL_NEW"}|}
      );
    ]
    !seen;
  Alcotest.(check (result (option item) reject))
    "response"
    (Ok (Some (Item.add "age" (Value.int 31) alice)))
    result

let test_transact_write () =
  let seen, respond = record ~response:(Ok (`Assoc [])) in
  let result =
    with_stub ~respond @@ fun () ->
    Aws_api_dynamodb_client.Transaction.(
      write api
        [
          put_if_not_exists ~table_name:"example-table" ~item:alice ~primary_key:"pk";
          delete ~table_name:"example-table" ~key:(Item.singleton "pk" (Value.String "bob")) ();
        ])
  in
  Alcotest.(check (result unit reject)) "ok" (Ok ()) result;
  Alcotest.(check (list (pair string json)))
    "request"
    [
      ( "TransactWriteItems",
        parse
          {|{"TransactItems":[
              {"Put":{"TableName":"example-table","Item":{"age":{"N":"30"},"pk":{"S":"alice"}},"ConditionExpression":"attribute_not_exists(#pk)","ExpressionAttributeNames":{"#pk":"pk"}}},
              {"Delete":{"TableName":"example-table","Key":{"pk":{"S":"bob"}}}}]}|}
      );
    ]
    !seen

(* Errors *)

let error =
  Alcotest.testable
    (fun fmt e -> Format.pp_print_string fmt (Aws_api_dynamodb_client.Error.to_string e))
    ( = )

let test_conditional_check_failed () =
  let body =
    {|{"__type":"com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException","message":"The conditional request failed"}|}
  in
  let result =
    with_stub ~respond:(fun ~action:_ ~body:_ -> Error body) @@ fun () ->
    Client.put_if_not_exists db ~item:alice ~primary_key:"pk"
  in
  match result with
  | Error e ->
    Alcotest.(check bool)
      "recognized" true
      (Aws_api_dynamodb_client.Error.is_conditional_check_failed e);
    Alcotest.(check string) "code" "ConditionalCheckFailedException" e.code;
    Alcotest.(check (option string)) "message" (Some "The conditional request failed") e.message
  | Ok () -> Alcotest.fail "expected an error"

let test_transaction_cancelled_by_condition () =
  let e =
    Aws_api_dynamodb_client.Error.of_body
      {|{"__type":"com.amazonaws.dynamodb.v20120810#TransactionCanceledException","CancellationReasons":[{"Code":"None"},{"Code":"ConditionalCheckFailed","Message":"The conditional request failed"}]}|}
  in
  Alcotest.(check bool)
    "recognized" true
    (Aws_api_dynamodb_client.Error.is_conditional_check_failed e);
  Alcotest.(check (list string))
    "reasons"
    [ "None"; "ConditionalCheckFailed" ]
    (Aws_api_dynamodb_client.Error.cancellation_reasons e)

let test_unparseable_error_keeps_body () =
  let e = Aws_api_dynamodb_client.Error.of_body "<html>gateway</html>" in
  Alcotest.check error "raw body" { code = ""; message = None; body = "<html>gateway</html>" } e;
  Alcotest.(check bool)
    "not conditional" false
    (Aws_api_dynamodb_client.Error.is_conditional_check_failed e)

(* --- Http bridge --- *)

let test_http_signs_and_posts () =
  let respond _ : Aws_api.Http.response = { status = 200; headers = []; body = {|{"Item":{}}|} } in
  let result, seen = with_http ~respond @@ fun () -> Client.get db ~key:alice_key in
  Alcotest.(check bool) "ok" true (Result.is_ok result);
  match seen with
  | [ request ] ->
    Alcotest.(check string) "method" "POST" (Aws_api.Http.string_of_meth request.meth);
    Alcotest.(check string)
      "uri" "https://dynamodb.us-east-1.amazonaws.com/" (Uri.to_string request.uri);
    let header name = Aws_api.Http.header name request.headers in
    Alcotest.(check (option string))
      "target" (Some "DynamoDB_20120810.GetItem") (header "X-Amz-Target");
    Alcotest.(check (option string))
      "content type" (Some "application/x-amz-json-1.0") (header "Content-Type");
    Alcotest.(check (option string)) "date" (Some "19700101T000000Z") (header "X-Amz-Date");
    Alcotest.(check bool)
      "signed" true
      (Option.fold ~none:false
         ~some:
           (String.starts_with
              ~prefix:"AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/19700101/us-east-1/dynamodb/")
         (header "Authorization"));
    Alcotest.(check (option json))
      "body"
      (Some (parse {|{"TableName":"example-table","Key":{"pk":{"S":"alice"}}}|}))
      (Option.map parse request.body)
  | _ -> Alcotest.fail "expected one request"

let test_http_status_mapping () =
  let run status body =
    let respond _ : Aws_api.Http.response = { status; headers = []; body } in
    fst
      ( with_http ~respond @@ fun () ->
        match Client.get db ~key:alice_key with Ok _ -> "ok" | Error e -> "error:" ^ e.code )
  in
  Alcotest.(check string) "2xx" "ok" (run 200 {|{}|});
  Alcotest.(check string)
    "4xx" "error:AccessDeniedException"
    (run 400 {|{"__type":"com.amazon.coral.service#AccessDeniedException","Message":"no"}|});
  Alcotest.(check string) "5xx" "error:HttpStatus" (run 503 "down")

let test_http_default_provider_fetches_through_effect () =
  let respond (r : Aws_api.Http.request) : Aws_api.Http.response =
    if Uri.host r.uri = Some "169.254.170.2" then
      {
        status = 200;
        headers = [];
        body =
          {|{"AccessKeyId":"AKID_ECS","SecretAccessKey":"s","Token":"t","Expiration":"2100-01-01T00:00:00Z"}|};
      }
    else
      { status = 200; headers = []; body = "{}" }
  in
  let getenv = function
    | "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI" -> Some "/v2/creds"
    | _ -> None
  in
  let provider =
    Sigv4.Provider.default ~getenv
      ~read_file:(fun _ -> None)
      ~now ~http:Aws_api_dynamodb.Transport.http ()
  in
  let db = Client.make (Aws_api_dynamodb.make ~provider ~region:"us-east-1" ~now ()) ~table:"t" in
  let _, seen =
    with_http ~respond @@ fun () ->
    ignore (Client.get db ~key:alice_key);
    ignore (Client.get db ~key:alice_key)
  in
  Alcotest.(check (list string))
    "credentials fetched once through the same effect, then two calls"
    [ "169.254.170.2"; "dynamodb.us-east-1.amazonaws.com"; "dynamodb.us-east-1.amazonaws.com" ]
    (List.map (fun (r : Aws_api.Http.request) -> Option.get (Uri.host r.uri)) seen)

let test_max_pages () =
  let page n =
    `Assoc
      [
        "Items", `List [];
        "LastEvaluatedKey", `Assoc [ "pk", `Assoc [ "S", `String (string_of_int n) ] ];
      ]
  in
  let calls = ref 0 in
  let respond ~action:_ ~body:_ =
    incr calls;
    Ok (page !calls)
  in
  let result = with_stub ~respond @@ fun () -> Client.scan ~max_pages:3 db in
  (match result with
  | Error e ->
    Alcotest.(check bool) "too many pages" true (Aws_api_dynamodb_client.Error.is_too_many_pages e)
  | Ok _ -> Alcotest.fail "expected Error");
  Alcotest.(check int) "stopped after max_pages requests" 3 !calls

let test_error_message_capitalized () =
  let e =
    Aws_api_dynamodb_client.Error.of_body
      {|{"__type":"com.amazon.coral.service#ExpiredTokenException","Message":"The security token included in the request is expired"}|}
  in
  Alcotest.(check string)
    "to_string" "ExpiredTokenException: The security token included in the request is expired"
    (Aws_api_dynamodb_client.Error.to_string e)

let test_number_long_exponent () =
  Alcotest.(check bool)
    "leading zeros in exponent" true
    (Result.is_ok (Number.of_string "1e-0000005"));
  Alcotest.(check bool)
    "seven significant exponent digits rejected" true
    (Result.is_error (Number.of_string "1e1000000"))

let () =
  Alcotest.run "aws-api-dynamodb"
    [
      ( "wire",
        [
          Alcotest.test_case "encodes every JSON kind" `Quick test_wire_encodes_every_json_kind;
          Alcotest.test_case "decodes numbers and sets" `Quick test_wire_decodes_numbers_and_sets;
          Alcotest.test_case "numbers round-trip" `Quick test_wire_numbers_round_trip;
        ] );
      ( "query",
        [
          Alcotest.test_case "omits absent fields" `Quick test_query_omits_absent_fields;
          Alcotest.test_case "emits limit and direction" `Quick test_query_emits_limit_and_direction;
          Alcotest.test_case "emits exclusive start key" `Quick test_query_emits_exclusive_start_key;
          Alcotest.test_case "decodes last evaluated key" `Quick
            test_query_decodes_last_evaluated_key;
          Alcotest.test_case "decodes absent last evaluated key" `Quick
            test_query_decodes_absent_last_evaluated_key;
        ] );
      ( "client",
        [
          Alcotest.test_case "get" `Quick test_get;
          Alcotest.test_case "query follows pagination" `Quick test_query_follows_pagination;
          Alcotest.test_case "query limit returns one page" `Quick test_query_limit_returns_one_page;
          Alcotest.test_case "scan follows pagination" `Quick test_scan_follows_pagination;
          Alcotest.test_case "update requests ALL_NEW" `Quick test_update_requests_all_new;
          Alcotest.test_case "transact write" `Quick test_transact_write;
        ] );
      ( "error",
        [
          Alcotest.test_case "conditional check failed" `Quick test_conditional_check_failed;
          Alcotest.test_case "transaction cancelled by condition" `Quick
            test_transaction_cancelled_by_condition;
          Alcotest.test_case "unparseable body" `Quick test_unparseable_error_keeps_body;
        ] );
      ( "http",
        [
          Alcotest.test_case "signs and posts" `Quick test_http_signs_and_posts;
          Alcotest.test_case "status mapping" `Quick test_http_status_mapping;
          Alcotest.test_case "default provider fetches through the effect" `Quick
            test_http_default_provider_fetches_through_effect;
        ] );
      ( "limits",
        [
          Alcotest.test_case "max_pages" `Quick test_max_pages;
          Alcotest.test_case "Message key" `Quick test_error_message_capitalized;
          Alcotest.test_case "long exponent" `Quick test_number_long_exponent;
        ] );
    ]
