type t = { status : int; headers : (string * string) list; body : string }

let header name t = Aws_api.Http.header name t.headers
