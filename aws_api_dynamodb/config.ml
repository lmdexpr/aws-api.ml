type t = { endpoint : Uri.t; region : string }

let aws ~region =
  { endpoint = Uri.of_string ("https://dynamodb." ^ region ^ ".amazonaws.com/"); region }

let local ?(endpoint = Uri.of_string "http://127.0.0.1:8000/") ?(region = "us-east-1") () =
  { endpoint; region }
