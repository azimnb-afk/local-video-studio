"""Audio generation using MLX Audio for Apple Silicon."""

import sys
import json


def status_output(message: str):
    """Output status message for Swift to parse."""
    print(f"STATUS:{message}", file=sys.stderr)
    sys.stderr.flush()


def progress_output(percent: float, message: str):
    """Output progress for Swift to parse."""
    print(f"PROGRESS:{percent}:{message}", file=sys.stderr)
    sys.stderr.flush()


def generate_audio(
    text: str,
    voice: str = "af_heart",
    output_path: str = "output.wav",
    speed: float = 1.0,
    model_name: str = "mlx-community/Kokoro-82M-bf16",
) -> dict:
    """
    Generate audio from text using MLX Audio.

    Args:
        text: Text to convert to speech
        voice: Voice ID (e.g., 'af_heart', 'am_adam', 'bf_emma')
        output_path: Path to save the output audio file
        speed: Speech speed multiplier (0.5 to 2.0)
        model_name: MLX Audio model to use

    Returns:
        dict with 'success' and 'audio_path' or 'error'
    """
    try:
        status_output("Loading MLX Audio...")
        progress_output(10, "Loading model")

        import mlx.core as mx
        import numpy as np
        from mlx_audio.tts.utils import load_model

        # Load model
        model = load_model(model_name)
        progress_output(30, "Model loaded")

        status_output(f"Generating speech with voice: {voice}")
        progress_output(40, "Generating speech")

        # Generate speech - collect all audio chunks
        audio_chunks = []
        for result in model.generate(
            text=text,
            voice=voice,
            speed=speed,
            lang_code="a",  # American English
        ):
            audio_chunks.append(result.audio)
            progress_output(60, "Processing audio")

        # Concatenate audio chunks
        if audio_chunks:
            audio = mx.concatenate(audio_chunks, axis=0)
        else:
            return {"success": False, "error": "No audio generated"}

        progress_output(80, "Saving audio")

        # Save to WAV file
        import wave

        # Convert MLX array to numpy
        audio_np = np.array(audio, dtype=np.float32)

        # Normalize to int16 range
        audio_int16 = (audio_np * 32767).astype(np.int16)

        # Write WAV file
        with wave.open(output_path, "w") as wav_file:
            wav_file.setnchannels(1)  # Mono
            wav_file.setsampwidth(2)  # 16-bit
            wav_file.setframerate(24000)  # Kokoro uses 24kHz
            wav_file.writeframes(audio_int16.tobytes())

        status_output(f"Audio saved to: {output_path}")
        progress_output(100, "Complete")

        return {"success": True, "audio_path": output_path}

    except ImportError as e:
        error_msg = f"MLX Audio not installed: {e}. Run: pip install mlx-audio"
        status_output(f"ERROR: {error_msg}")
        return {"success": False, "error": error_msg}
    except Exception as e:
        import traceback

        error_msg = f"{e}\n{traceback.format_exc()}"
        status_output(f"ERROR: {error_msg}")
        return {"success": False, "error": str(e)}


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Generate audio with MLX Audio")
    parser.add_argument("--text", "-t", type=str, required=True, help="Text to speak")
    parser.add_argument("--voice", "-v", type=str, default="af_heart", help="Voice ID")
    parser.add_argument(
        "--output", "-o", type=str, default="output.wav", help="Output path"
    )
    parser.add_argument("--speed", "-s", type=float, default=1.0, help="Speech speed")
    parser.add_argument(
        "--model",
        "-m",
        type=str,
        default="mlx-community/Kokoro-82M-bf16",
        help="Model name",
    )

    args = parser.parse_args()

    result = generate_audio(
        text=args.text,
        voice=args.voice,
        output_path=args.output,
        speed=args.speed,
        model_name=args.model,
    )

    print(json.dumps(result))
    sys.exit(0 if result["success"] else 1)
