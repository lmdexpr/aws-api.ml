(** Typed attribute values <-> the generated [Aws_api_dynamodb.attribute_value] envelope, for
    calling [Aws_api_dynamodb] operations that [Client] does not wrap. No JSON here;
    [Aws_api_dynamodb] does that. *)

type attrs = Aws_api_dynamodb.attribute_value Aws_api_dynamodb.Wire.map

val of_item : Item.t -> attrs

val to_item : attrs -> Item.t
(** Raises [Of_yojson_error] with a path on an envelope with no tag, several tags, an invalid
    number, or an invalid set; inside [perform] that becomes [Error.deserialization]. *)

val items : attrs list option -> Item.t list
(** Absent lists read as empty. *)

val yojson_of_attrs : attrs -> Yojson.Safe.t

val attrs_of_yojson : Yojson.Safe.t -> attrs
(** The envelope as JSON, e.g. an item read out of a DynamoDB Streams record. *)
