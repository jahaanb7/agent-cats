#!/usr/bin/env python3
"""Builds dist/agent-cats-reel.mp4: voiceover, scene timing, frames, chiptune bed, sound effects, mix.

Voice: macOS `say` (REEL_VOICE, default Samantha). To use a better voice (your own, ElevenLabs, …),
put one file per line in a folder named 0.wav … 7.wav (or .mp3/.m4a/.aiff) and set REEL_VO_DIR.
Only the standard library, ffmpeg and swiftc are needed.
"""
import json, os, shutil, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)

# (spoken line, on-screen caption). Each line opens a scene of the storyboard in Tools/Reel/main.swift.
LINES = [
    ("My AI agent waited forty-seven minutes for me to click yes.", "My AI agent waited 47 minutes for me to click YES"),
    ("So I turned them all into cats.", "So I turned them all into cats"),
    ("Every Claude Code session gets a cat in my menu bar.", "Every Claude Code session gets a cat in my menu bar"),
    ("When one needs me, it asks. In plain English.", "When one needs me, it asks in plain English"),
    ("One click. Back to work.", "One click. Back to work."),
    ("Questions? Answer right from the bubble.", "Questions? Answer right from the bubble"),
    ("Then it tells me what it actually got done.", "Then it tells me what it actually got done"),
    ("Agent Cats. Link in bio.", "Agent Cats. Link in bio."),
]
GAP = [0.3, 0.25, 0.25, 0.1, 0.25, 0.25, 0.25]      # pause after each line
MIN_SCENE = [2.4, 2.0, 2.5, 2.0, 1.4, 2.3, 2.6]     # room for the visuals to land
SR = 48000


def run(*cmd, **kw):
    subprocess.run([str(c) for c in cmd], check=True, **kw)


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                         check=True, capture_output=True, text=True).stdout
    return float(out.strip())


def synth(path, expr, dur, post=None):
    af = ["-af", post] if post else []
    run("ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"aevalsrc=exprs='{expr}':d={dur}:s={SR}", *af,
        "-ac", "1", path)


def voiceover(work):
    vo_dir = os.environ.get("REEL_VO_DIR")
    voice = os.environ.get("REEL_VOICE", "Samantha")
    clips = []
    for i, (spoken, _) in enumerate(LINES):
        raw = None
        if vo_dir:
            raw = next((p for p in (Path(vo_dir) / f"{i}{ext}" for ext in (".wav", ".mp3", ".m4a", ".aiff")) if p.exists()), None)
            if raw is None:
                sys.exit(f"REEL_VO_DIR is missing line {i}: {spoken!r}")
        else:
            raw = work / f"say{i}.aiff"
            run("say", "-v", voice, "-r", "185", "-o", raw, spoken)
        clip = work / f"vo{i}.wav"
        # Trim silence, tidy the low end, add presence and a little compression.
        run("ffmpeg", "-loglevel", "error", "-y", "-i", raw, "-af",
            "silenceremove=start_periods=1:start_threshold=-45dB,areverse,"
            "silenceremove=start_periods=1:start_threshold=-45dB,areverse,"
            "highpass=f=90,equalizer=f=3200:width_type=o:width=2:g=3,"
            "acompressor=threshold=-18dB:ratio=3:attack=5:release=80",
            "-ar", SR, "-ac", "1", clip)
        clips.append((clip, duration(clip)))
    return clips


def timeline(clips):
    lines, t = [], 0.15
    for i, ((_, cap), (_, d)) in enumerate(zip(LINES, clips)):
        lines.append({"caption": cap, "start": round(t, 3), "end": round(t + d, 3)})
        if i < len(GAP):
            t += max(d + GAP[i], MIN_SCENE[i])
    total = lines[-1]["start"] + max(clips[-1][1] + 1.3, 2.8)
    return {"lines": lines, "duration": round(total, 3)}


def sound_bank(work, tl):
    fx = {
        "pop": ("0.6*sin(2*PI*(380*t+3200*t*t))*exp(-28*t)", 0.15, None),
        "click": ("0.7*(random(0)*2-1)*exp(-260*t)+0.5*sin(2*PI*2400*t)*exp(-140*t)", 0.06, None),
        "whoosh": ("0.55*(random(0)*2-1)*pow(sin(PI*t/0.45),2)", 0.45, "highpass=f=500,lowpass=f=3500"),
        "poof": ("0.45*(random(0)*2-1)*exp(-14*t)+0.6*sin(2*PI*(170-220*t)*t)*exp(-11*t)", 0.32, "lowpass=f=2600"),
        "chime": ("0.3*(sin(2*PI*1318.5*t)+0.8*gte(t,0.09)*sin(2*PI*1975.5*t))*exp(-4.5*t)", 1.0, None),
        "alert": ("0.28*sin(2*PI*880*t)*(lt(t,0.07)+gte(t,0.12)*lt(t,0.19))", 0.22, None),
        # A synthesized "mrrow?": a gliding voice with harmonics.
        "meow": ("st(0,2*PI*(520*t+460*0.6/PI*(1-cos(PI*t/0.6))+6*sin(2*PI*7*t)/(2*PI*7)));"
                 "0.33*pow(sin(PI*t/0.6),0.7)*(sin(ld(0))+0.55*sin(2*ld(0))+0.3*sin(3*ld(0))+0.15*sin(4*ld(0)))",
                 0.6, "lowpass=f=3800,equalizer=f=1200:width_type=o:width=1.5:g=4"),
    }
    paths = {}
    for name, (expr, d, post) in fx.items():
        paths[name] = work / f"fx_{name}.wav"
        synth(paths[name], expr, d, post)

    # Tense clock ticks under the hook, then a chiptune loop (I–vi–IV–V at 120 bpm) from the poof.
    hook_end = tl["lines"][1]["start"] + 0.3
    synth(work / "ticks.wav", "0.35*(random(0)*2-1)*exp(-320*mod(t,0.25))", round(hook_end, 3), "highpass=f=2500")
    music_len = round(tl["duration"] - hook_end, 3)
    root = "st(1,-3*eq(mod(floor(t/2),4),1)-7*eq(mod(floor(t/2),4),2)-5*eq(mod(floor(t/2),4),3));"
    third = "st(2,4-eq(mod(floor(t/2),4),1));"
    step = "st(3,mod(floor(t*8),8));"
    arp = "st(4,ld(1)+ld(2)*(eq(ld(3),1)+eq(ld(3),5))+7*(eq(ld(3),2)+eq(ld(3),4)+eq(ld(3),7))+12*eq(ld(3),3));"
    lead = "0.16*sgn(sin(2*PI*523.25*pow(2,ld(4)/12)*t))*exp(-9*mod(t,0.125))"
    bass = "0.32*(sin(2*PI*130.81*pow(2,ld(1)/12)*t)+0.3*sin(4*PI*130.81*pow(2,ld(1)/12)*t))*exp(-3*mod(t,0.5))"
    kick = "0.5*sin(2*PI*(48+110*exp(-28*mod(t,0.5)))*mod(t,0.5))*exp(-10*mod(t,0.5))"
    hat = "0.08*(random(0)*2-1)*exp(-70*mod(t+0.25,0.5))"
    synth(work / "music.wav", root + third + step + arp + f"{lead}+{bass}+{kick}+{hat}", music_len,
          f"lowpass=f=5000,afade=t=in:d=0.05,afade=t=out:st={max(0, music_len - 0.8)}:d=0.8")
    return paths, hook_end


def mix(work, clips, tl, cues, paths, hook_end):
    inputs, chains, vo_labels, fx_labels = [], [], [], []
    def add(path):
        inputs.extend(["-i", str(path)]); return len(inputs) // 2 - 1
    for i, (clip, _) in enumerate(clips):
        ms = int(tl["lines"][i]["start"] * 1000)
        k = add(clip); chains.append(f"[{k}]adelay={ms}|{ms}[v{i}]"); vo_labels.append(f"[v{i}]")
    for j, c in enumerate(cues):
        ms = int(c["t"] * 1000)
        k = add(paths[c["name"]]); chains.append(f"[{k}]volume={c['gain'] * 0.8:.2f},adelay={ms}|{ms}[f{j}]"); fx_labels.append(f"[f{j}]")
    k = add(work / "ticks.wav"); fx_labels.append(f"[{k}]")
    km = add(work / "music.wav")
    dms = int(hook_end * 1000)
    chains += [
        f"{''.join(vo_labels)}amix=inputs={len(vo_labels)}:normalize=0,asplit[vo][key]",
        f"[{km}]volume=0.55,adelay={dms}|{dms}[mus]",
        "[mus][key]sidechaincompress=threshold=0.02:ratio=8:attack=15:release=350:makeup=1[bed]",
        f"{''.join(fx_labels)}amix=inputs={len(fx_labels)}:normalize=0[fx]",
        f"[vo][bed][fx]amix=inputs=3:normalize=0,atrim=0:{tl['duration']},loudnorm=I=-14:TP=-1.5:LRA=11[out]",
    ]
    out = work / "mix.m4a"
    run("ffmpeg", "-loglevel", "error", "-y", *inputs, "-filter_complex", ";".join(chains), "-map", "[out]",
        "-ar", SR, "-c:a", "aac", "-b:a", "192k", out)
    return out


def main():
    for tool in ("ffmpeg", "ffprobe", "swiftc", "say"):
        if not shutil.which(tool):
            sys.exit(f"{tool} is required (ffmpeg: brew install ffmpeg)")
    work = Path(tempfile.mkdtemp(prefix="agentcats-reel."))
    try:
        print("1/5 voiceover"); clips = voiceover(work)
        tl = timeline(clips); (work / "timeline.json").write_text(json.dumps(tl, indent=2))
        print(f"    {tl['duration']:.1f}s, lines at " + ", ".join(f"{l['start']:.1f}" for l in tl["lines"]))
        print("2/5 compiling renderer")
        app_sources = [p for p in sorted(Path("Sources/App").glob("*.swift")) if p.name != "main.swift"]
        run("swiftc", "-O", "-swift-version", "5", "-target", "arm64-apple-macos14", "-o", work / "reel",
            *sorted(Path("Sources/Shared").glob("*.swift")), *sorted(Path("Sources/Core").glob("*.swift")),
            *app_sources, "Tools/Reel/main.swift")
        print("3/5 rendering frames"); run(work / "reel", work / "timeline.json", work / "frames")
        cues = json.loads((work / "frames" / "sfx.json").read_text())
        print("4/5 music, sound effects, mix"); paths, hook_end = sound_bank(work, tl)
        audio = mix(work, clips, tl, cues, paths, hook_end)
        print("5/5 encoding")
        Path("dist").mkdir(exist_ok=True)
        run("ffmpeg", "-loglevel", "error", "-y", "-framerate", "30", "-i", work / "frames" / "f%04d.png", "-i", audio,
            "-c:v", "libx264", "-preset", "slow", "-crf", "17", "-pix_fmt", "yuv420p", "-c:a", "copy", "-shortest",
            "-movflags", "+faststart", "dist/agent-cats-reel.mp4")
        if os.environ.get("REEL_KEEP"):
            print(f"kept work files in {work}")
        print("dist/agent-cats-reel.mp4")
    finally:
        if not os.environ.get("REEL_KEEP"):
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
