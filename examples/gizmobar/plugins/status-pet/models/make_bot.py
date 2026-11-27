#!/usr/bin/env python3
"""Builds gizmo-bot.glb: a small boxy robot with eight clips (idle, dance,
run, sleep, wave, charge, dance-charging, happy) for the status-pet example. The plug,
cable and chest light rest at zero scale and only show while charging. Run: python3 make_bot.py"""
import json, math, struct

bin_ = bytearray()
views, accessors = [], []


def add(data, fmt, count, type_, ctype, minmax=None, target=None):
    while len(bin_) % 4:
        bin_.append(0)
    off = len(bin_)
    bin_.extend(struct.pack("<" + fmt * len(data), *data))
    v = {"buffer": 0, "byteOffset": off, "byteLength": len(bin_) - off}
    if target:
        v["target"] = target
    views.append(v)
    a = {"bufferView": len(views) - 1, "componentType": ctype, "count": count, "type": type_}
    if minmax:
        a["min"], a["max"] = minmax
    accessors.append(a)
    return len(accessors) - 1


def box(sx, sy, sz):
    hx, hy, hz = sx / 2, sy / 2, sz / 2
    faces = [((1, 0, 0), [(hx, -hy, -hz), (hx, hy, -hz), (hx, hy, hz), (hx, -hy, hz)]),
             ((-1, 0, 0), [(-hx, -hy, hz), (-hx, hy, hz), (-hx, hy, -hz), (-hx, -hy, -hz)]),
             ((0, 1, 0), [(-hx, hy, -hz), (-hx, hy, hz), (hx, hy, hz), (hx, hy, -hz)]),
             ((0, -1, 0), [(-hx, -hy, hz), (-hx, -hy, -hz), (hx, -hy, -hz), (hx, -hy, hz)]),
             ((0, 0, 1), [(-hx, -hy, hz), (hx, -hy, hz), (hx, hy, hz), (-hx, hy, hz)]),
             ((0, 0, -1), [(hx, -hy, -hz), (-hx, -hy, -hz), (-hx, hy, -hz), (hx, hy, -hz)])]
    pos, nor, idx = [], [], []
    for n, quad in faces:
        b = len(pos) // 3
        for p in quad:
            pos += p
            nor += n
        idx += [b, b + 1, b + 2, b, b + 2, b + 3]
    p = add(pos, "f", 24, "VEC3", 5126, ([-hx, -hy, -hz], [hx, hy, hz]), 34962)
    n = add(nor, "f", 24, "VEC3", 5126, target=34962)
    i = add(idx, "H", 36, "SCALAR", 5123, target=34963)
    return p, n, i


materials = [
    {"name": "Shell", "pbrMetallicRoughness": {"baseColorFactor": [0.43, 0.54, 1.0, 1], "metallicFactor": 0.1, "roughnessFactor": 0.5}},
    {"name": "Face", "pbrMetallicRoughness": {"baseColorFactor": [0.9, 0.96, 1.0, 1], "metallicFactor": 0, "roughnessFactor": 0.6}},
    {"name": "Ink", "pbrMetallicRoughness": {"baseColorFactor": [0.05, 0.02, 0.2, 1], "metallicFactor": 0, "roughnessFactor": 0.4}},
    {"name": "Glow", "pbrMetallicRoughness": {"baseColorFactor": [0.72, 0.49, 1.0, 1], "metallicFactor": 0}, "emissiveFactor": [0.4, 0.2, 0.6]},
    {"name": "Charge", "pbrMetallicRoughness": {"baseColorFactor": [0.65, 0.89, 0.63, 1], "metallicFactor": 0}, "emissiveFactor": [0.3, 0.7, 0.3]},
    {"name": "Cord", "pbrMetallicRoughness": {"baseColorFactor": [0.42, 0.44, 0.53, 1], "metallicFactor": 0.2, "roughnessFactor": 0.6}},
]
meshes = []


def mesh(name, size, mat):
    p, n, i = box(*size)
    meshes.append({"name": name, "primitives": [{"attributes": {"POSITION": p, "NORMAL": n}, "indices": i, "material": mat}]})
    return len(meshes) - 1


nodes = [
    {"name": "Root", "children": [1]},
    {"name": "Body", "mesh": mesh("Body", (0.5, 0.45, 0.35), 0), "translation": [0, 0.25, 0], "children": [2, 6, 7, 8, 9, 10, 11, 12]},
    {"name": "Head", "mesh": mesh("Head", (0.42, 0.32, 0.32), 1), "translation": [0, 0.42, 0], "children": [3, 4, 5]},
    {"name": "EyeL", "mesh": mesh("Eye", (0.07, 0.09, 0.02), 2), "translation": [-0.09, 0.02, 0.165]},
    {"name": "EyeR", "mesh": mesh("Eye", (0.07, 0.09, 0.02), 2), "translation": [0.09, 0.02, 0.165]},
    {"name": "Antenna", "mesh": mesh("Antenna", (0.06, 0.06, 0.06), 3), "translation": [0, 0.24, 0]},
    {"name": "ArmL", "mesh": mesh("Arm", (0.1, 0.32, 0.1), 0), "translation": [-0.32, -0.02, 0]},
    {"name": "ArmR", "mesh": mesh("Arm", (0.1, 0.32, 0.1), 0), "translation": [0.32, -0.02, 0]},
    {"name": "LegL", "mesh": mesh("Leg", (0.12, 0.18, 0.12), 2), "translation": [-0.12, -0.3, 0]},
    {"name": "LegR", "mesh": mesh("Leg", (0.12, 0.18, 0.12), 2), "translation": [0.12, -0.3, 0]},
    {"name": "ChestLight", "mesh": mesh("ChestLight", (0.12, 0.12, 0.02), 4), "translation": [0, 0.02, 0.18], "scale": [0, 0, 0]},
    {"name": "Plug", "mesh": mesh("Plug", (0.1, 0.1, 0.1), 5), "translation": [0, -0.05, -0.22], "scale": [0, 0, 0]},
    {"name": "Cable", "mesh": mesh("Cable", (0.5, 0.035, 0.035), 5), "translation": [0.26, -0.15, -0.22], "rotation": [0, 0, -0.2588, 0.9659], "scale": [0, 0, 0]},
]
N = {n["name"]: i for i, n in enumerate(nodes)}


def q(axis, deg):
    s = math.sin(math.radians(deg) / 2)
    return [axis[0] * s, axis[1] * s, axis[2] * s, math.cos(math.radians(deg) / 2)]


animations = []


def clip(name, tracks):
    samplers, channels = [], []
    for node, path, times, values in tracks:
        t = add(times, "f", len(times), "SCALAR", 5126, ([min(times)], [max(times)]))
        flat = [x for v in values for x in v]
        o = add(flat, "f", len(values), "VEC4" if path == "rotation" else "VEC3", 5126)
        samplers.append({"input": t, "output": o, "interpolation": "LINEAR"})
        channels.append({"sampler": len(samplers) - 1, "target": {"node": N[node], "path": path}})
    animations.append({"name": name, "samplers": samplers, "channels": channels})


def wave(times, f):
    return times, [f(t) for t in times]


def T(d, n):
    return [d * i / n for i in range(n + 1)]


S = math.sin
P = math.pi
clip("idle", [
    ("Body", "translation", *wave(T(2, 8), lambda t: [0, 0.25 + 0.02 * S(t * P), 0])),
    ("Head", "rotation", *wave(T(2, 8), lambda t: q((0, 1, 0), 8 * S(t * P)))),
])
dance = [
    ("Body", "rotation", *wave(T(1, 8), lambda t: q((0, 0, 1), 10 * S(t * 2 * P)))),
    ("Body", "translation", *wave(T(1, 8), lambda t: [0, 0.25 + 0.04 * abs(S(t * 2 * P)), 0])),
    ("ArmL", "rotation", *wave(T(1, 8), lambda t: q((0, 0, 1), -60 - 50 * S(t * 2 * P)))),
    ("ArmR", "rotation", *wave(T(1, 8), lambda t: q((0, 0, 1), 60 + 50 * S(t * 2 * P)))),
]
clip("dance", dance)
clip("run", [
    ("Body", "translation", *wave(T(0.4, 8), lambda t: [0, 0.25 + 0.05 * abs(S(t / 0.4 * 2 * P)), 0])),
    ("Body", "rotation", *wave(T(0.4, 8), lambda t: q((1, 0, 0), 12))),
    ("ArmL", "rotation", *wave(T(0.4, 8), lambda t: q((1, 0, 0), 45 * S(t / 0.4 * 2 * P)))),
    ("ArmR", "rotation", *wave(T(0.4, 8), lambda t: q((1, 0, 0), -45 * S(t / 0.4 * 2 * P)))),
    ("LegL", "rotation", *wave(T(0.4, 8), lambda t: q((1, 0, 0), -35 * S(t / 0.4 * 2 * P)))),
    ("LegR", "rotation", *wave(T(0.4, 8), lambda t: q((1, 0, 0), 35 * S(t / 0.4 * 2 * P)))),
])
clip("sleep", [
    ("Head", "rotation", *wave(T(3, 6), lambda t: q((1, 0, 0), 22 + 3 * S(t / 3 * 2 * P)))),
    ("Body", "translation", *wave(T(3, 6), lambda t: [0, 0.24 + 0.012 * S(t / 3 * 2 * P), 0])),
    ("Antenna", "scale", *wave(T(3, 6), lambda t: [0.6, 0.6, 0.6])),
])
clip("wave", [
    ("ArmR", "rotation", *wave(T(1.2, 12), lambda t: q((0, 0, 1), min(1, t / 0.25) * 150 + 20 * S(t * 4 * P)))),
    ("Head", "rotation", *wave(T(1.2, 12), lambda t: q((0, 0, 1), -8 * min(1, t / 0.25)))),
])
clip("charge", [
    # Sits down with the cable in its back; the chest light breathes.
    ("Body", "translation", *wave(T(2.4, 12), lambda t: [0, 0.2 + 0.008 * S(t / 2.4 * 2 * P), 0])),
    ("Body", "rotation", *wave(T(2.4, 2), lambda t: q((1, 0, 0), -8))),
    ("LegL", "rotation", *wave(T(2.4, 2), lambda t: q((1, 0, 0), -80))),
    ("LegR", "rotation", *wave(T(2.4, 2), lambda t: q((1, 0, 0), -80))),
    ("ArmL", "rotation", *wave(T(2.4, 2), lambda t: q((0, 0, 1), -12))),
    ("ArmR", "rotation", *wave(T(2.4, 2), lambda t: q((0, 0, 1), 12))),
    ("Head", "rotation", *wave(T(2.4, 12), lambda t: q((1, 0, 0), -6 + 3 * S(t / 2.4 * 2 * P)))),
    ("EyeL", "scale", *wave(T(2.4, 2), lambda t: [1, 0.45, 1])),
    ("EyeR", "scale", *wave(T(2.4, 2), lambda t: [1, 0.45, 1])),
    ("ChestLight", "scale", *wave(T(2.4, 12), lambda t: [0.8 + 0.25 * S(t / 2.4 * 2 * P)] * 3)),
    ("Plug", "scale", *wave(T(2.4, 2), lambda t: [1, 1, 1])),
    ("Cable", "scale", *wave(T(2.4, 2), lambda t: [1, 1, 1])),
])
# Dancing while plugged in: same moves, cable and chest light still on.
clip("dance-charging", dance + [
    ("ChestLight", "scale", *wave(T(1, 8), lambda t: [0.9 + 0.2 * abs(S(t * 2 * P))] * 3)),
    ("Plug", "scale", *wave(T(1, 2), lambda t: [1, 1, 1])),
    ("Cable", "scale", *wave(T(1, 2), lambda t: [1, 1, 1])),
])
clip("happy", [
    # Full and still plugged in: small hops with the arms up.
    ("Body", "translation", *wave(T(0.8, 8), lambda t: [0, 0.25 + 0.06 * abs(S(t / 0.8 * 2 * P)), 0])),
    ("ArmL", "rotation", *wave(T(0.8, 8), lambda t: q((0, 0, 1), -120 - 15 * S(t / 0.8 * 2 * P)))),
    ("ArmR", "rotation", *wave(T(0.8, 8), lambda t: q((0, 0, 1), 120 + 15 * S(t / 0.8 * 2 * P)))),
    ("EyeL", "scale", *wave(T(0.8, 2), lambda t: [1, 0.45, 1])),
    ("EyeR", "scale", *wave(T(0.8, 2), lambda t: [1, 0.45, 1])),
])

doc = {"asset": {"version": "2.0", "generator": "gizmobar make_bot.py"}, "scene": 0, "scenes": [{"nodes": [0]}],
       "nodes": nodes, "meshes": meshes, "materials": materials, "animations": animations,
       "buffers": [{"byteLength": 0}], "bufferViews": views, "accessors": accessors}
while len(bin_) % 4:
    bin_.append(0)
doc["buffers"][0]["byteLength"] = len(bin_)
j = json.dumps(doc, separators=(",", ":")).encode()
j += b" " * ((4 - len(j) % 4) % 4)
out = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(j) + 8 + len(bin_))
out += struct.pack("<II", len(j), 0x4E4F534A) + j + struct.pack("<II", len(bin_), 0x004E4942) + bytes(bin_)
open("gizmo-bot.glb", "wb").write(out)
print(f"gizmo-bot.glb: {len(out)} bytes, {len(meshes)} meshes, clips {[a['name'] for a in animations]}")
