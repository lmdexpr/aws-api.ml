(* Tests for the credential Provider abstraction, the env provider, and the chain combinator.
   No Unix is needed: the env provider's [getenv] is injected with a pure stub. *)

let contains haystack needle = String.includes ~affix:needle haystack

(* Extract the access key from an "Authorization: AWS4-HMAC-SHA256 Credential=<AK>/<scope...>" header. *)
let access_key_of signed =
  let auth = List.assoc "Authorization" signed in
  match String.split_first ~sep:"Credential=" auth with
  | None -> Alcotest.failf "no Credential= in %S" auth
  | Some (_, rest) -> (
    match String.split_first ~sep:"/" rest with
    | Some (access_key, _) -> access_key
    | None -> Alcotest.failf "no scope in %S" auth)

(* Resolve [provider] and sign a trivial request, returning the headers to add. *)
let sign_with provider =
  Sigv4.with_provider provider @@ fun () ->
  let credentials = Sigv4.Credentials.fetch () in
  Sigv4.sign
    ~now:(fun () -> 0.)
    ~credentials ~region:"us-east-1" ~service:"s3" ~http_method:"GET"
    ~uri:(Uri.of_string "https://example.com/")
    []

let expect_no_credentials ~contains:subs f =
  match f () with
  | exception Sigv4.No_credentials msg ->
    List.iter
      (fun sub ->
        Alcotest.(check bool) (Printf.sprintf "message contains %S" sub) true (contains msg sub))
      subs
  | _ -> Alcotest.fail "expected Sigv4.No_credentials to be raised"

(* --- env provider --- *)

let test_env_present () =
  let getenv = function
    | "AWS_ACCESS_KEY_ID" -> Some "AKID_ENV"
    | "AWS_SECRET_ACCESS_KEY" -> Some "secret"
    | _ -> None
  in
  Alcotest.(check string)
    "env access key" "AKID_ENV"
    (access_key_of (sign_with (Sigv4.Provider.Env.make ~getenv ())))

let test_env_session_token () =
  let getenv = function
    | "AWS_ACCESS_KEY_ID" -> Some "AKID"
    | "AWS_SECRET_ACCESS_KEY" -> Some "secret"
    | "AWS_SESSION_TOKEN" -> Some "TOKEN123"
    | _ -> None
  in
  let signed = sign_with (Sigv4.Provider.Env.make ~getenv ()) in
  Alcotest.(check string)
    "session token header" "TOKEN123"
    (List.assoc "X-Amz-Security-Token" signed)

let test_env_missing () =
  let getenv _ = None in
  expect_no_credentials ~contains:[ "[env]" ] (fun () ->
    ignore (sign_with (Sigv4.Provider.Env.make ~getenv ())))

(* --- chain --- *)

let decline name = Sigv4.Provider.v ~name (fun () -> Result.error "not applicable")

let test_chain_first_wins () =
  let p =
    Sigv4.Provider.chain
      [
        Sigv4.Provider.Static.make ~access_key:"AK1" ~secret_key:"s" ();
        Sigv4.Provider.Static.make ~access_key:"AK2" ~secret_key:"s" ();
      ]
  in
  Alcotest.(check string) "first resolver wins" "AK1" (access_key_of (sign_with p))

let test_chain_skips_decline () =
  let p =
    Sigv4.Provider.chain
      [ decline "a"; Sigv4.Provider.Static.make ~access_key:"AK2" ~secret_key:"s" () ]
  in
  Alcotest.(check string) "declines are skipped" "AK2" (access_key_of (sign_with p))

let test_chain_all_decline () =
  let p = Sigv4.Provider.chain [ decline "alpha"; decline "beta" ] in
  expect_no_credentials ~contains:[ "[alpha]"; "[beta]" ] (fun () -> ignore (sign_with p))

(* --- http providers: ecs, imds --- *)

let credential_body ?(expiration = "2100-01-01T00:00:00Z") key =
  Printf.sprintf {|{"AccessKeyId":"%s","SecretAccessKey":"s","Token":"tok","Expiration":"%s"}|} key
    expiration

let ecs_env = function
  | "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI" -> Some "/v2/credentials/abc"
  | _ -> None

let ok body : Sigv4.Provider.Http.response = { status = 200; body }

let test_ecs_resolves_from_endpoint () =
  let urls = ref [] in
  let http (r : Sigv4.Provider.Http.request) =
    urls := r.url :: !urls;
    ok (credential_body "AKID_ECS")
  in
  let p = Sigv4.Provider.Ecs.make ~getenv:ecs_env ~now:(fun () -> 0.) ~http () in
  let signed = sign_with p in
  Alcotest.(check string) "access key" "AKID_ECS" (access_key_of signed);
  Alcotest.(check (option string))
    "session token is sent" (Some "tok")
    (List.assoc_opt "X-Amz-Security-Token" signed);
  Alcotest.(check (list string))
    "relative uri joined with the link-local host"
    [ "http://169.254.170.2/v2/credentials/abc" ]
    !urls

let test_ecs_caches_until_expiry () =
  let calls = ref 0 in
  let http _ =
    incr calls;
    ok (credential_body ~expiration:"1970-01-01T01:00:00Z" (Printf.sprintf "AKID_%d" !calls))
  in
  let now = ref 0. in
  let p = Sigv4.Provider.Ecs.make ~getenv:ecs_env ~now:(fun () -> !now) ~http () in
  Alcotest.(check string) "first fetch" "AKID_1" (access_key_of (sign_with p));
  Alcotest.(check string) "cached" "AKID_1" (access_key_of (sign_with p));
  (* 3600 s expiry minus the 300 s refresh margin. *)
  now := 3300.;
  Alcotest.(check string) "refetched near expiry" "AKID_2" (access_key_of (sign_with p));
  Alcotest.(check int) "endpoint hit twice" 2 !calls

let test_ecs_declines_without_env () =
  let http _ = Alcotest.fail "must not fetch" in
  let p = Sigv4.Provider.Ecs.make ~getenv:(fun _ -> None) ~now:(fun () -> 0.) ~http () in
  expect_no_credentials ~contains:[ "[ecs]"; "AWS_CONTAINER_CREDENTIALS_" ] (fun () ->
    ignore (sign_with p))

(* A scripted IMDSv2: the token from PUT must come back on every metadata read. *)
let imds ?(role = "my-role") () =
  let seen = ref [] in
  let http (r : Sigv4.Provider.Http.request) : Sigv4.Provider.Http.response =
    seen := r :: !seen;
    let token = List.assoc_opt "X-aws-ec2-metadata-token" r.headers in
    match r.meth, r.url with
    | `PUT, "http://169.254.169.254/latest/api/token" ->
      Alcotest.(check (option string))
        "token ttl requested" (Some "21600")
        (List.assoc_opt "X-aws-ec2-metadata-token-ttl-seconds" r.headers);
      ok "TOKEN"
    | `GET, _ when token <> Some "TOKEN" -> { status = 401; body = "" }
    | `GET, "http://169.254.169.254/latest/meta-data/iam/security-credentials/" -> ok (role ^ "\n")
    | `GET, url
      when url = "http://169.254.169.254/latest/meta-data/iam/security-credentials/" ^ role ->
      ok (credential_body "AKID_IMDS")
    | _ -> { status = 404; body = "" }
  in
  seen, http

let test_imds_resolves_with_token () =
  let seen, http = imds () in
  let p = Sigv4.Provider.Imds.make ~getenv:(fun _ -> None) ~now:(fun () -> 0.) ~http () in
  Alcotest.(check string) "access key" "AKID_IMDS" (access_key_of (sign_with p));
  Alcotest.(check (list string))
    "token, role, credentials"
    [
      "PUT /latest/api/token";
      "GET /latest/meta-data/iam/security-credentials/";
      "GET /latest/meta-data/iam/security-credentials/my-role";
    ]
    (List.rev_map
       (fun (r : Sigv4.Provider.Http.request) ->
         (match r.meth with `PUT -> "PUT " | `GET -> "GET ")
         ^ String.drop_first (String.length "http://169.254.169.254") r.url)
       !seen)

let test_imds_declines_when_disabled () =
  let http _ = Alcotest.fail "must not fetch" in
  let getenv = function "AWS_EC2_METADATA_DISABLED" -> Some "true" | _ -> None in
  let p = Sigv4.Provider.Imds.make ~getenv ~now:(fun () -> 0.) ~http () in
  expect_no_credentials ~contains:[ "[imds]"; "AWS_EC2_METADATA_DISABLED" ] (fun () ->
    ignore (sign_with p))

let test_imds_declines_when_unreachable () =
  let http _ = failwith "connection refused" in
  let p = Sigv4.Provider.Imds.make ~getenv:(fun _ -> None) ~now:(fun () -> 0.) ~http () in
  expect_no_credentials ~contains:[ "[imds]"; "connection refused" ] (fun () ->
    ignore (sign_with p))

(* --- profile provider --- *)

let files ~credentials ~config = function
  | "/home/u/.aws/credentials" -> credentials
  | "/home/u/.aws/config" -> config
  | _ -> None

let profile_env ?profile () = function
  | "HOME" -> Some "/home/u"
  | "AWS_PROFILE" -> profile
  | _ -> None

let test_profile_parse () =
  let sections =
    Sigv4.Provider.Profile.parse
      "# comment\n\
       [default]\n\
       aws_access_key_id = A\n\
       ; another\n\
       aws_secret_access_key=B\n\n\
       [profile dev]\n\
       region = us-west-2\n"
  in
  Alcotest.(check (list (pair string (list (pair string string)))))
    "sections"
    [
      "default", [ "aws_access_key_id", "A"; "aws_secret_access_key", "B" ];
      "profile dev", [ "region", "us-west-2" ];
    ]
    sections

let test_profile_credentials_file () =
  let read_file =
    files
      ~credentials:
        (Some
           "[default]\n\
            aws_access_key_id = AKID_DEF\n\
            aws_secret_access_key = s\n\
            [dev]\n\
            aws_access_key_id = AKID_DEV\n\
            aws_secret_access_key = s\n\
            aws_session_token = t\n")
      ~config:None
  in
  let p = Sigv4.Provider.Profile.make ~getenv:(profile_env ()) ~read_file () in
  Alcotest.(check string) "default profile" "AKID_DEF" (access_key_of (sign_with p));
  let p = Sigv4.Provider.Profile.make ~getenv:(profile_env ~profile:"dev" ()) ~read_file () in
  let signed = sign_with p in
  Alcotest.(check string) "AWS_PROFILE" "AKID_DEV" (access_key_of signed);
  Alcotest.(check (option string))
    "session token" (Some "t")
    (List.assoc_opt "X-Amz-Security-Token" signed)

let test_profile_falls_back_to_config () =
  let read_file =
    files ~credentials:None
      ~config:(Some "[profile dev]\naws_access_key_id = AKID_CFG\naws_secret_access_key = s\n")
  in
  let p = Sigv4.Provider.Profile.make ~getenv:(profile_env ~profile:"dev" ()) ~read_file () in
  Alcotest.(check string) "config file" "AKID_CFG" (access_key_of (sign_with p))

let test_profile_declines_without_keys () =
  let p = Sigv4.Provider.Profile.make ~getenv:(profile_env ()) ~read_file:(fun _ -> None) () in
  expect_no_credentials ~contains:[ "[profile]"; "\"default\"" ] (fun () -> ignore (sign_with p))

(* --- http providers: hardening --- *)

let test_ecs_malformed_document_declines () =
  let bodies = ref [ "<html>captive portal</html>"; {|{"AccessKeyId":"AK","Token":123}|}; "[]" ] in
  let http _ =
    let body = List.hd !bodies in
    bodies := List.tl !bodies;
    ok body
  in
  let p = Sigv4.Provider.Ecs.make ~getenv:ecs_env ~now:(fun () -> 0.) ~http () in
  for _ = 1 to 3 do
    expect_no_credentials ~contains:[ "[ecs]"; "credential document" ] (fun () ->
      ignore (sign_with p))
  done;
  (* The chain falls through instead of aborting. *)
  let fallback = Sigv4.Provider.Static.make ~access_key:"AKID_NEXT" ~secret_key:"s" () in
  let http _ = ok "not json" in
  let p =
    Sigv4.Provider.chain
      [ Sigv4.Provider.Ecs.make ~getenv:ecs_env ~now:(fun () -> 0.) ~http (); fallback ]
  in
  Alcotest.(check string) "next provider" "AKID_NEXT" (access_key_of (sign_with p))

let test_ecs_decline_reason_omits_secrets () =
  let secret = "SECRET_IN_BODY" in
  let http _ : Sigv4.Provider.Http.response =
    { status = 403; body = String.make 200 'x' ^ secret }
  in
  let getenv = function
    | "AWS_CONTAINER_CREDENTIALS_FULL_URI" -> Some "http://127.0.0.1:8080/creds?token=QUERY_SECRET"
    | _ -> None
  in
  let p = Sigv4.Provider.Ecs.make ~getenv ~now:(fun () -> 0.) ~http () in
  match sign_with p with
  | _ -> Alcotest.fail "expected decline"
  | exception Sigv4.No_credentials msg ->
    Alcotest.(check bool) "status kept" true (contains msg "answered 403");
    Alcotest.(check bool) "body truncated" false (contains msg secret);
    Alcotest.(check bool) "query redacted" false (contains msg "QUERY_SECRET")

let test_ecs_no_expiry_is_cached () =
  let calls = ref 0 in
  let http _ =
    incr calls;
    ok {|{"AccessKeyId":"AKID","SecretAccessKey":"s"}|}
  in
  let now = ref 0. in
  let p = Sigv4.Provider.Ecs.make ~getenv:ecs_env ~now:(fun () -> !now) ~http () in
  ignore (sign_with p);
  ignore (sign_with p);
  Alcotest.(check int) "one fetch" 1 !calls;
  (* 15 min default TTL minus the 5 min margin. *)
  now := 601.;
  ignore (sign_with p);
  Alcotest.(check int) "refetched after the default ttl" 2 !calls

let test_ecs_stale_served_when_refresh_fails () =
  let calls = ref 0 in
  let http _ =
    incr calls;
    if !calls = 1 then
      ok (credential_body ~expiration:"1970-01-01T01:00:00Z" "AKID_1")
    else
      failwith "agent down"
  in
  let now = ref 0. in
  let p = Sigv4.Provider.Ecs.make ~getenv:ecs_env ~now:(fun () -> !now) ~http () in
  Alcotest.(check string) "first" "AKID_1" (access_key_of (sign_with p));
  now := 3400.;
  Alcotest.(check string) "stale but unexpired" "AKID_1" (access_key_of (sign_with p));
  now := 3601.;
  expect_no_credentials ~contains:[ "agent down" ] (fun () -> ignore (sign_with p))

let test_ecs_redirect_declines () =
  let http _ : Sigv4.Provider.Http.response = { status = 302; body = "" } in
  let p = Sigv4.Provider.Ecs.make ~getenv:ecs_env ~now:(fun () -> 0.) ~http () in
  expect_no_credentials ~contains:[ "answered 302" ] (fun () -> ignore (sign_with p))

let test_ecs_full_uri_restricted () =
  let http _ = Alcotest.fail "must not fetch" in
  List.iter
    (fun url ->
      let getenv = function "AWS_CONTAINER_CREDENTIALS_FULL_URI" -> Some url | _ -> None in
      let p = Sigv4.Provider.Ecs.make ~getenv ~now:(fun () -> 0.) ~http () in
      expect_no_credentials ~contains:[ "must be https" ] (fun () -> ignore (sign_with p)))
    [
      "http://10.0.0.5/creds";
      "http://example.com/creds";
      "http://127.evil.example/creds";
      "http://127.0.0.256/creds";
      "ftp://127.0.0.1/creds";
      "creds";
    ];
  List.iter
    (fun url ->
      let http _ = ok (credential_body "AKID_OK") in
      let getenv = function "AWS_CONTAINER_CREDENTIALS_FULL_URI" -> Some url | _ -> None in
      let p = Sigv4.Provider.Ecs.make ~getenv ~now:(fun () -> 0.) ~http () in
      Alcotest.(check string) url "AKID_OK" (access_key_of (sign_with p)))
    [
      "https://example.com/creds";
      "http://127.0.0.1:8080/creds";
      "http://localhost/creds";
      "http://169.254.170.23/v1/credentials";
      "http://[fd00:ec2::23]/v1/credentials";
    ]

let test_ecs_authorization_token () =
  let seen = ref [] in
  let http (r : Sigv4.Provider.Http.request) =
    seen := r.headers :: !seen;
    ok (credential_body "AKID")
  in
  let base = function
    | "AWS_CONTAINER_CREDENTIALS_FULL_URI" -> Some "http://169.254.170.23/v1/credentials"
    | _ -> None
  in
  let getenv v = if v = "AWS_CONTAINER_AUTHORIZATION_TOKEN" then Some "tok-env" else base v in
  ignore (sign_with (Sigv4.Provider.Ecs.make ~getenv ~now:(fun () -> 0.) ~http ()));
  let getenv v =
    if v = "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE" then Some "/run/token" else base v
  in
  let read_file = function "/run/token" -> Some "tok-file\n" | _ -> None in
  ignore (sign_with (Sigv4.Provider.Ecs.make ~getenv ~read_file ~now:(fun () -> 0.) ~http ()));
  Alcotest.(check (list (list (pair string string))))
    "authorization headers"
    [ [ "Authorization", "tok-file" ]; [ "Authorization", "tok-env" ] ]
    !seen;
  let getenv v =
    match v with
    | "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE" -> Some "/missing"
    | "AWS_CONTAINER_AUTHORIZATION_TOKEN" -> Some "tok-env"
    | _ -> base v
  in
  expect_no_credentials ~contains:[ "TOKEN_FILE cannot be read" ] (fun () ->
    ignore
      (sign_with
         (Sigv4.Provider.Ecs.make ~getenv ~read_file:(fun _ -> None) ~now:(fun () -> 0.) ~http ())));
  let getenv v = if v = "AWS_CONTAINER_AUTHORIZATION_TOKEN" then Some "evil\r\nX: y" else base v in
  expect_no_credentials ~contains:[ "line break" ] (fun () ->
    ignore (sign_with (Sigv4.Provider.Ecs.make ~getenv ~now:(fun () -> 0.) ~http ())))

let test_imds_caches () =
  let seen, http = imds () in
  let p = Sigv4.Provider.Imds.make ~getenv:(fun _ -> None) ~now:(fun () -> 0.) ~http () in
  ignore (sign_with p);
  ignore (sign_with p);
  Alcotest.(check int) "three requests for two resolutions" 3 (List.length !seen)

let test_profile_env_overrides_and_equals_in_value () =
  let read_file = function
    | "/tmp/creds" -> Some "[dev]\naws_access_key_id = AKID_X\naws_secret_access_key = a=b=c\n"
    | _ -> None
  in
  let getenv = function
    | "AWS_SHARED_CREDENTIALS_FILE" -> Some "/tmp/creds"
    | "AWS_PROFILE" -> Some "dev"
    | _ -> None
  in
  let p = Sigv4.Provider.Profile.make ~getenv ~read_file () in
  Alcotest.(check string) "file from env, no HOME needed" "AKID_X" (access_key_of (sign_with p))

let test_profile_config_requires_profile_prefix () =
  let read_file =
    files ~credentials:None
      ~config:(Some "[dev]\naws_access_key_id = AKID_BARE\naws_secret_access_key = s\n")
  in
  let p = Sigv4.Provider.Profile.make ~getenv:(profile_env ~profile:"dev" ()) ~read_file () in
  expect_no_credentials ~contains:[ "[profile]" ] (fun () -> ignore (sign_with p));
  let read_file =
    files ~credentials:None
      ~config:(Some "[profile default]\naws_access_key_id = AKID_PD\naws_secret_access_key = s\n")
  in
  let p = Sigv4.Provider.Profile.make ~getenv:(profile_env ()) ~read_file () in
  Alcotest.(check string) "[profile default] accepted" "AKID_PD" (access_key_of (sign_with p))

let test_epoch_of_iso8601 () =
  let parse = Sigv4.Provider.Fetched.epoch_of_iso8601 in
  Alcotest.(check (option (float 0.))) "epoch" (Some 1704067200.) (parse "2024-01-01T00:00:00Z");
  Alcotest.(check (option (float 0.))) "leap day" (Some 1709164800.) (parse "2024-02-29T00:00:00Z");
  Alcotest.(check (option (float 0.)))
    "fractional seconds" (Some 1704067200.)
    (parse "2024-01-01T00:00:00.123Z");
  Alcotest.(check (option (float 0.))) "offset rejected" None (parse "2024-01-01T00:00:00+09:00");
  Alcotest.(check (option (float 0.))) "month 13 rejected" None (parse "2024-13-01T00:00:00Z");
  Alcotest.(check (option (float 0.))) "negative hour rejected" None (parse "2024-01-01T-1:00:00Z");
  Alcotest.(check (option (float 0.))) "garbage rejected" None (parse "soon")

(* --- handler exception delivery --- *)

exception Boom

let test_provider_exception_reaches_fetch_site () =
  let p = Sigv4.Provider.v (fun () -> raise Boom) in
  let caught_at_fetch =
    Sigv4.with_provider p @@ fun () ->
    match Sigv4.Credentials.fetch () with _ -> false | exception Boom -> true
  in
  Alcotest.(check bool) "raised at the fetch site" true caught_at_fetch

(* --- default chain --- *)

let test_default_order () =
  let http _ = Alcotest.fail "env must win before any fetch" in
  let getenv = function
    | "AWS_ACCESS_KEY_ID" -> Some "AKID_ENV"
    | "AWS_SECRET_ACCESS_KEY" -> Some "s"
    | _ -> None
  in
  let p = Sigv4.Provider.default ~getenv ~read_file:(fun _ -> None) ~now:(fun () -> 0.) ~http () in
  Alcotest.(check string) "env first" "AKID_ENV" (access_key_of (sign_with p));
  let _, http = imds () in
  let p =
    Sigv4.Provider.default
      ~getenv:(fun _ -> None)
      ~read_file:(fun _ -> None)
      ~now:(fun () -> 0.)
      ~http ()
  in
  Alcotest.(check string) "imds last" "AKID_IMDS" (access_key_of (sign_with p));
  let p =
    Sigv4.Provider.default
      ~getenv:(fun _ -> None)
      ~read_file:(fun _ -> None)
      ~now:(fun () -> 0.)
      ~http:(fun _ -> failwith "unreachable")
      ()
  in
  expect_no_credentials ~contains:[ "[env]"; "[profile]"; "[ecs]"; "[imds]" ] (fun () ->
    ignore (sign_with p))

let () =
  Alcotest.run "credentials"
    [
      ( "provider",
        [
          Alcotest.test_case "env present resolves" `Quick test_env_present;
          Alcotest.test_case "env session token is signed" `Quick test_env_session_token;
          Alcotest.test_case "env missing declines" `Quick test_env_missing;
          Alcotest.test_case "chain first resolver wins" `Quick test_chain_first_wins;
          Alcotest.test_case "chain skips declines" `Quick test_chain_skips_decline;
          Alcotest.test_case "chain all decline raises" `Quick test_chain_all_decline;
        ] );
      ( "ecs",
        [
          Alcotest.test_case "resolves from the endpoint" `Quick test_ecs_resolves_from_endpoint;
          Alcotest.test_case "caches until near expiry" `Quick test_ecs_caches_until_expiry;
          Alcotest.test_case "declines without env" `Quick test_ecs_declines_without_env;
        ] );
      ( "imds",
        [
          Alcotest.test_case "resolves with a v2 token" `Quick test_imds_resolves_with_token;
          Alcotest.test_case "declines when disabled" `Quick test_imds_declines_when_disabled;
          Alcotest.test_case "declines when unreachable" `Quick test_imds_declines_when_unreachable;
        ] );
      ( "profile",
        [
          Alcotest.test_case "parses ini" `Quick test_profile_parse;
          Alcotest.test_case "reads the credentials file" `Quick test_profile_credentials_file;
          Alcotest.test_case "falls back to the config file" `Quick
            test_profile_falls_back_to_config;
          Alcotest.test_case "declines without keys" `Quick test_profile_declines_without_keys;
        ] );
      ( "hardening",
        [
          Alcotest.test_case "malformed document declines" `Quick
            test_ecs_malformed_document_declines;
          Alcotest.test_case "decline reason omits secrets" `Quick
            test_ecs_decline_reason_omits_secrets;
          Alcotest.test_case "no expiry is cached" `Quick test_ecs_no_expiry_is_cached;
          Alcotest.test_case "stale served when refresh fails" `Quick
            test_ecs_stale_served_when_refresh_fails;
          Alcotest.test_case "redirect declines" `Quick test_ecs_redirect_declines;
          Alcotest.test_case "full uri restricted" `Quick test_ecs_full_uri_restricted;
          Alcotest.test_case "authorization token" `Quick test_ecs_authorization_token;
          Alcotest.test_case "imds caches" `Quick test_imds_caches;
          Alcotest.test_case "profile env overrides" `Quick
            test_profile_env_overrides_and_equals_in_value;
          Alcotest.test_case "config needs profile prefix" `Quick
            test_profile_config_requires_profile_prefix;
          Alcotest.test_case "iso8601" `Quick test_epoch_of_iso8601;
          Alcotest.test_case "provider exception at fetch site" `Quick
            test_provider_exception_reaches_fetch_site;
        ] );
      "default", [ Alcotest.test_case "env, profile, ecs, imds" `Quick test_default_order ];
    ]
