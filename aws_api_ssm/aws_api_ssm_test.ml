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
let ssm = Aws_api_ssm.make ~provider ~region:"ap-northeast-1" ~now:(fun () -> 0.) ()
let reply ?(status = 200) body _ : Aws_api.Http.response = { status; headers = []; body }
let parse = Yojson.Safe.from_string
let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

let get_parameter () =
  let result, seen =
    with_http
      ~respond:
        (reply
           {|{"Parameter":{"Name":"/app/db","Type":"SecureString","Value":"s3cret","Version":3,
               "LastModifiedDate":1.7E9,"Unknown":true}}|})
    @@ fun () ->
    Aws_api_ssm.Get_parameter.perform ssm { name = "/app/db"; with_decryption = Some true }
  in
  (match seen with
  | [ request ] ->
    let header name = Aws_api.Http.header name request.headers in
    Alcotest.(check string)
      "uri" "https://ssm.ap-northeast-1.amazonaws.com/" (Uri.to_string request.uri);
    Alcotest.(check (option string))
      "target" (Some "AmazonSSM.GetParameter") (header "X-Amz-Target");
    Alcotest.(check (option string))
      "content type" (Some "application/x-amz-json-1.1") (header "Content-Type");
    Alcotest.(check bool)
      "signed" true
      (Option.fold ~none:false
         ~some:
           (String.starts_with
              ~prefix:"AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/19700101/ap-northeast-1/ssm/")
         (header "Authorization"));
    Alcotest.(check (option json))
      "body"
      (Some (parse {|{"Name":"/app/db","WithDecryption":true}|}))
      (Option.map parse request.body)
  | _ -> Alcotest.fail "expected one request");
  match result with
  | Ok { parameter = Some p } ->
    Alcotest.(check (option string)) "value" (Some "s3cret") p.value;
    Alcotest.(check (option int)) "version" (Some 3) p.version;
    Alcotest.(check (option (float 0.))) "date" (Some 1.7e9) p.last_modified_date
  | Ok { parameter = None } -> Alcotest.fail "no parameter"
  | Error e -> Alcotest.fail (Aws_api_ssm.Error.to_string e)

let error () =
  let result, _ =
    with_http
      ~respond:
        (reply ~status:400 {|{"__type":"com.amazonaws.ssm#ParameterNotFound","message":"nope"}|})
    @@ fun () -> Aws_api_ssm.Get_parameter.perform ssm { name = "x"; with_decryption = None }
  in
  match result with
  | Ok _ -> Alcotest.fail "expected error"
  | Error e ->
    Alcotest.(check string) "error" "ParameterNotFound: nope" (Aws_api_ssm.Error.to_string e)

let empty_output () =
  let result, seen =
    with_http ~respond:(reply "{}") @@ fun () ->
    Aws_api_ssm.Delete_parameter.perform ssm { name = "x" }
  in
  Alcotest.(check (list (option string)))
    "body" [ Some {|{"Name":"x"}|} ]
    (List.map (fun (r : Aws_api.Http.request) -> r.body) seen);
  match result with Ok () -> () | Error e -> Alcotest.fail (Aws_api_ssm.Error.to_string e)

let get name = Aws_api_ssm.Get_parameter.perform ssm { name; with_decryption = None }
let error_string = function Ok _ -> "ok" | Error e -> Aws_api_ssm.Error.to_string e

let other_statuses () =
  let run status body = fst (with_http ~respond:(reply ~status body) @@ fun () -> get "x") in
  Alcotest.(check string) "5xx" "HttpStatus: status 503" (error_string (run 503 "down"));
  Alcotest.(check string) "3xx" "HttpStatus: status 301" (error_string (run 301 ""));
  Alcotest.(check bool)
    "is_http_status" true
    (match run 503 "down" with Error e -> Aws_api_ssm.Error.is_http_status e | Ok _ -> false)

let contains ~needle s =
  let n = String.length s and k = String.length needle in
  let rec go i = i + k <= n && (String.sub s i k = needle || go (i + 1)) in
  go 0

let decode_failure () =
  let result, _ =
    with_http ~respond:(reply {|{"Parameter":{"Value":"s3cret","Version":"not-an-int"}}|})
    @@ fun () -> get "x"
  in
  match result with
  | Ok _ -> Alcotest.fail "expected error"
  | Error e ->
    Alcotest.(check bool) "is_deserialization" true (Aws_api_ssm.Error.is_deserialization e);
    Alcotest.(check string) "body dropped" "" e.body;
    Alcotest.(check bool)
      "secret not in message" false
      (Option.fold ~none:false ~some:(contains ~needle:"s3cret") e.message)

let body_preview () =
  let long = String.make 1000 'x' in
  let e = Aws_api_ssm.Error.http_status ~status:502 ~body:long in
  Alcotest.(check string) "message wins" "HttpStatus: status 502" (Aws_api_ssm.Error.to_string e);
  let e = Aws_api_ssm.Error.of_body long in
  Alcotest.(check int) "truncated" 259 (String.length (Aws_api_ssm.Error.to_string e))

let bad_region () =
  Alcotest.check_raises "slash"
    (Invalid_argument "Transport.make: invalid region \"x.evil.example/\"") (fun () ->
    ignore (Aws_api_ssm.make ~provider ~region:"x.evil.example/" ~now:(fun () -> 0.) ()))

let () =
  Alcotest.run "aws-api-ssm"
    [
      ( "generated",
        [
          Alcotest.test_case "GetParameter signs, posts, decodes" `Quick get_parameter;
          Alcotest.test_case "4xx error body" `Quick error;
          Alcotest.test_case "empty output" `Quick empty_output;
          Alcotest.test_case "3xx and 5xx are Error" `Quick other_statuses;
          Alcotest.test_case "decode failure drops the body" `Quick decode_failure;
          Alcotest.test_case "body preview" `Quick body_preview;
          Alcotest.test_case "bad region" `Quick bad_region;
        ] );
    ]
