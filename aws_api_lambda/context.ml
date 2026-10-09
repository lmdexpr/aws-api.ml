type t = {
  function_name : string;
  function_version : string;
  memory_size_mb : int;
  region : string;
  log_group_name : string option;
  log_stream_name : string option;
}

type parse_error =
  | Missing_variable of string
  | Invalid_variable of { name : string; value : string }

let parse_error_to_string = function
  | Missing_variable name -> Printf.sprintf "missing environment variable %s" name
  | Invalid_variable { name; value } ->
    Printf.sprintf "invalid environment variable %s: %S" name value

let function_name_var = "AWS_LAMBDA_FUNCTION_NAME"
let function_version_var = "AWS_LAMBDA_FUNCTION_VERSION"
let memory_size_var = "AWS_LAMBDA_FUNCTION_MEMORY_SIZE"
let region_var = "AWS_REGION"
let log_group_var = "AWS_LAMBDA_LOG_GROUP_NAME"
let log_stream_var = "AWS_LAMBDA_LOG_STREAM_NAME"

let of_env getenv =
  let open Result.Syntax in
  let required name = getenv name |> Option.to_result ~none:(Missing_variable name) in
  let* function_name = required function_name_var in
  let* function_version = required function_version_var in
  let* memory_size = required memory_size_var in
  let* memory_size_mb =
    int_of_string_opt memory_size
    |> Option.to_result ~none:(Invalid_variable { name = memory_size_var; value = memory_size })
  in
  let* region = required region_var in
  Ok
    {
      function_name;
      function_version;
      memory_size_mb;
      region;
      log_group_name = getenv log_group_var;
      log_stream_name = getenv log_stream_var;
    }
