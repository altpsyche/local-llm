"""
Record mic until silence, POST to whisper-server, print transcript.
Usage:
  python bob-voice-capture.py                    # record mic → transcript
  python bob-voice-capture.py --file <path>      # transcribe audio file
  python bob-voice-capture.py --port 8082 --silence-sec 1.5
Exit code 0 = success, 1 = error (server unreachable or no speech).
"""
import argparse
import io
import os
import sys
import tempfile
import wave

# Force UTF-8 stdout so whisper transcripts with non-ASCII chars print cleanly on Windows.
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

import numpy as np
import requests
import sounddevice as sd

SAMPLE_RATE = 16000  # whisper prefers 16 kHz
CHANNELS    = 1
DTYPE       = 'int16'
CHUNK_SECS  = 0.1    # RMS window size
RMS_SILENCE = 200    # amplitude threshold below = silence (tune if env is loud)


def record_until_silence(silence_sec: float) -> bytes:
    """Record mic until silence_sec of continuous silence. Return raw PCM bytes."""
    silence_chunks = int(silence_sec / CHUNK_SECS)
    chunk_samples  = int(SAMPLE_RATE * CHUNK_SECS)
    frames = []
    consecutive_silence = 0
    started = False

    print("Listening... (speak now, recording stops after silence)", file=sys.stderr)

    with sd.InputStream(samplerate=SAMPLE_RATE, channels=CHANNELS, dtype=DTYPE) as stream:
        while True:
            data, _ = stream.read(chunk_samples)
            rms = np.sqrt(np.mean(data.astype(np.float32) ** 2))

            if rms > RMS_SILENCE:
                started = True
                consecutive_silence = 0
                frames.append(data.copy())
            elif started:
                consecutive_silence += 1
                frames.append(data.copy())
                if consecutive_silence >= silence_chunks:
                    break
            # if not started yet, discard leading silence (don't record)

    if not frames:
        return b''
    return np.concatenate(frames, axis=0).tobytes()


def pcm_to_wav(pcm_bytes: bytes) -> bytes:
    """Wrap raw PCM bytes in a WAV container."""
    buf = io.BytesIO()
    with wave.open(buf, 'wb') as wf:
        wf.setnchannels(CHANNELS)
        wf.setsampwidth(2)  # 16-bit
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(pcm_bytes)
    return buf.getvalue()


def transcribe(wav_path: str, port: int) -> str:
    """POST a WAV file to whisper-server, return transcript text."""
    url = f"http://localhost:{port}/inference"
    with open(wav_path, 'rb') as f:
        try:
            resp = requests.post(
                url,
                files={'file': ('audio.wav', f, 'audio/wav')},
                data={'temperature': '0.0', 'response_format': 'json'},
                timeout=30,
            )
        except requests.exceptions.ConnectionError:
            print(f"Error: whisper-server not reachable at {url}. Run: bob up (or start-whisper.ps1)", file=sys.stderr)
            sys.exit(1)
    resp.raise_for_status()
    return resp.json().get('text', '').strip()


def main():
    parser = argparse.ArgumentParser(description='Mic capture + whisper transcription')
    parser.add_argument('--file',        help='Transcribe this audio file instead of mic')
    parser.add_argument('--port',        type=int, default=int(os.environ.get('BOB_STT_PORT', 8082)))
    parser.add_argument('--silence-sec', type=float, default=1.5, dest='silence_sec')
    args = parser.parse_args()

    if args.file:
        wav_path = args.file
        tmp_path = None
    else:
        pcm = record_until_silence(args.silence_sec)
        if not pcm:
            print("Error: no speech detected", file=sys.stderr)
            sys.exit(1)
        wav_bytes = pcm_to_wav(pcm)
        fd, tmp_path = tempfile.mkstemp(suffix='.wav')
        try:
            with os.fdopen(fd, 'wb') as f:
                f.write(wav_bytes)
            wav_path = tmp_path
        except Exception:
            os.close(fd)
            raise

    try:
        transcript = transcribe(wav_path, args.port)
    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)

    if not transcript:
        print("Error: empty transcript", file=sys.stderr)
        sys.exit(1)

    print(transcript)


if __name__ == '__main__':
    main()
