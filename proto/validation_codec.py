import struct, io

WIRE_VARINT = 0
WIRE_LEN    = 2

def _encode_varint(value):
    buf = []
    while value > 0x7F:
        buf.append((value & 0x7F) | 0x80)
        value >>= 7
    buf.append(value & 0x7F)
    return bytes(buf)

def _encode_tag(field_number, wire_type):
    return _encode_varint((field_number << 3) | wire_type)

def _encode_string(field_number, value):
    if not value:
        return b""
    encoded = value.encode("utf-8")
    return _encode_tag(field_number, WIRE_LEN) + _encode_varint(len(encoded)) + encoded

def _encode_int64(field_number, value):
    if value == 0:
        return b""
    return _encode_tag(field_number, WIRE_VARINT) + _encode_varint(value)

def _encode_embedded(field_number, data):
    return _encode_tag(field_number, WIRE_LEN) + _encode_varint(len(data)) + data

def _decode_varint(stream):
    result = 0
    shift = 0
    while True:
        b = stream.read(1)
        if not b:
            raise EOFError
        byte = b[0]
        result |= (byte & 0x7F) << shift
        if (byte & 0x80) == 0:
            return result
        shift += 7

def _decode_tag(stream):
    v = _decode_varint(stream)
    return v >> 3, v & 0x07

def _read_length_delimited(stream):
    length = _decode_varint(stream)
    return stream.read(length)


def encode_event(event: dict) -> bytes:
    parts = []
    parts.append(_encode_string(1, event.get("validation_id", "")))
    parts.append(_encode_string(2, event.get("equipment_id", "")))
    parts.append(_encode_string(3, event.get("station_id", "")))
    parts.append(_encode_string(4, event.get("ligne_id", "")))
    parts.append(_encode_int64(5, event.get("timestamp_ms", 0)))
    parts.append(_encode_string(6, event.get("media_type", "")))
    parts.append(_encode_string(7, event.get("result", "")))
    parts.append(_encode_string(8, event.get("channel", "")))
    parts.append(_encode_string(9, event.get("equipment_type", "")))
    return b"".join(parts)


def encode_batch(sd_id: str, batch_id: str, generated_at_ms: int, events: list[dict]) -> bytes:
    parts = []
    parts.append(_encode_string(1, sd_id))
    parts.append(_encode_string(2, batch_id))
    parts.append(_encode_int64(3, generated_at_ms))
    for ev in events:
        ev_bytes = encode_event(ev)
        parts.append(_encode_embedded(4, ev_bytes))
    return b"".join(parts)


def decode_event(data: bytes) -> dict:
    stream = io.BytesIO(data)
    fields = {
        1: "validation_id", 2: "equipment_id", 3: "station_id",
        4: "ligne_id", 6: "media_type", 7: "result",
        8: "channel", 9: "equipment_type",
    }
    result = {}
    while stream.tell() < len(data):
        try:
            field_num, wire_type = _decode_tag(stream)
        except EOFError:
            break
        if wire_type == WIRE_VARINT:
            val = _decode_varint(stream)
            if field_num == 5:
                result["timestamp_ms"] = val
        elif wire_type == WIRE_LEN:
            val = _read_length_delimited(stream)
            if field_num in fields:
                result[fields[field_num]] = val.decode("utf-8")
        else:
            break
    return result


def decode_batch(data: bytes) -> dict:
    stream = io.BytesIO(data)
    batch = {"sd_id": "", "batch_id": "", "generated_at_ms": 0, "events": []}
    while stream.tell() < len(data):
        try:
            field_num, wire_type = _decode_tag(stream)
        except EOFError:
            break
        if wire_type == WIRE_VARINT:
            val = _decode_varint(stream)
            if field_num == 3:
                batch["generated_at_ms"] = val
        elif wire_type == WIRE_LEN:
            val = _read_length_delimited(stream)
            if field_num == 1:
                batch["sd_id"] = val.decode("utf-8")
            elif field_num == 2:
                batch["batch_id"] = val.decode("utf-8")
            elif field_num == 4:
                batch["events"].append(decode_event(val))
        else:
            break
    return batch
