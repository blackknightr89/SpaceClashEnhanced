#!/usr/bin/env python3
"""upscale-videos.py — escala con IA los vídeos de Space Clash de TU copia del juego.

Genera un "máster" por vídeo (1280x960, 4:3, audio original copiado) en <root>/videos-hd/. Los
instaladores lo detectan y lo usan en lugar de los MPG de 320x240 al adaptar los vídeos a la pantalla
(--videos fit). Nada de esto se distribuye: se genera en tu máquina a partir de tu CD.

Requisitos: Python 3.10+, ffmpeg en el PATH, PyTorch (con CUDA para que sea rápido) y spandrel:
    pip install torch spandrel numpy
Tiempo orientativo (RTX 3050 6 GB): modelo "general" ≈ 10 min para los 7 vídeos; "x4plus" ≈ 2 h.

Uso:
    python3 tools/upscale-videos.py                      # instalación en ~/Games/space-clash
    python3 tools/upscale-videos.py --root DIR --model x4plus
    py tools\\upscale-videos.py --root C:\\Games\\SpaceClash   (Windows)
Después, reinstalar (o simplemente volver a abrir el juego) para que se regeneren los vídeos.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

VIDEOS = {  # nombre → SHA-256 del MPG original del CD (edición española)
    "LOGO.MPG": "73b260e5f9c53d198d3872719b86c99d58059fa01224cce937bcd660af97306d",
    "DINAMIC.MPG": "18d721c17d4f0f3cfab163ccf2255500427ce0ee9441ad97be632cdbe9d6e794",
    "INTRO.MPG": "21ccc54cf26092b1fc9af45ea764f3d0e356fb993715ebc25a45b5225a577955",
    "FINAL00.MPG": "9d961881d5a076c6d1899e626b9ca519630aad6c7c2aea64f44f2b58493e5774",
    "FINAL01.MPG": "35286ae006a543096b6ee1e2bb2b17990680152703a3d790861909396535a278",
    "FINAL02.MPG": "76b406415b48813c0a79e83596e83bcf1f2f4e7f05a73954503a1d1a31e1ac37",
    "FINAL03.MPG": "13a2dd30aa8547d0560cc24fdc6ed87b3468310779c86146835cc2dabb8df983",
}

REL = "https://github.com/xinntao/Real-ESRGAN/releases/download"
WEIGHTS = {  # archivo → (URL, SHA-256)
    "realesr-general-x4v3.pth": (f"{REL}/v0.2.5.0/realesr-general-x4v3.pth",
                                 "8dc7edb9ac80ccdc30c3a5dca6616509367f05fbc184ad95b731f05bece96292"),
    "realesr-general-wdn-x4v3.pth": (f"{REL}/v0.2.5.0/realesr-general-wdn-x4v3.pth",
                                     "1641f8c4464b9f097c9fdda5589273713f67cf59f3d909e0bd688f0cee269dca"),
    "RealESRGAN_x4plus.pth": (f"{REL}/v0.1.0/RealESRGAN_x4plus.pth",
                              "4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1"),
}
# Comparativa en docs/VIDEOS.md §6.7. "general": realesr-general-x4v3 con la reducción de ruido a medias
# (interpolación de pesos con la variante wdn): limpia el MPEG-1 sin borrar estrellas tenues ni inventar
# texturas. "x4plus": más nítido en bordes y texturas, pero borra detalle fino y es ~12 veces más lento.
MODELS = {
    "general": ("realesr-general-x4v3.pth", "realesr-general-wdn-x4v3.pth", 0.5),
    "general-sharp": ("realesr-general-x4v3.pth", None, 1.0),
    "x4plus": ("RealESRGAN_x4plus.pth", None, 1.0),
}
MASTER_VERSION = 1  # subir si cambian los parámetros de salida (videos-fit.sh compara el manifiesto)


def die(msg):
    print(f"upscale-videos: {msg}", file=sys.stderr)
    sys.exit(1)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch_weights(name, cache):
    url, digest = WEIGHTS[name]
    dest = cache / name
    if dest.exists() and sha256(dest) == digest:
        return dest
    cache.mkdir(parents=True, exist_ok=True)
    print(f"Descargando {name}…")
    tmp = dest.with_suffix(".part")
    urllib.request.urlretrieve(url, tmp)
    if sha256(tmp) != digest:
        tmp.unlink()
        die(f"el SHA-256 de {name} no coincide; descarga corrupta o modificada")
    tmp.replace(dest)
    return dest


def find_sources(root):
    """Originales de 320x240: cd/VIDEOS/ORIG (si videos-fit ya los adaptó) o cd/VIDEOS."""
    for d in (root / "cd" / "VIDEOS" / "ORIG", root / "cd" / "VIDEOS"):
        if all((d / n).is_file() for n in VIDEOS):
            break
    else:
        die(f"no encuentro los 7 vídeos originales en {root}/cd/VIDEOS[/ORIG] (¿--root correcto?)")
    for n, digest in VIDEOS.items():
        if sha256(d / n) != digest:
            if d.name == "VIDEOS":
                die(f"{d / n} no es el original (¿ya adaptado a la pantalla y sin ORIG/?). "
                    "Reinstalá con --force o usá --input con la carpeta VIDEOS del CD.")
            print(f"aviso: {n} no coincide con el del CD conocido; se usa igual", file=sys.stderr)
    return d


def probe(path):
    out = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
                                   "-show_entries", "stream=width,height", "-of", "json", str(path)])
    s = json.loads(out)["streams"][0]
    return s["width"], s["height"]


def count_frames(path):
    out = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames",
                                   "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", str(path)])
    return int(out.strip().split(b",")[0])


def load_model(spec, cache, torch, device):
    from spandrel import ModelLoader
    main, mix_with, mix = MODELS[spec]
    desc = ModelLoader().load_from_file(str(fetch_weights(main, cache)))
    if mix_with:  # interpolación de pesos: fuerza de la reducción de ruido
        other = ModelLoader().load_from_file(str(fetch_weights(mix_with, cache)))
        a, b = desc.model.state_dict(), other.model.state_dict()
        desc.model.load_state_dict({k: mix * a[k] + (1 - mix) * b[k] for k in a})
    model = desc.model.to(device).eval()
    half = device.type == "cuda"
    return (model.half() if half else model), desc.scale, half


def upscale(src, dst, model, scale, half, torch, np, lossless, batch):
    w, h = probe(src)
    expected = count_frames(src)
    fs = w * h * 3
    # -fps_mode passthrough: un fotograma de salida por cada fotograma decodificado (sin duplicar/eliminar)
    dec = subprocess.Popen(["ffmpeg", "-nostdin", "-v", "error", "-i", str(src), "-an", "-fps_mode", "passthrough",
                            "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
    vcodec = (["-c:v", "ffv1", "-level", "3", "-pix_fmt", "yuv444p"] if lossless else
              ["-c:v", "libx264", "-crf", "12", "-preset", "slow", "-pix_fmt", "yuv420p"])
    part = dst.with_name(dst.stem + ".part.mkv")
    # Vídeo y audio empiezan en el mismo instante en los 7 MPG: copiar el audio conserva la sincronía.
    enc = subprocess.Popen(["ffmpeg", "-nostdin", "-v", "error", "-y",
                            "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w * scale}x{h * scale}",
                            "-r", "25", "-i", "-", "-i", str(src),
                            "-map", "0:v", "-map", "1:a", *vcodec, "-c:a", "copy", str(part)],
                           stdin=subprocess.PIPE)
    n, t0 = 0, time.time()
    with torch.inference_mode():
        while True:
            frames = [dec.stdout.read(fs) for _ in range(batch)]
            frames = [f for f in frames if len(f) == fs]
            if not frames:
                break
            x = torch.from_numpy(np.stack([np.frombuffer(f, np.uint8).reshape(h, w, 3) for f in frames]))
            x = x.to(next(model.parameters()).device).permute(0, 3, 1, 2)
            x = (x.half() if half else x.float()) / 255
            y = model(x).clamp_(0, 1).mul_(255).round_().byte().permute(0, 2, 3, 1).cpu().numpy()
            enc.stdin.write(y.tobytes())
            n += len(frames)
            el = time.time() - t0
            print(f"\r  {src.name}: {n}/{expected} fotogramas ({n / el:.1f} fps)", end="", flush=True)
    enc.stdin.close()
    if enc.wait() or dec.wait():
        die(f"ffmpeg falló con {src.name}")
    print()
    got = count_frames(part)
    if got != expected:
        die(f"{src.name}: {got} fotogramas en el máster y {expected} en el original")
    part.replace(dst)
    return expected, time.time() - t0


def main():
    ap = argparse.ArgumentParser(description="Escala con IA los vídeos de Space Clash (ver el encabezado).")
    ap.add_argument("--root", type=Path, default=Path.home() / "Games" / "space-clash",
                    help="instalación del juego (def: ~/Games/space-clash)")
    ap.add_argument("--input", type=Path, help="carpeta con los MPG originales (def: <root>/cd/VIDEOS[/ORIG])")
    ap.add_argument("--output", type=Path, help="carpeta del máster (def: <root>/videos-hd)")
    ap.add_argument("--model", choices=MODELS, default="general")
    ap.add_argument("--lossless", action="store_true", help="máster FFV1 sin pérdida (~12 GB en vez de ~1,5 GB)")
    ap.add_argument("--only", help="solo estos vídeos, separados por coma (p. ej. LOGO,INTRO)")
    ap.add_argument("--batch", type=int, default=4, help="fotogramas por lote en la GPU (bajar si falta VRAM)")
    ap.add_argument("--cpu", action="store_true", help="forzar CPU (muy lento)")
    a = ap.parse_args()

    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            die(f"falta {tool} en el PATH")
    try:
        import numpy as np
        import torch
        import spandrel  # noqa: F401
    except ImportError as e:
        die(f"falta un módulo de Python ({e.name}). Instalá: pip install torch spandrel numpy")

    src_dir = a.input or find_sources(a.root)
    out = a.output or a.root / "videos-hd"
    out.mkdir(parents=True, exist_ok=True)
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "spaceclash" / "models"
    device = torch.device("cuda" if torch.cuda.is_available() and not a.cpu else "cpu")
    if device.type == "cpu":
        print("aviso: sin GPU CUDA; en CPU puede tardar muchas horas", file=sys.stderr)
    model, scale, half = load_model(a.model, cache, torch, device)

    manifest_path = out / "manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    params = {"version": MASTER_VERSION, "model": a.model, "lossless": a.lossless, "scale": scale}
    if {k: manifest.get(k) for k in params} != params:
        manifest = {**params, "videos": {}}  # parámetros distintos: se rehace todo
    names = [n if n.upper().endswith(".MPG") else n.upper() + ".MPG"
             for n in a.only.split(",")] if a.only else list(VIDEOS)
    print(f"Modelo: {a.model} (x{scale}) en {device.type}; salida: {out}")
    for name in names:
        if name not in VIDEOS:
            die(f"vídeo desconocido: {name}")
        dst = out / (Path(name).stem + ".mkv")
        src = src_dir / name
        if manifest["videos"].get(name, {}).get("source_sha256") == VIDEOS[name] and dst.exists():
            print(f"  {name}: ya está")
            continue
        frames, secs = upscale(src, dst, model, scale, half, torch, np, a.lossless, a.batch)
        manifest["videos"][name] = {"frames": frames, "seconds": round(secs, 1), "source_sha256": VIDEOS[name]}
        manifest_path.write_text(json.dumps(manifest, indent=2))
    manifest.update(torch=torch.__version__, spandrel=spandrel.__version__)
    manifest_path.write_text(json.dumps(manifest, indent=2))
    print("Listo. Volvé a abrir el juego (o reinstalá) para que los vídeos se regeneren con el máster.")


if __name__ == "__main__":
    main()
