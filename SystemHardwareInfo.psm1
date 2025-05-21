function Get-SystemHardwareInfo {
    param(
        [switch]$UseUtility
    )
    # Get CPU Vendor and Extensions
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cpuVendor = $cpu.Manufacturer
    $cpuName = $cpu.Name

    if ($cpuVendor -match 'AMD') {
        $cpuType = 'AMD'
       
    } elseif ($cpuVendor -match 'Intel') {
        $cpuType = 'Intel'
    } else {
        $cpuType = $cpuVendor
    }

    # Try to detect extensions from CPU name string or utility
    $cpuExts = @()
    if ($UseUtility) {
        # $tempPath variable removed as it was unused
        $cpuidUrl = 'https://download.sysinternals.com/files/Coreinfo.zip'
        $coreinfoExe = [System.IO.Path]::Combine($env:TEMP, 'Coreinfo.exe')
        if (-not (Test-Path $coreinfoExe)) {
            try {
                Write-Verbose "Downloading Coreinfo utility..."
                $zipPath = [System.IO.Path]::Combine($env:TEMP, 'Coreinfo.zip')
                Invoke-WebRequest -Uri $cpuidUrl -OutFile $zipPath -UseBasicParsing
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $env:TEMP)
                Remove-Item $zipPath -Force
            } catch {
                Write-Warning "Failed to download or extract Coreinfo. Falling back to PowerShell-only detection."
            }
        }
        if (Test-Path $coreinfoExe) {
            try {
                $coreinfoOutput = & $coreinfoExe | Out-String
                $extMatches = $coreinfoOutput | Select-String -Pattern 'AVX|AVX2|AVX-512|SSE4.2|SSE4.1|SSE3|SSE2|SSE|MMX|FMA|AES|VT-x|SMT|HT' -AllMatches
                $cpuExts = $extMatches.Matches.Value | Sort-Object -Unique
            } catch {
                Write-Warning "Failed to run Coreinfo. Falling back to PowerShell-only detection."
            }
        }
    }
    if (-not $cpuExts -or $cpuExts.Count -eq 0) {
        $knownExts = @('AVX-512', 'AVX2', 'AVX', 'SSE4.2', 'SSE4.1', 'SSE3', 'SSE2', 'SSE', 'MMX', 'FMA', 'AES', 'VT-x', 'SMT', 'HT')
        foreach ($ext in $knownExts) {
            if ($cpuName -match $ext) { $cpuExts += $ext }
        }
        if ($cpuExts.Count -eq 0) { $cpuExts = @('Unknown (not detectable via PowerShell)') }
    }

    # Get RAM (in GB)
    $ramBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    $ramGB = [math]::Round($ramBytes / 1GB, 2)

    # Get Disk Space (all drives)
    $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
        [PSCustomObject]@{
            DeviceID = $_.DeviceID
            SizeGB = [math]::Round($_.Size / 1GB, 2)
            FreeGB = [math]::Round($_.FreeSpace / 1GB, 2)
        }
    }

    # Get GPU(s) info with utilization
    $gpuUtil = @{}
    try {
        $counters = Get-Counter -ListSet "GPU Engine" -ErrorAction Stop
        $utilSamples = Get-Counter -Counter "\\GPU Engine(*)\\Utilization Percentage" -ErrorAction Stop
        foreach ($sample in $utilSamples.CounterSamples) {
            $instance = $sample.InstanceName
            $value = [math]::Round($sample.CookedValue, 2)
            if ($instance -notmatch "_engtype_3D") { continue } # Only 3D engines
            $gpuUtil[$instance] = $value
        }
    } catch {
        # If Get-Counter fails, leave $gpuUtil empty
    }

    $gpus = Get-CimInstance Win32_VideoController | ForEach-Object {
        $util = $null
        foreach ($key in $gpuUtil.Keys) {
            if ($key -like "*$_.$_.PNPDeviceID*") { $util = $gpuUtil[$key]; break }
        }
        [PSCustomObject]@{
            Name = $_.Name
            AdapterRAM_GB = if ($_.AdapterRAM) { [math]::Round($_.AdapterRAM / 1GB, 2) } else { $null }
            Utilization_Percent = $util
        }
    }

    # CUDA detection
    $cudaInstalled = $false
    $cudaVersion = $null
    $envVars = [System.Environment]::GetEnvironmentVariables()
    foreach ($key in $envVars.Keys) {
        if ($key -like 'CUDA_PATH*') {
            $cudaInstalled = $true
            $cudaPath = $envVars[$key]
            # Try to get version from folder name or version.txt
            if (Test-Path "$cudaPath\version.txt") {
                $cudaVersion = Get-Content "$cudaPath\version.txt" | Select-Object -First 1
            } elseif ($cudaPath -match 'v(\d+_\d+)') {
                $cudaVersion = $cudaPath -replace '.*v(\d+_\d+).*', '$1'
                $cudaVersion = $cudaVersion -replace '_', '.'
            }
            break
        }
    }
    # Fallback: check for nvcc.exe in PATH
    if (-not $cudaInstalled) {
        $nvcc = Get-Command nvcc.exe -ErrorAction SilentlyContinue
        if ($nvcc) {
            $cudaInstalled = $true
            # Try to get version from nvcc output
            $nvccVer = & $nvcc.Source -V 2>$null | Select-String 'release' | Select-Object -First 1
            if ($nvccVer) {
                if ($nvccVer -match 'release ([\d.]+)') {
                    $cudaVersion = $Matches[1]
                }
            }
        }
    }

    $Selected_LlamaCpp_Zip = Select-LlamaCppZipForHardware -CPU $cpuType -CPU_Extensions $cpuExts -GPUs $gpus.Name

    # Output as a custom object
    [PSCustomObject]@{
        CPU = $cpuType
        CPU_Name = $cpuName
        CPU_Extensions = $cpuExts -join ', '
        RAM_GB = $ramGB
        Disks = $disks
        GPUs = $gpus
        CUDA_Installed = $cudaInstalled
        CUDA_Version = $cudaVersion
    }
}

function Select-LlamaCppZipForHardware {
    param(
        [Parameter(Mandatory=$true)]
        [string]$CPU,
        [Parameter(Mandatory=$true)]
        [string[]]$CPU_Extensions,
        [Parameter(Mandatory=$false)]
        [string[]]$GPUs
    )
    # Default zip for AMD or Intel without any extension
    $defaultZip = 'https://github.com/ggml-org/llama.cpp/releases/download/b5349/llama-b5349-bin-win-cpu-x64.zip'

    # Example logic: you can expand this with more rules for other hardware/extension combos
    if (($CPU -eq 'AMD' -or $CPU -eq 'Intel') -and ($CPU_Extensions.Count -eq 0 -or ($CPU_Extensions -contains 'Unknown (not detectable via PowerShell)'))) {
        return $defaultZip
    }
    # Add more rules here for other CPU/GPU/extension combinations as needed

    # Fallback to default
    return $defaultZip
}

function Expand-LlamaBin {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ZipPath,
        [string]$TargetFolder = (Join-Path $env:LOCALAPPDATA 'llama-bin')
    )
    if (-not (Test-Path $ZipPath)) {
        Write-Host "Zip file not found: $ZipPath" -ForegroundColor Red
        return $null
    }
    if (-not (Test-Path $TargetFolder)) {
        New-Item -ItemType Directory -Path $TargetFolder | Out-Null
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $extractedFiles = @()
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        foreach ($entry in $zip.Entries) {
            if ($entry.Name -match '^llama-server\.exe$' -or $entry.Name -match '\.dll$') {
                $destPath = Join-Path $TargetFolder $entry.Name
                $entryStream = $entry.Open()
                $fileStream = [System.IO.File]::Open($destPath, [System.IO.FileMode]::Create)
                $entryStream.CopyTo($fileStream)
                $fileStream.Close()
                $entryStream.Close()
                $extractedFiles += $destPath
            }
        }
        $zip.Dispose()
        if ($extractedFiles.Count -eq 0) {
            Write-Host "No llama-server.exe or DLLs found in the zip." -ForegroundColor Yellow
            return $null
        }
        Write-Host "Extracted files:" -ForegroundColor Cyan
        foreach ($f in $extractedFiles) { Write-Host "  $f" -ForegroundColor Green }
        return [PSCustomObject]@{ ExtractedFiles = $extractedFiles }
    } catch {
        Write-Host "Failed to extract files: $_" -ForegroundColor Red
        return $null
    }
}

function Get-GGUFModel {
    param(
        [string]$ModelUrl = 'https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q2_K.gguf',
        [string]$TargetFolder = (Join-Path $env:LOCALAPPDATA 'llama-bin')
    )
    if (-not (Test-Path $TargetFolder)) {
        New-Item -ItemType Directory -Path $TargetFolder | Out-Null
    }
    $fileName = [System.IO.Path]::GetFileName($ModelUrl)
    $targetPath = Join-Path $TargetFolder $fileName
    if (-not (Test-Path $targetPath)) {
        Write-Host "Downloading GGUF model from $ModelUrl ..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri $ModelUrl -OutFile $targetPath -UseBasicParsing
    } else {
        Write-Host "Model already downloaded: $targetPath" -ForegroundColor Yellow
    }
    if (Test-Path $targetPath) {
        Write-Host "Model available at: $targetPath" -ForegroundColor Green
        return $targetPath
    } else {
        Write-Host "Failed to download model." -ForegroundColor Red
        return $null
    }
}

function Start-LlamaServer {
    param(
        [string]$ModelPath,
        [string]$BinFolder = (Join-Path $env:LOCALAPPDATA 'llama-bin'),
        [int]$Port = 8080,
        [string]$ListenHost = 'localhost',
        [string]$ExtraArgs = ''
    )
    $exePath = Join-Path $BinFolder 'llama-server.exe'
    if (-not (Test-Path $exePath)) {
        Write-Host "llama-server.exe not found in $BinFolder" -ForegroundColor Red
        return $null
    }
    if (-not (Test-Path $ModelPath)) {
        Write-Host "Model file not found: $ModelPath" -ForegroundColor Red
        return $null
    }
    # Check if port is available
    $portAvailable = $true
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
        $listener.Start()
        $listener.Stop()
    } catch {
        $portAvailable = $false
    }
    if (-not $portAvailable) {
        Write-Host "Port $Port is already in use. Please choose another port or stop the conflicting process." -ForegroundColor Red
        return $null
    }
    $cmdArgs = @(
        "--host", $ListenHost,
        "--port", $Port,
        "--model", $ModelPath
    )
    if ($ExtraArgs -ne '') {
        $cmdArgs += $ExtraArgs
    }
    Write-Host ("Launching llama-server.exe on {0}:{1} ..." -f $ListenHost, $Port) -ForegroundColor Cyan
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exePath
    $psi.Arguments = $cmdArgs -join ' '
    $psi.WorkingDirectory = $BinFolder
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $process.Start() | Out-Null
    Write-Host "llama-server.exe started with PID $($process.Id)" -ForegroundColor Green
    return [PSCustomObject]@{
        Process = $process
        PID = $process.Id
        Host = $ListenHost
        Port = $Port
    }
}

function Send-LlamaMessage {
    param(
        [string]$Message = "Hello World",
        [int]$Port = 8080,
        [string]$LlamaHost = 'localhost'
    )
    $url = "http://$LlamaHost`:$Port/completion"
    $body = @{ prompt = $Message } | ConvertTo-Json
    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType 'application/json'
        return $response
    } catch {
        Write-Host ("Failed to contact llama server at {0}: {1}" -f $url, ${_}) -ForegroundColor Red
        return $null
    }
}

function Get-LlamaHealth {
    param(
        [int]$Port = 8080,
        [string]$LlamaHost = 'localhost'
    )
    $url = "http://$LlamaHost`:$Port/health"
    try {
        $response = Invoke-RestMethod -Uri $url -Method Get
        Write-Host "Llama server health response:" -ForegroundColor Cyan
        $response | ConvertTo-Json -Depth 10 | Write-Host
        return $response
    } catch {
        Write-Host ("Failed to contact llama server health endpoint at {0}: {1}" -f $url, ${_}) -ForegroundColor Red
        return $null
    }
}

function Invoke-LlamaCompletion {
    param(
        [string]$Prompt,
        [int]$Port = 8080,
        [string]$LlamaHost = 'localhost',
        [int]$N_predict = 1024,
        [string]$Stop = $null,
        [int]$Seed = 42,
        [int]$Top_k = 40,
        [double]$Top_p = 0.95,
        [double]$Temperature = 0.0,
        [double]$Repeat_penalty = 1.1
    )
    $url = "http://$LlamaHost`:$Port/completion"

    $body = @{ prompt = $Prompt; n_predict = $N_predict; seed = $Seed; top_k = $Top_k; top_p = $Top_p; temperature = $Temperature; repeat_penalty = $Repeat_penalty }
    if ($Stop) { $body.stop = $Stop }
    $jsonBody = $body | ConvertTo-Json
    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -Body $jsonBody -ContentType 'application/json'
        return $response
    } catch {
        Write-Host ("Failed to contact llama server completion endpoint at {0}: {1}" -f $url, ${_}) -ForegroundColor Red
        return $null
    }
}

Export-ModuleMember -Function Get-SystemHardwareInfo,Select-LlamaCppZipForHardware,Expand-LlamaBin,Get-GGUFModel,Start-LlamaServer,Send-LlamaMessage,Get-LlamaHealth,Invoke-LlamaCompletion
