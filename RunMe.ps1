# Import the module (adjust the path if needed)
Import-Module "./SystemHardwareInfo.psm1"

# Get system hardware information (try with utility for best CPU extension detection)
$info = Get-SystemHardwareInfo -UseUtility

Write-Host "--- System Hardware Information ---" -ForegroundColor Cyan
Write-Host "CPU Type: $($info.CPU)" -ForegroundColor Yellow
Write-Host "CPU Name: $($info.CPU_Name)" -ForegroundColor Yellow
Write-Host "CPU Extensions: $($info.CPU_Extensions)" -ForegroundColor Yellow
Write-Host "Total RAM: $($info.RAM_GB) GB" -ForegroundColor Yellow

Write-Host "Disks:" -ForegroundColor Cyan
foreach ($disk in $info.Disks) {
    Write-Host "  Drive $($disk.DeviceID): $($disk.FreeGB) GB free of $($disk.SizeGB) GB" -ForegroundColor Green
}

Write-Host "GPUs:" -ForegroundColor Cyan
foreach ($gpu in $info.GPUs) {
    $util = if ($gpu.Utilization_Percent -ne $null) { "$($gpu.Utilization_Percent)%" } else { "N/A" }
    Write-Host "  $($gpu.Name) ($($gpu.AdapterRAM_GB) GB VRAM) - Utilization: $util" -ForegroundColor Green
}

$llama_zip = Select-LlamaCppZipForHardware -CPU $info.CPU -CPU_Extensions $info.CPU_Extensions -GPUs $info.GPUs.Name

Write-Host "Selected Llama.cpp Zip:" -ForegroundColor Cyan
if ($llama_zip) {
    Write-Host "  $($llama_zip)" -ForegroundColor Green
    # Download the zip if not already present
    $zipFileName = [System.IO.Path]::GetFileName($llama_zip)
    $zipLocalPath = Join-Path $env:TEMP $zipFileName
    if (-not (Test-Path $zipLocalPath)) {
        Write-Host "Downloading $llama_zip ..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri $llama_zip -OutFile $zipLocalPath -UseBasicParsing
        $shouldExtract = $true
    } else {
        Write-Host "Zip already downloaded: $zipLocalPath" -ForegroundColor Yellow
        # Only extract if the llama-server.exe or DLLs are missing in the target folder
        $llamaBinFolder = Join-Path $env:LOCALAPPDATA 'llama-bin'
        $llamaServerExe = Join-Path $llamaBinFolder 'llama-server.exe'
        $dlls = @('llama.dll', 'ggml.dll')
        $dllsExist = $true
        foreach ($dll in $dlls) {
            if (-not (Test-Path (Join-Path $llamaBinFolder $dll))) { $dllsExist = $false; break }
        }
        if (-not (Test-Path $llamaServerExe) -or -not $dllsExist) {
            $shouldExtract = $true
        } else {
            $shouldExtract = $false
        }
    }
    if ($shouldExtract) {
        # Extract llama-server.exe and DLLs
        $extractResult = Expand-LlamaBin -ZipPath $zipLocalPath
    } else {
        Write-Host "Binaries already extracted in $llamaBinFolder. Skipping extraction." -ForegroundColor Yellow
        $extractResult = [PSCustomObject]@{ ExtractedFiles = @(Join-Path $llamaBinFolder 'llama-server.exe') }
    }
    if ($extractResult -and $extractResult.ExtractedFiles) {
        Write-Host "Extraction successful. Extracted files:" -ForegroundColor Cyan
        foreach ($f in $extractResult.ExtractedFiles) { Write-Host "  $f" -ForegroundColor Green }
        # Download GGUF model to llama-bin folder
        $ggufModelPath = Get-GGUFModel
        if ($ggufModelPath) {
            Write-Host "GGUF model ready at: $ggufModelPath" -ForegroundColor Green
            # Check for existing server info and process
            $serverInfoFile = Join-Path $env:LOCALAPPDATA 'llama-bin-server-info.json'
            $reuseServer = $false
            if (Test-Path $serverInfoFile) {
                $serverInfo = Get-Content $serverInfoFile | ConvertFrom-Json
                if ($serverInfo -and $serverInfo.pid) {
                    $existingProc = Get-Process -Id $serverInfo.pid -ErrorAction SilentlyContinue
                    if ($existingProc) {
                        Write-Host "Found running llama-server process (PID: $($serverInfo.pid)). Checking health..." -ForegroundColor Yellow
                        $reuseServer = $true
                        $serverResult = [PSCustomObject]@{ Host = $serverInfo.address; Port = $serverInfo.port; PID = $serverInfo.pid }
                    }
                }
            }
            if (-not $reuseServer) {
                # Start llama-server
                $serverResult = Start-LlamaServer -ModelPath $ggufModelPath -spf "system.txt"
                if ($serverResult) {
                    Write-Host "llama-server.exe launched successfully. PID: $($serverResult.PID)" -ForegroundColor Green
                    # Save PID and server info to file for later checks
                    $serverInfo = @{ address = $serverResult.Host; port = $serverResult.Port; pid = $serverResult.PID }
                    $serverInfo | ConvertTo-Json | Set-Content -Path $serverInfoFile
                    Write-Host "Saved llama-server info to $serverInfoFile" -ForegroundColor Yellow
                    # Wait up to 60 seconds for server to be ready
                    Write-Host "Waiting up to 60 seconds for llama-server to be ready..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 60
                } else {
                    Write-Host "Failed to launch llama-server.exe." -ForegroundColor Red
                }
            }
            if ($serverResult) {
                # Health check and completion
                $health = Get-LlamaHealth -Port $serverResult.Port -LlamaHost $serverResult.Host
                if ($health -and $health.status -eq 'OK') {
                    Write-Host "Llama server health is OK. Sending completion request..." -ForegroundColor Green
                    $completion = Invoke-LlamaCompletion -Prompt 'The default Windows XP folder is ' -Port $serverResult.Port -LlamaHost $serverResult.Host
                    Write-Host "Completion response: $($completion.content)" -ForegroundColor Green
                } else {
                    Write-Host "Llama server health check failed or status not OK." -ForegroundColor Red
                }
            }
        } else {
            Write-Host "Failed to download GGUF model." -ForegroundColor Red
        }
    } else {
        Write-Host "Extraction failed or no files found." -ForegroundColor Red
    }
} else {
    Write-Host "  No suitable Llama.cpp zip found for the current hardware." -ForegroundColor Red
}
