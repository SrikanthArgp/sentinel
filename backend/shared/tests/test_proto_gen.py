"""Guards against codegen drift: generated stubs must import cleanly and
their message fields must match the .proto source of truth field-for-field.
Catches a stale `proto_gen/` (edited .proto, forgot to rerun gen_proto.sh)
before any real handler code depends on the wrong shape.
"""

from __future__ import annotations

from pathlib import Path

from proto_gen import feature_store_pb2, scoring_pb2


def _fields_from_proto_source(proto_path: Path, message_name: str) -> list[str]:
    text = proto_path.read_text()
    start = text.index(f"message {message_name} {{")
    end = text.index("}", start)
    body = text[start:end]
    fields = []
    for line in body.splitlines():
        line = line.strip().rstrip(";")
        if not line or line.startswith("//"):
            continue
        # e.g. "string account_id = 1;" or "repeated string reasons = 4;"
        parts = line.split()
        if len(parts) >= 3 and parts[-2] == "=":
            fields.append(parts[-3])
    return fields


def test_feature_store_stubs_import():
    req = feature_store_pb2.GetFeaturesRequest(account_id="a1", merchant_id="m1")
    assert req.account_id == "a1"


def test_scoring_stubs_import():
    resp = scoring_pb2.ScoreTransactionResponse(
        transaction_id="t1", score=42, reasons=["velocity_exceeded"]
    )
    assert resp.reasons == ["velocity_exceeded"]


def test_feature_store_request_fields_match_proto_source():
    proto_path = (Path(__file__).resolve().parents[2] / "proto" / "feature_store.proto")
    expected = _fields_from_proto_source(proto_path, "GetFeaturesRequest")
    actual = [f.name for f in feature_store_pb2.GetFeaturesRequest.DESCRIPTOR.fields]
    assert actual == expected


def test_scoring_request_fields_match_proto_source():
    proto_path = Path(__file__).resolve().parents[2] / "proto" / "scoring.proto"
    expected = _fields_from_proto_source(proto_path, "ScoreTransactionRequest")
    actual = [f.name for f in scoring_pb2.ScoreTransactionRequest.DESCRIPTOR.fields]
    assert actual == expected


def test_scoring_response_fields_match_proto_source():
    proto_path = Path(__file__).resolve().parents[2] / "proto" / "scoring.proto"
    expected = _fields_from_proto_source(proto_path, "ScoreTransactionResponse")
    actual = [f.name for f in scoring_pb2.ScoreTransactionResponse.DESCRIPTOR.fields]
    assert actual == expected
