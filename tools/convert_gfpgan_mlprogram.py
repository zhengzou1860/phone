# Batch-1 tracing and palettization approach adapted from tsyrenov1987/coreml-photo-restoration (MIT).
import argparse
import hashlib
import importlib
import json
import os
from pathlib import Path
import sys
import types

import numpy as np
import torch
from PIL import Image
from torch import nn
import torch.nn.functional as F

WEIGHTS_URL = "https://github.com/TencentARC/GFPGAN/releases/download/v1.3.0/GFPGANv1.4.pth"
UPSTREAM_COMMIT = "7552a7791caad982045a7bbe5634bbf1cd5c8679"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def package_bytes(path):
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def validate_prediction(model, example, reference, label):
    pixels = np.moveaxis(example[0].numpy(), 0, -1)
    pixels = np.ascontiguousarray(np.rint(pixels * 255.0), dtype=np.uint8)
    prediction = model.predict({"x_1": Image.fromarray(pixels)})["activation_out"]
    array = np.asarray(prediction)
    if array.shape == (1, 3, 512, 512):
        array = array[0]
    if array.shape == (3, 512, 512):
        array = np.moveaxis(array, 0, -1)
    if array.shape == (512, 512, 4):
        array = array[..., :3]
    if array.dtype != np.uint8:
        if float(array.max()) <= 1.0:
            array = array * 255.0
        array = np.ascontiguousarray(np.rint(array), dtype=np.uint8)
    reference_array = np.moveaxis(reference[0].numpy(), 0, -1) / 255.0
    mean_error = float(np.abs(array.astype(np.float32) / 255.0 - reference_array).mean())
    output_std = float(array.astype(np.float32).std() / 255.0)
    print(
        f"GFPGAN-{label} shape={array.shape} mean_error={mean_error:.6f} "
        f"std={output_std:.6f} range=[{array.min()},{array.max()}]"
    )
    if array.shape != (512, 512, 3) or mean_error > 0.08 or output_std < 0.03:
        raise RuntimeError(
            f"Core ML {label} output validation failed: shape={array.shape} "
            f"mean_error={mean_error} std={output_std}"
        )
    return {"meanAbsoluteError": mean_error, "outputStd": output_std}


def stub_basicsr():
    registry = types.ModuleType("basicsr.utils.registry")

    class Registry:
        def register(self, *args, **kwargs):
            def decorate(value):
                return value
            return decorate

    registry.ARCH_REGISTRY = Registry()
    arch_util = types.ModuleType("basicsr.archs.arch_util")
    arch_util.default_init_weights = lambda *args, **kwargs: None
    modules = {
        "basicsr": types.ModuleType("basicsr"),
        "basicsr.utils": types.ModuleType("basicsr.utils"),
        "basicsr.archs": types.ModuleType("basicsr.archs"),
        "basicsr.utils.registry": registry,
        "basicsr.archs.arch_util": arch_util,
    }
    sys.modules.update(modules)


def modulated_conv_forward(self, x, style):
    style = self.modulation(style).view(1, 1, self.in_channels, 1, 1)
    weight = self.weight * style
    if self.demodulate:
        demod = torch.rsqrt(weight.pow(2).sum([2, 3, 4]) + self.eps)
        weight = weight * demod.view(1, self.out_channels, 1, 1, 1)
    weight = weight.view(self.out_channels, self.in_channels, self.kernel_size, self.kernel_size)
    if self.sample_mode == "upsample":
        x = F.interpolate(x, scale_factor=2, mode="bilinear", align_corners=False)
    elif self.sample_mode == "downsample":
        x = F.interpolate(x, scale_factor=0.5, mode="bilinear", align_corners=False)
    return F.conv2d(x, weight, padding=self.padding)


class Restore(nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, x):
        x = x * 2.0 - 1.0
        out = self.net(x, return_rgb=False, randomize_noise=False)[0]
        return (out.clamp(-1.0, 1.0) + 1.0) * 127.5


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()

    torch.set_num_threads(4)
    stub_basicsr()
    sys.path.insert(0, str(args.upstream))
    gfpgan_package = types.ModuleType("gfpgan")
    gfpgan_package.__path__ = [str(args.upstream / "gfpgan")]
    arch_package = types.ModuleType("gfpgan.archs")
    arch_package.__path__ = [str(args.upstream / "gfpgan" / "archs")]
    sys.modules["gfpgan"] = gfpgan_package
    sys.modules["gfpgan.archs"] = arch_package
    architecture = importlib.import_module("gfpgan.archs.gfpganv1_clean_arch")
    stylegan = importlib.import_module("gfpgan.archs.stylegan2_clean_arch")

    net = architecture.GFPGANv1Clean(
        out_size=512,
        num_style_feat=512,
        channel_multiplier=2,
        decoder_load_path=None,
        fix_decoder=False,
        num_mlp=8,
        input_is_latent=True,
        different_w=True,
        narrow=1,
        sft_half=True,
    )
    checkpoint = torch.load(args.weights, map_location="cpu", weights_only=True)
    state = checkpoint.get("params_ema", checkpoint.get("params", checkpoint))
    missing, unexpected = net.load_state_dict(state, strict=False)
    if len(missing) > 10:
        raise RuntimeError(f"architecture mismatch: {missing[:8]}")
    model = Restore(net).eval()

    example = torch.rand(1, 3, 512, 512)
    with torch.no_grad():
        reference = model(example)
        stylegan.ModulatedConv2d.forward = modulated_conv_forward
        patched = model(example)
    patch_delta = (reference - patched).abs().max().item()
    if patch_delta >= 1e-3:
        raise RuntimeError(f"modulated convolution patch changed output: {patch_delta}")
    traced = torch.jit.trace(model, example, check_trace=False)

    import coremltools as ct

    converted = ct.convert(
        traced,
        inputs=[ct.ImageType(name="x_1", shape=(1, 3, 512, 512), scale=1.0 / 255.0,
                             bias=[0, 0, 0], color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="activation_out")],
        minimum_deployment_target=ct.target.iOS18,
        convert_to="mlprogram",
        compute_units=ct.ComputeUnit.CPU_AND_GPU,
        compute_precision=ct.precision.FLOAT32,
    )
    converted.author = "TencentARC/GFPGAN"
    converted.license = "Apache-2.0"
    converted.short_description = "GFPGAN v1.4 aligned 512px face restoration, FP32 compute with 6-bit weights"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    unquantized_output = args.output.parent / "gfpgan-unquantized.mlpackage"
    converted.save(str(unquantized_output))
    unquantized_model = ct.models.MLModel(str(unquantized_output), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    unquantized_metrics = validate_prediction(unquantized_model, example, reference, "UNQUANTIZED")

    import coremltools.optimize.coreml as optimize

    quantized = optimize.palettize_weights(
        converted,
        config=optimize.OptimizationConfig(
            global_config=optimize.OpPalettizerConfig(nbits=6, mode="kmeans")
        ),
    )
    quantized.author = converted.author
    quantized.license = converted.license
    quantized.short_description = converted.short_description
    quantized.save(str(args.output))

    runtime_model = ct.models.MLModel(str(args.output), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    quantized_metrics = validate_prediction(runtime_model, example, reference, "PAL6")

    spec = ct.models.utils.load_spec(str(args.output))
    manifest = {
        "model": "GFPGAN v1.4",
        "format": "mlprogram-fp32-weights-pal6",
        "bytes": package_bytes(args.output),
        "sha256": sha256(args.weights),
        "weightsBytes": args.weights.stat().st_size,
        "weightsURL": WEIGHTS_URL,
        "upstreamCommit": UPSTREAM_COMMIT,
        "source": "https://github.com/TencentARC/GFPGAN",
        "conversion": "https://github.com/tsyrenov1987/coreml-photo-restoration",
        "license": "Apache-2.0",
        "specificationVersion": spec.specificationVersion,
        "modelType": spec.WhichOneof("Type"),
        "inputs": [{"name": item.name, "kind": item.type.WhichOneof("Type")} for item in spec.description.input],
        "outputs": [{"name": item.name, "kind": item.type.WhichOneof("Type")} for item in spec.description.output],
        "patchMaxDelta": patch_delta,
        "unquantizedValidation": unquantized_metrics,
        "palettizedValidation": quantized_metrics,
    }
    args.manifest.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print("GFPGAN-MLPROGRAM " + json.dumps(manifest, ensure_ascii=False))
    print("GFPGAN-CONVERT-VERDICT PASS")


if __name__ == "__main__":
    main()
