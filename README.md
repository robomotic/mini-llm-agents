# PsLLM: PowerShell Llama.cpp Hardware & Model Bootstrapper

> **Proof of Concept (POC): Local LLMs as Hacking Tools**
>
> This project demonstrates how attackers could leverage a local LLM for offensive security or hacking purposes. By first detecting the available CPU/GPU hardware, the tool can select and download the most suitable LLM model and binaries stealthily. The model is then served locally via llama.cpp, which is highly efficient and lightweight. This approach enables attackers to run advanced language models on compromised systems without relying on cloud APIs, increasing stealth and persistence.

This PowerShell tool automates the process of detecting your system hardware, downloading the appropriate llama.cpp Windows binaries, fetching a GGUF model from HuggingFace, and launching a local LLM server with health and completion API endpoints.

## Features
- **Automatic Hardware Detection:** Detects CPU, RAM, GPU, and CUDA support.
- **Smart Binary Selection:** Downloads the best llama.cpp Windows binary for your hardware.
- **Model Download:** Fetches a default TinyLlama GGUF model (or your choice) from HuggingFace.
- **One-Click Extraction:** Extracts only the necessary binaries (llama-server.exe and DLLs) to a local folder.
- **Idempotent Setup:** Skips downloads and extraction if files are already present.
- **Server Management:** Launches llama-server, saves its PID, address, and port for later use, and checks if a server is already running.
- **Health & Completion API:** Checks server health and sends a test completion request ("Hello World" or your prompt).

## Usage

1. **Clone or Download** this repository.
2. **Open PowerShell** in the project directory.
3. **Run the main script:**
   ```powershell
   .\RunMe.ps1
   ```
   The script will:
   - Detect your hardware
   - Download the correct llama.cpp binary (if needed)
   - Download the TinyLlama GGUF model (if needed)
   - Extract binaries (if needed)
   - Start the llama-server (or reuse if already running)
   - Check server health and send a test completion

## Customization
- **Model:** Edit `Get-GGUFModel` in `SystemHardwareInfo.psm1` to use a different GGUF model URL.
- **Prompt:** Change the prompt in `Invoke-LlamaCompletion` or in `RunMe.ps1` to test with your own text.
- **Port/Host:** By default, the server runs on `0.0.0.0:8080`. You can change this in the script or module.

## API Endpoints
- `GET /health` — Returns server health status.
- `POST /completion` — Accepts a prompt and returns a model completion.

## Requirements
- Windows 10/11
- PowerShell 5.1 or later
- Internet connection (for first run)

## Files
- `RunMe.ps1` — Main entry point script.
- `SystemHardwareInfo.psm1` — PowerShell module with all logic and helper functions.
- `llama-bin-server-info.json` — Stores running server PID, address, and port.

## Example Output
```
--- System Hardware Information ---
CPU Type: Intel
CPU Name: Intel(R) Core(TM) i7-xxxx CPU @ 2.60GHz
CPU Extensions: AVX2, SSE4.2, ...
Total RAM: 32 GB
Disks:
  Drive C: 100 GB free of 500 GB
GPUs:
  NVIDIA GeForce RTX 3060 (6 GB VRAM) - Utilization: 0%
Selected Llama.cpp Zip:
  https://github.com/ggml-org/llama.cpp/releases/download/...
Zip already downloaded: ...
Binaries already extracted in ...\llama-bin. Skipping extraction.
GGUF model ready at: ...\llama-bin\tinyllama-1.1b-chat-v1.0.Q2_K.gguf
Found running llama-server process (PID: 12345). Checking health...
Llama server health is OK. Sending completion request...
Completion response: Hello! How can I help you today?
```

## Troubleshooting
- If you see errors about missing modules or permissions, try running PowerShell as Administrator.
- If the server fails to start, check for port conflicts or missing dependencies.
- To stop the server, kill the process using the PID in `llama-bin-server-info.json`.

## License
MIT
