$ErrorActionPreference = "Stop"
$Keytool = "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe"
if (-not (Test-Path $Keytool)) {
  Write-Error "keytool not found at $Keytool; set Keytool path or install Android Studio JBR."
}

$storePass = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
$keyPass = $storePass
$ks = Join-Path $PSScriptRoot "upload-keystore.jks"
$alias = "oxplayer_upload"

if (Test-Path $ks) { Remove-Item $ks -Force }

& $Keytool -genkeypair -v -storetype PKCS12 -keystore $ks -alias $alias `
  -keyalg RSA -keysize 2048 -validity 10000 `
  -storepass $storePass -keypass $keyPass `
  -dname "CN=Oxplayer Release, OU=Mobile, O=Oxplayer, L=San Francisco, ST=CA, C=US"

$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ks))
$out = Join-Path $PSScriptRoot ".ci-keystore-secrets-temp.txt"
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("GitHub Actions secrets - copy then DELETE this file")
[void]$sb.AppendLine("Created: " + (Get-Date -Format o))
[void]$sb.AppendLine("")
[void]$sb.AppendLine("ANDROID_KEY_ALIAS")
[void]$sb.AppendLine($alias)
[void]$sb.AppendLine("")
[void]$sb.AppendLine("ANDROID_KEYSTORE_PASSWORD")
[void]$sb.AppendLine($storePass)
[void]$sb.AppendLine("")
[void]$sb.AppendLine("ANDROID_KEY_PASSWORD")
[void]$sb.AppendLine($keyPass)
[void]$sb.AppendLine("")
[void]$sb.AppendLine("ANDROID_KEYSTORE_BASE64 single line:")
[void]$sb.AppendLine($b64)
[void]$sb.AppendLine("")
[void]$sb.AppendLine("Keep forever offline: keystore file path, alias, both passwords.")
[void]$sb.AppendLine($ks)
[System.IO.File]::WriteAllText($out, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))

Write-Host "OK: $ks"
Write-Host "OK: $out"
