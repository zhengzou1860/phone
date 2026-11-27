import argparse
import hashlib
import json
from pathlib import Path

import coremltools as ct
import gdown

FILE_ID = "1-3fF4aPnh8ygUOmKItIrZ318xI9JGmQx"
EXPECTED_BYTES = 337_392_296
SOURCE_URL = "https://github.com/john-rocky/CoreML-Models"
UPSTREAM_URL = "https://github.com/TencentARC/GFPGAN"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def feature_record(feature, direction):
    feature_type = feature.type
    kind = feature_type.WhichOneof("Type")
    record = {"name": feature.name, "direction": direction, "kind": kind}
    if kind == "imageType":
        image = feature_type.imageType
        record.update(
            width=image.width,
            height=image.height,
            colorSpace=image.colorSpace,
        )
    elif kind == "multiArrayType":
        array = feature_type.multiArrayType
        record.update(
            shape=list(array.shape),
            dataType=array.dataType,
        )
    return record


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()

    downloaded = gdown.download(id=FILE_ID, output=str(args.output), quiet=False)
    if not downloaded:
        raise RuntimeError("GFPGAN download failed")
    output = Path(downloaded)
    actual_bytes = output.stat().st_size
    if actual_bytes != EXPECTED_BYTES:
        raise RuntimeError(f"unexpected model size: {actual_bytes}")

    actual_hash = sha256(output)
    spec = ct.models.utils.load_spec(str(output))
    inputs = [feature_record(item, "input") for item in spec.description.input]
    outputs = [feature_record(item, "output") for item in spec.description.output]
    if len(inputs) != 1 or len(outputs) != 1:
        raise RuntimeError(f"unexpected feature count: {len(inputs)} inputs, {len(outputs)} outputs")
    for feature in inputs + outputs:
        if feature["kind"] != "imageType" or feature.get("width") != 512 or feature.get("height") != 512:
            raise RuntimeError(f"unexpected GFPGAN image interface: {feature}")

    manifest = {
        "file": output.name,
        "bytes": actual_bytes,
        "sha256": actual_hash,
        "source": SOURCE_URL,
        "upstream": UPSTREAM_URL,
        "license": "Apache-2.0",
        "specificationVersion": spec.specificationVersion,
        "modelType": spec.WhichOneof("Type"),
        "inputs": inputs,
        "outputs": outputs,
    }
    args.manifest.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"GFPGAN-MODEL bytes={actual_bytes} sha256={actual_hash} type={manifest['modelType']}")
    for feature in inputs + outputs:
        print("GFPGAN-IO " + json.dumps(feature, ensure_ascii=False))
    print("GFPGAN-INSPECT-VERDICT PASS")


if __name__ == "__main__":
    main()
