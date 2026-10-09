(** Credential providers behind {!Sigv4.Provider}. A provider yields the raw credential fields
    ([Ok]) or a decline reason ([Error]); it never builds a [Sigv4.Credentials.t].

    This library performs no I/O: providers that need the file system or the network take the
    operation as an argument ([read_file], [http]). *)

type t

val v :
  ?name:string ->
  (unit -> (access_key:string * secret_key:string * session_token:string option, string) result) ->
  t
(** A provider from a thunk. [?name] prefixes its decline reason in {!chain} aggregation. *)

val run : t -> (access_key:string * secret_key:string * session_token:string option, string) result
(** Run a provider, prefixing its decline reason with its name. *)

val chain : t list -> t
(** First provider to resolve wins; if all decline, their reasons are aggregated. *)

(** Minimal HTTP for the providers that fetch credentials. [http] raises on transport failure; the
    provider turns that into a decline. *)
module Http : sig
  type request = { meth : [ `GET | `PUT ]; url : string; headers : (string * string) list }
  type response = { status : int; body : string }
end

(** Fixed credentials. *)
module Static : sig
  val make : access_key:string -> secret_key:string -> ?session_token:string -> unit -> t
end

(** Reads [AWS_ACCESS_KEY_ID] / [AWS_SECRET_ACCESS_KEY] (+ optional [AWS_SESSION_TOKEN]). [?getenv]
    defaults to [Sys.getenv_opt]. *)
module Env : sig
  val make : ?getenv:(string -> string option) -> unit -> t
end

(** Reads the shared credentials file ([AWS_SHARED_CREDENTIALS_FILE], default [~/.aws/credentials])
    then the config file ([AWS_CONFIG_FILE], default [~/.aws/config]) for the profile named by
    [AWS_PROFILE] (default [default]); in the config file the section is [profile <name>] except for
    [default]. The environment is read on every resolution. [read_file path] returns the contents or
    [None] when the file does not exist. Static keys only: [role_arn], [sso_*] and
    [credential_process] are not followed. *)
module Profile : sig
  val make : ?getenv:(string -> string option) -> read_file:(string -> string option) -> unit -> t

  val parse : string -> (string * (string * string) list) list
  (** INI sections to key/value pairs, section names verbatim. Exposed for tests. *)
end

(** Credentials from the AWS container endpoint ([AWS_CONTAINER_CREDENTIALS_RELATIVE_URI] /
    [_FULL_URI]). As the AWS SDKs, [_FULL_URI] must be [https], or [http] to a loopback or
    link-local agent address (169.254.170.2, 169.254.170.23, fd00:ec2::23). Sends the contents of
    [AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE] (read with [read_file]; unreadable is a decline) or
    else [AWS_CONTAINER_AUTHORIZATION_TOKEN] as [Authorization]. Declines when no variable is set,
    when the fetch fails or when the document is malformed; secrets never appear in decline reasons.

    Caching, shared with {!Imds}: the result is reused until 5 minutes before the reported expiry,
    or for 15 minutes when no expiry is reported; if a refresh fails, the previous credentials are
    served until they actually expire. [now] is UTC epoch seconds. Build once and reuse so the cache
    is shared. *)
module Ecs : sig
  val make :
    ?getenv:(string -> string option) ->
    ?read_file:(string -> string option) ->
    now:(unit -> float) ->
    http:(Http.request -> Http.response) ->
    unit ->
    t
end

(** Credentials from the EC2 instance metadata service (IMDSv2: session token, then the role's
    credentials). Caches and declines like {!Ecs}. Declines when [AWS_EC2_METADATA_DISABLED] is
    [true] or the service is unreachable. [AWS_EC2_METADATA_SERVICE_ENDPOINT] overrides the
    endpoint. *)
module Imds : sig
  val make :
    ?getenv:(string -> string option) ->
    now:(unit -> float) ->
    http:(Http.request -> Http.response) ->
    unit ->
    t
end

(** Internals exposed for tests. *)
module Fetched : sig
  val epoch_of_iso8601 : string -> float option
end

val default :
  ?getenv:(string -> string option) ->
  ?read_file:(string -> string option) ->
  now:(unit -> float) ->
  http:(Http.request -> Http.response) ->
  unit ->
  t
(** The default chain, in the order the AWS SDKs use: {!Env}, {!Profile}, {!Ecs}, {!Imds}.
    [read_file] defaults to reading from the file system. Build once and reuse so the caches are
    shared. *)
