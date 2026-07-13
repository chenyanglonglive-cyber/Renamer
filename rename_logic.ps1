# PowerShell Rename Logic (ASCII-Safe with Unicode Escapes)
param(
    [string]$ProjectSuffix = ""
)

try { Add-Type -AssemblyName System.Drawing } catch {}

# Image Compression Function
function Save-CompressedImage {
    param(
        [string]$SourcePath,
        [string]$DestPath,
        [long]$MaxBytes = 256000
    )
    
    $img = $null
    try {
        $img = [System.Drawing.Image]::FromFile($SourcePath)
        
        $codecs = [System.Drawing.Imaging.ImageCodecInfo]::GetImageDecoders()
        $jpegCodec = $codecs | Where-Object { $_.FormatID -eq [System.Drawing.Imaging.ImageFormat]::Jpeg.Guid }
        
        $quality = 95L
        $success = $false
        
        while ($quality -ge 10) {
            $encParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
            $encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, $quality)
            
            $ms = New-Object System.IO.MemoryStream
            $img.Save($ms, $jpegCodec, $encParams)
            
            if ($ms.Length -le $MaxBytes) {
                $fs = New-Object System.IO.FileStream($DestPath, [System.IO.FileMode]::Create)
                $ms.WriteTo($fs)
                $fs.Close()
                $ms.Close()
                $success = $true
                break
            }
            $ms.Close()
            $quality -= 5
        }
        
        if (-not $success) {
            $encParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
            $encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, 10L)
            $img.Save($DestPath, $jpegCodec, $encParams)
        }
        
        $img.Dispose()
        $img = $null
    } catch {
        if ($null -ne $img) { $img.Dispose(); $img = $null }
        # Fallback if error
        Copy-Item -Path $SourcePath -Destination $DestPath -Force
    }
}

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
    $S = Get-Content $SET_PATH -Raw -Encoding UTF8 | ConvertFrom-Json
    
    $Q_RAW = Get-Content $SEQ_PATH -Raw -Encoding UTF8
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
    $PROJECT_SUFFIX_PART = ""
    if (-not [string]::IsNullOrWhiteSpace($ProjectSuffix)) {
        $PROJECT_SUFFIX_PART = "-$ProjectSuffix"
    }
    $v_cnt = 0
    $i_cnt = 0

    # 3.5 Pre-scan for large images
    $largeImageCount = 0
    $items = Get-ChildItem -Path $DIR
    foreach ($item in $items) {
        if ($item.Name -match 'settings\.json|sequence\.json|naming_log\.csv|.*\.bat|.*\.ps1|^\.') { continue }
        if ($item.PSIsContainer) {
            $sub = @(Get-ChildItem -Path $item.FullName -File)
            foreach ($f in $sub) {
                $ext = $f.Extension.ToLower()
                if ($S.IMG_EXTS -contains $ext -and $f.Length -gt 256000) {
                    $largeImageCount++
                }
            }
        } else {
            $ext = $item.Extension.ToLower()
            if ($S.IMG_EXTS -contains $ext -and $item.Length -gt 256000) {
                $largeImageCount++
            }
        }
    }

    $doCompress = $false
    if ($largeImageCount -gt 0) {
        $objShell = New-Object -ComObject WScript.Shell
        # $msg = "发现 N 个图片大于 250KB。是否压缩？" (Using ASCII-safe hex)
        $msg = "$([char]0x53D1)$([char]0x73B0) $largeImageCount $([char]0x4E2A)$([char]0x56FE)$([char]0x7247)$([char]0x5927)$([char]0x4E8E) 250KB.`n`n$([char]0x662F)$([char]0x5426)$([char]0x538B)$([char]0x7F29)? (Keep Dimensions, Reduce Quality)"
        $btn = $objShell.Popup($msg, 0, "Compression", 4 + 32) # 4 = Yes/No, 32 = Question
        if ($btn -eq 6) { # 6 = Yes
            $doCompress = $true
        }
    }

    # 4. Main Loop
    $items = Get-ChildItem -Path $DIR
    foreach ($item in $items) {
        if ($item.Name -match 'settings\.json|sequence\.json|naming_log\.csv|.*\.bat|.*\.ps1|^\.') { continue }
        
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
            $newN = "B$($Q.image_seq)-$inputName-$type9-$DATE_STR-$($S.DESIGNER)$PROJECT_SUFFIX_PART"
            $dest = Join-Path $S.IMAGE_OUT_DIR $newN
            
            if (-not (Test-Path $S.IMAGE_OUT_DIR)) { New-Item -ItemType Directory -Path $S.IMAGE_OUT_DIR -Force | Out-Null }
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            
            # Now Rename 1 file and move all
            foreach ($f in $sub) {
                $fExt = $f.Extension.ToLower()
                $isImg = $S.IMG_EXTS -contains $fExt

                # Format Check: .jpg (Allow .jpeg too)
                if ($isImg -and -not ($fExt -eq '.jpg' -or $fExt -eq '.jpeg')) {
                    $fmtWarnMsg = "$([char]0x6CE8)$([char]0x610F)$([char]0xFF1A)$([char]0x6587)$([char]0x4EF6)$([char]0x4E0D)$([char]0x662F)$([char]0x89C4)$([char]0x5B9A)$([char]0x683C)$([char]0x5F0F)! (JPG)`n`n$([char]0x6587)$([char]0x4EF6): $($f.Name)`n$([char]0x683C)$([char]0x5F0F): $fExt"
                    (New-Object -ComObject WScript.Shell).Popup($fmtWarnMsg, 0, "Format Warning", 48) | Out-Null
                }

                $fNeedResize = $false
                if ($isImg) {
                    $fd = Get-Dims $f.FullName
                    if ($fd.W -gt 0 -and $fd.H -gt 0 -and $fd.W -eq $fd.H -and ($fd.W -ne 800 -or $fd.H -ne 800)) {
                        $fNeedResize = $true
                        $warnMsg = "$([char]0x6CE8)$([char]0x610F)$([char]0xFF1A)$([char]0x65B9)$([char]0x56FE)$([char]0x5C3A)$([char]0x5BF8)$([char]0x4E0D)$([char]0x7B26)$([char]0x5408) 800*800 $([char]0x89C4)$([char]0x683C)$([char]0xFF0C)$([char]0x5DF2)$([char]0x4FEE)$([char]0x6539)$([char]0x4E3A) 800*800 $([char]0x7684) JPG $([char]0x683C)$([char]0x5F0F)！`n`n$([char]0x6587)$([char]0x4EF6): $($f.Name)`n$([char]0x539F)$([char]0x5C3A)$([char]0x5BF8): $($fd.W) x $($fd.H)"
                        (New-Object -ComObject WScript.Shell).Popup($warnMsg, 0, "Dimension Warning", 48) | Out-Null
                    }
                }

                if ($f.FullName -eq $file1.FullName) {
                    if ($fNeedResize) {
                        $targetName = "$newN.jpg"
                    } else {
                        $targetName = "$newN$($f.Extension)"
                    }
                } else {
                    if ($fNeedResize) {
                        $targetName = [System.IO.Path]::ChangeExtension($f.Name, '.jpg')
                    } else {
                        $targetName = $f.Name
                    }
                }

                $targetPath = Join-Path $dest $targetName

                if ($fNeedResize) {
                    & ffmpeg -y -hide_banner -loglevel error -i $f.FullName -vf scale=800:800 $targetPath
                    if ($doCompress -and $isImg -and (Get-Item $targetPath).Length -gt 256000) {
                        Save-CompressedImage -SourcePath $targetPath -DestPath $targetPath -MaxBytes 256000
                    }
                    Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
                } elseif ($doCompress -and $isImg -and $f.Length -gt 256000) {
                    Save-CompressedImage -SourcePath $f.FullName -DestPath $targetPath -MaxBytes 256000
                    Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
                } else {
                    Move-Item -Path $f.FullName -Destination $targetPath -Force -ErrorAction SilentlyContinue
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
                    # Format Check: .mp4
                    if ($ext -ne '.mp4') {
                        $fmtWarnMsg = "$([char]0x6CE8)$([char]0x610F)$([char]0xFF1A)$([char]0x6587)$([char]0x4EF6)$([char]0x4E0D)$([char]0x662F)$([char]0x89C4)$([char]0x5B9A)$([char]0x683C)$([char]0x5F0F)! (MP4)`n`n$([char]0x6587)$([char]0x4EF6): $($item.Name)`n$([char]0x683C)$([char]0x5F0F): $ext"
                        (New-Object -ComObject WScript.Shell).Popup($fmtWarnMsg, 0, "Format Warning", 48) | Out-Null
                    }
                    # Dimension Check: 1280*720 or 720*1280
                    if (-not (($d.W -eq 1280 -and $d.H -eq 720) -or ($d.W -eq 720 -and $d.H -eq 1280))) {
                        $warnMsg = "$([char]0x6CE8)$([char]0x610F)$([char]0xFF1A)$([char]0x89C6)$([char]0x9891)$([char]0x4E0D)$([char]0x662F)$([char]0x89C4)$([char]0x5B9A)$([char]0x5C3A)$([char]0x5BF8)! (1280*720 / 720*1280)`n`n$([char]0x6587)$([char]0x4EF6): $($item.Name)`n$([char]0x5C3A)$([char]0x5BF8): $($d.W) x $($d.H)"
                        (New-Object -ComObject WScript.Shell).Popup($warnMsg, 0, "Dimension Warning", 48) | Out-Null
                    }
                    # 妯棰?= \u6A2A\u89C6\u9891, 绔栬棰?= \u7AD6\u89C6\u9891
                    $type = if ($d.W -gt $d.H) { "$([char]0x6A2A)$([char]0x89C6)$([char]0x9891)" } else { "$([char]0x7AD6)$([char]0x89C6)$([char]0x9891)" }
                    $seq = $Q.video_seq
                    $out = $S.VIDEO_OUT_DIR
                    $Q.video_seq++
                    $v_cnt++
                } else {
                    # Format Check: .jpg
                    if (-not ($ext -eq '.jpg' -or $ext -eq '.jpeg')) {
                        $fmtWarnMsg = "$([char]0x6CE8)$([char]0x610F)$([char]0xFF1A)$([char]0x6587)$([char]0x4EF6)$([char]0x4E0D)$([char]0x662F)$([char]0x89C4)$([char]0x5B9A)$([char]0x683C)$([char]0x5F0F)! (JPG)`n`n$([char]0x6587)$([char]0x4EF6): $($item.Name)`n$([char]0x683C)$([char]0x5F0F): $ext"
                        (New-Object -ComObject WScript.Shell).Popup($fmtWarnMsg, 0, "Format Warning", 48) | Out-Null
                    }
                    # 横图 = \u6A2A\u56FE, 竖图 = \u7AD6\u56FE, 方图 = \u65B9\u56FE
                    $type = if ($d.W -gt 0 -and $d.H -gt 0 -and $d.W -eq $d.H) { "$([char]0x65B9)$([char]0x56FE)" } elseif ($d.W -gt $d.H) { "$([char]0x6A2A)$([char]0x56FE)" } else { "$([char]0x7AD6)$([char]0x56FE)" }
                    $seq = $Q.image_seq
                    $out = $S.IMAGE_OUT_DIR
                    $Q.image_seq++
                    $i_cnt++
                }
                
                $fNeedResize = $false
                if ($isI -and $d.W -gt 0 -and $d.H -gt 0 -and $d.W -eq $d.H) {
                    if ($d.W -ne 800 -or $d.H -ne 800) {
                        $fNeedResize = $true
                        $warnMsg = "$([char]0x6CE8)$([char]0x610F)$([char]0xFF1A)$([char]0x65B9)$([char]0x56FE)$([char]0x5C3A)$([char]0x5BF8)$([char]0x4E0D)$([char]0x7B26)$([char]0x5408) 800*800 $([char]0x89C4)$([char]0x683C)$([char]0xFF0C)$([char]0x5DF2)$([char]0x4FEE)$([char]0x6539)$([char]0x4E3A) 800*800 $([char]0x7684) JPG $([char]0x683C)$([char]0x5F0F)！`n`n$([char]0x6587)$([char]0x4EF6): $($item.Name)`n$([char]0x539F)$([char]0x5C3A)$([char]0x5BF8): $($d.W) x $($d.H)"
                        (New-Object -ComObject WScript.Shell).Popup($warnMsg, 0, "Dimension Warning", 48) | Out-Null
                        $ext = '.jpg'
                    }
                }

                if ($doCompress -and $isI -and $item.Length -gt 256000) {
                    if ($ext -ne '.jpg' -and $ext -ne '.jpeg') {
                        $ext = '.jpg'
                    }
                }

                $finalName = "B$($seq)-$($item.BaseName)-$type-$DATE_STR-$($S.DESIGNER)$PROJECT_SUFFIX_PART$ext"
                if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
                
                $destPath = Join-Path $out $finalName
                if ($fNeedResize) {
                    & ffmpeg -y -hide_banner -loglevel error -i $item.FullName -vf scale=800:800 $destPath
                    if ($doCompress -and $isI -and (Get-Item $destPath).Length -gt 256000) {
                        Save-CompressedImage -SourcePath $destPath -DestPath $destPath -MaxBytes 256000
                    }
                    Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
                } elseif ($doCompress -and $isI -and $item.Length -gt 256000) {
                    Save-CompressedImage -SourcePath $item.FullName -DestPath $destPath -MaxBytes 256000
                    Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
                } else {
                    Move-Item -Path $item.FullName -Destination $destPath -Force
                }
                
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

