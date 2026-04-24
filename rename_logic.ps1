# PowerShell Rename Logic (ASCII-Safe with Unicode Escapes)

# Define Dimensions Function (Move outside try for cleaner structure)
function Get-Dims {
    param($P)
    $w = 0; $h = 0
    try {
        $f = Get-Item $P
        $shell = New-Object -ComObject Shell.Application
        $nd = $shell.Namespace($f.DirectoryName)
        $fi = $nd.ParseName($f.Name)
        # Regex for dimension property names
        $regW = "^(Frame width|Width|$([char]0x5E27)$([char]0x5BBD)$([char]0x5EA6)|$([char]0x5BBD)$([char]0x5EA6))$"
        $regH = "^(Frame height|Height|$([char]0x5E27)$([char]0x9AD8)$([char]0x5EA6)|$([char]0x9AD8)$([char]0x5EA6))$"
        
        for($i=0; $i -le 350; $i++){
            $pn = $nd.GetDetailsOf($null, $i)
            if($pn -match $regW){
                $v = $nd.GetDetailsOf($fi, $i) -replace '[^\d]', ''
                if($v){$w = [int]$v}
            }
            if($pn -match $regH){
                $v = $nd.GetDetailsOf($fi, $i) -replace '[^\d]', ''
                if($v){$h = [int]$v}
            }
            if($w -gt 0 -and $h -gt 0){ break }
        }
    } catch {}
    return @{W=$w; H=$h}
}

try {
    # 1. Setup paths
    $DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
    if (-not $DIR) { $DIR = Get-Location }
    Set-Location -Path $DIR

    $SET_PATH = Join-Path $DIR 'settings.json'
    $SEQ_PATH = Join-Path $DIR 'sequence.json'
    $LOG_PATH = Join-Path $DIR 'naming_log.csv'

    # 2. Validate files
    if (-not (Test-Path $SET_PATH)) { throw "Missing settings.json" }
    if (-not (Test-Path $SEQ_PATH)) { throw "Missing sequence.json" }

    # 3. Load config
    $S = Get-Content $SET_PATH -Raw | ConvertFrom-Json
    
    $Q_RAW = Get-Content $SEQ_PATH -Raw
    if ([string]::IsNullOrWhiteSpace($Q_RAW)) {
        Write-Host "Sequence file is empty. Recovering from naming_log.csv..." -ForegroundColor Yellow
        $img_max = 0
        $vid_max = 0
        
        if (Test-Path $LOG_PATH) {
            $logData = Import-Csv $LOG_PATH
            $tag_img = "$([char]0x56FE)" # 鍥?            $tag_vid = "$([char]0x89C6)$([char]0x9891)" # 瑙嗛
            
            foreach ($row in $logData) {
                if ($row.NewName -match '^B(\d+)-') {
                    $num = [int]$matches[1]
                    if ($row.NewName -match $tag_img) {
                        if ($num -gt $img_max) { $img_max = $num }
                    } elseif ($row.NewName -match $tag_vid) {
                        if ($num -gt $vid_max) { $vid_max = $num }
                    }
                }
            }
        }
        
        $Q = [PSCustomObject]@{ 
            image_seq = $img_max + 1
            video_seq = $vid_max + 1
        }
        Write-Host "Recovered Next: Image=$($Q.image_seq), Video=$($Q.video_seq)" -ForegroundColor Cyan
    } else {
        $Q = $Q_RAW | ConvertFrom-Json
    }

    # Initialize log with CSV header
    if (-not (Test-Path $LOG_PATH)) { 
        "Time,OriginalName,NewName,OutputPath" | Set-Content $LOG_PATH -Encoding UTF8 
    }

    # Auto-merge backup logs if they exist (e.g. from a previous run where CSV was locked)
    $TMP_LOG = Join-Path $DIR "naming_log_backup.csv"
    if (Test-Path $TMP_LOG) {
        try {
            $backupContent = Get-Content $TMP_LOG | Select-Object -Skip 1
            if ($backupContent) {
                $backupContent | Add-Content $LOG_PATH -Encoding UTF8 -ErrorAction Stop
                Remove-Item $TMP_LOG -Force
                Write-Host "Success: Merged backup logs into naming_log.csv" -ForegroundColor Green
            }
        } catch {
            Write-Host "Notice: Backup log exists but naming_log.csv is still locked. Will merge later." -ForegroundColor Gray
        }
    }

    $DATE_STR = (Get-Date).ToString('yyyyMMdd')
    $v_cnt = 0
    $i_cnt = 0

    # 4. Main Loop
    $items = Get-ChildItem -Path $DIR
    foreach ($item in $items) {
        if ($item.Name -match 'settings\.json|sequence\.json|naming_log\.csv|.*\.bat|.*\.ps1') { continue }
        
        # A. Folders (9-image logic)
        if ($item.PSIsContainer) {
            $sub = @(Get-ChildItem -Path $item.FullName -File)
            
            $file1 = $null
            $isComplete = $true
            # Check 1 to 9 sequence and locate file 1
            for ($j = 1; $j -le 9; $j++) {
                $foundDigit = $false
                foreach ($f in $sub) {
                    if ($f.BaseName -match "(^|\D)0?$j(\D|$)") {
                        $foundDigit = $true
                        if ($j -eq 1 -and $null -eq $file1) { $file1 = $f }
                        break
                    }
                }
                if (-not $foundDigit) {
                    $isComplete = $false
                    break
                }
            }
            
            if (-not $isComplete -or $sub.Count -lt 9) {
                # ASCII-safe message 
                $msg = "Error: Incomplete 1-9 sequence or missing files!`n`nPath: $($item.FullName)"
                $objShell = New-Object -ComObject WScript.Shell
                $objShell.Popup($msg, 0, "Missing 1-9", 16)
                continue
            }
            if ($null -eq $file1) {
                $msg = "Error: Cannot find file representing '1'!`n`nPath: $($item.FullName)"
                $objShell = New-Object -ComObject WScript.Shell
                $objShell.Popup($msg, 0, "Missing file 1", 16)
                continue
            }
            
            try { Add-Type -AssemblyName Microsoft.VisualBasic } catch {}
            $promptMsg = "9-Image sequence detected!`n`nFolder: $($item.Name)`n`nPlease enter the base name for these 9 images (e.g., 娴嬭瘯-涓変綋):"
            $inputName = [Microsoft.VisualBasic.Interaction]::InputBox($promptMsg, "Provide Initial Name", $item.Name)
            
            if ([string]::IsNullOrWhiteSpace($inputName)) {
                $objShell = New-Object -ComObject WScript.Shell
                $objShell.Popup("Action cancelled or name empty. Skipping this folder.", 0, "Skipped", 48)
                continue
            }
            
            $type9 = "9$([char]0x56FE)"
            $newN = "B$($Q.image_seq)-$inputName-$type9-$DATE_STR-$($S.DESIGNER)"
            $dest = Join-Path $S.IMAGE_OUT_DIR $newN
            
            if (-not (Test-Path $S.IMAGE_OUT_DIR)) { New-Item -ItemType Directory -Path $S.IMAGE_OUT_DIR -Force | Out-Null }
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            
            # Now Rename 1 file and move all
            foreach ($f in $sub) {
                if ($f.FullName -eq $file1.FullName) {
                    $newFileN = "$newN$($f.Extension)"
                    Move-Item -Path $f.FullName -Destination (Join-Path $dest $newFileN) -Force -ErrorAction SilentlyContinue
                } else {
                    Move-Item -Path $f.FullName -Destination (Join-Path $dest $f.Name) -Force -ErrorAction SilentlyContinue
                }
            }
            
            Remove-Item -Path $item.FullName -Force -Recurse -ErrorAction SilentlyContinue
            
            $logLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$($item.Name),$newN,$($S.IMAGE_OUT_DIR)"
            
            # Robust Logging: Handle cases where the file might be locked by Excel
            try {
                $logLine | Add-Content $LOG_PATH -Encoding UTF8 -ErrorAction Stop
            } catch {
                $TMP_LOG = Join-Path $DIR "naming_log_backup.csv"
                Write-Host "Warning: naming_log.csv is locked. Saving to backup log..." -ForegroundColor Yellow
                if (-not (Test-Path $TMP_LOG)) { "Time,OriginalName,NewName,OutputPath" | Set-Content $TMP_LOG -Encoding UTF8 }
                $logLine | Add-Content $TMP_LOG -Encoding UTF8
            }
            $Q.image_seq++
            $i_cnt++
        } 
        # B. Files
        else {
            $ext = $item.Extension.ToLower()
            $isV = $S.VID_EXTS -contains $ext
            $isI = $S.IMG_EXTS -contains $ext
            
            if ($isV -or $isI) {
                $d = Get-Dims $item.FullName
                
                if ($isV) {
                    # 妯棰?= \u6A2A\u89C6\u9891, 绔栬棰?= \u7AD6\u89C6\u9891
                    $type = if ($d.W -gt $d.H) { "$([char]0x6A2A)$([char]0x89C6)$([char]0x9891)" } else { "$([char]0x7AD6)$([char]0x89C6)$([char]0x9891)" }
                    $seq = $Q.video_seq
                    $out = $S.VIDEO_OUT_DIR
                    $Q.video_seq++
                    $v_cnt++
                } else {
                    # 妯浘 = \u6A2A\u56FE, 绔栧浘 = \u7AD6\u56FE
                    $type = if ($d.W -gt $d.H) { "$([char]0x6A2A)$([char]0x56FE)" } else { "$([char]0x7AD6)$([char]0x56FE)" }
                    $seq = $Q.image_seq
                    $out = $S.IMAGE_OUT_DIR
                    $Q.image_seq++
                    $i_cnt++
                }
                
                $finalName = "B$($seq)-$($item.BaseName)-$type-$DATE_STR-$($S.DESIGNER)$ext"
                if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
                
                Move-Item -Path $item.FullName -Destination (Join-Path $out $finalName) -Force
                $logLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$($item.Name),$finalName,$out"
                
                # Robust Logging: Handle cases where the file might be locked by Excel
                try {
                    $logLine | Add-Content $LOG_PATH -Encoding UTF8 -ErrorAction Stop
                } catch {
                    $TMP_LOG = Join-Path $DIR "naming_log_backup.csv"
                    Write-Host "Warning: naming_log.csv is locked. Saving to backup log..." -ForegroundColor Yellow
                    if (-not (Test-Path $TMP_LOG)) { "Time,OriginalName,NewName,OutputPath" | Set-Content $TMP_LOG -Encoding UTF8 }
                    $logLine | Add-Content $TMP_LOG -Encoding UTF8
                }
            }
        }
    }

    # 5. Save State
    $Q | ConvertTo-Json | Set-Content $SEQ_PATH -Encoding UTF8
    
    # 6. Report
    $msg = "Task Finished!`n`nImages: $i_cnt`nVideos: $v_cnt`n`nCheck naming_log.csv for details."
    $objShell = New-Object -ComObject WScript.Shell
    $objShell.Popup($msg, 0, "Automation Report", 64)

} catch {
    $err = "Error: $($_.Exception.Message)"
    Write-Host $err -ForegroundColor Red
    $objShell = New-Object -ComObject WScript.Shell
    $objShell.Popup($err, 0, "Error", 16)
    exit 1
}

