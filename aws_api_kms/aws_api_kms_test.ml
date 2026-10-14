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
let kms = Aws_api_kms.make ~provider ~region:"ap-northeast-1" ~now:(fun () -> 0.) ()
let reply ?(status = 200) body _ : Aws_api.Http.response = { status; headers = []; body }
let parse = Yojson.Safe.from_string
let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal
let error_string = function Ok _ -> "ok" | Error e -> Aws_api_kms.Error.to_string e

let encrypt () =
  let result, seen =
    with_http
      ~respond:
        (reply
           {|{"CiphertextBlob":"AAECAw==","KeyId":"arn:aws:kms:ap-northeast-1:111122223333:key/k",
               "EncryptionAlgorithm":"SYMMETRIC_DEFAULT"}|})
    @@ fun () ->
    Aws_api_kms.Encrypt.perform kms
      (Aws_api_kms.encrypt_request ~key_id:"alias/app" ~plaintext:"s3cret"
         ~encryption_context:[ "tenant", "t1" ]
         ())
  in
  (match seen with
  | [ request ] ->
    let header name = Aws_api.Http.header name request.headers in
    Alcotest.(check string)
      "uri" "https://kms.ap-northeast-1.amazonaws.com/" (Uri.to_string request.uri);
    Alcotest.(check (option string)) "target" (Some "TrentService.Encrypt") (header "X-Amz-Target");
    Alcotest.(check (option string))
      "content type" (Some "application/x-amz-json-1.1") (header "Content-Type");
    Alcotest.(check bool)
      "signed" true
      (Option.fold ~none:false
         ~some:
           (String.starts_with
              ~prefix:"AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/19700101/ap-northeast-1/kms/")
         (header "Authorization"));
    Alcotest.(check (option json))
      "body"
      (Some
         (parse {|{"KeyId":"alias/app","Plaintext":"czNjcmV0","EncryptionContext":{"tenant":"t1"}}|}))
      (Option.map parse request.body)
  | _ -> Alcotest.fail "expected one request");
  match result with
  | Ok r ->
    Alcotest.(check (option string)) "ciphertext" (Some "\000\001\002\003") r.ciphertext_blob;
    Alcotest.(check bool) "enum" true (r.encryption_algorithm = Some `SYMMETRIC_DEFAULT)
  | Error e -> Alcotest.fail (Aws_api_kms.Error.to_string e)

let decrypt () =
  let result, seen =
    with_http ~respond:(reply {|{"Plaintext":"czNjcmV0","KeyId":"k"}|}) @@ fun () ->
    Aws_api_kms.Decrypt.perform kms
      (Aws_api_kms.decrypt_request ~ciphertext_blob:"\000\001\002\003" ())
  in
  Alcotest.(check (list (option json)))
    "body"
    [ Some (parse {|{"CiphertextBlob":"AAECAw=="}|}) ]
    (List.map (fun (r : Aws_api.Http.request) -> Option.map parse r.body) seen);
  match result with
  | Ok r -> Alcotest.(check (option string)) "plaintext" (Some "s3cret") r.plaintext
  | Error e -> Alcotest.fail (Aws_api_kms.Error.to_string e)

let error () =
  let result, _ =
    with_http
      ~respond:
        (reply ~status:400
           {|{"__type":"com.amazonaws.kms#InvalidCiphertextException","message":"bad"}|})
    @@ fun () -> Aws_api_kms.Decrypt.perform kms (Aws_api_kms.decrypt_request ())
  in
  Alcotest.(check string) "error" "InvalidCiphertextException: bad" (error_string result)

let contains ~needle s =
  let n = String.length s and k = String.length needle in
  let rec go i = i + k <= n && (String.sub s i k = needle || go (i + 1)) in
  go 0

(* Decrypt responses carry plaintext; a failed decode must not echo it. *)
let decode_failure () =
  let result, _ =
    with_http ~respond:(reply {|{"Plaintext":"czNjcmV0","KeyId":42}|}) @@ fun () ->
    Aws_api_kms.Decrypt.perform kms (Aws_api_kms.decrypt_request ())
  in
  match result with
  | Ok _ -> Alcotest.fail "expected error"
  | Error e ->
    Alcotest.(check bool) "is_deserialization" true (Aws_api_kms.Error.is_deserialization e);
    Alcotest.(check string) "body dropped" "" e.body;
    Alcotest.(check bool)
      "plaintext not in message" false
      (Option.fold ~none:false ~some:(contains ~needle:"czNjcmV0") e.message)

let invalid_base64 () =
  let result, _ =
    with_http ~respond:(reply {|{"Plaintext":"not base64!"}|}) @@ fun () ->
    Aws_api_kms.Decrypt.perform kms (Aws_api_kms.decrypt_request ())
  in
  Alcotest.(check bool)
    "is_deserialization" true
    (match result with Error e -> Aws_api_kms.Error.is_deserialization e | Ok _ -> false)

let () =
  Alcotest.run "aws-api-kms"
    [
      ( "generated",
        [
          Alcotest.test_case "Encrypt signs, base64-encodes, decodes" `Quick encrypt;
          Alcotest.test_case "Decrypt round-trips blobs" `Quick decrypt;
          Alcotest.test_case "4xx error body" `Quick error;
          Alcotest.test_case "decode failure drops the body" `Quick decode_failure;
          Alcotest.test_case "invalid base64 is Error" `Quick invalid_base64;
        ] );
    ]
