<#
.SYNOPSIS
    OAuth 2.0 Client Credentials grant against Okta, with DPoP (Demonstrating
    Proof-of-Possession) enforcement, followed by independent JWT validation
    via the Authorization Server's public JWKS.

.DESCRIPTION
    Companion script to Entry 05 of the Okta-IAM-Lab repo.

    Flow:
      1. Attempt a plain Client Credentials token request (Basic Auth only).
         Expected to fail: Okta's API Services app type enforces DPoP.
      2. Generate an EC (P-256) key pair and build/sign a DPoP proof JWT.
         Retry with the DPoP header attached.
         Expected to fail again: Okta requires a server-issued nonce.
      3. Capture the nonce from the DPoP-Nonce response header, rebuild the
         proof with the nonce included, resign, and retry. This succeeds.
      4. Decode the returned access token (header + payload) without
         verification, to inspect claims.
      5. Fetch the Authorization Server's JWKS, locate the signing key by
         `kid`, and independently verify the token's RS256 signature.

.NOTES
    Requires PowerShell 5.1+ with .NET's System.Security.Cryptography.
    Replace $orgUrl, $clientId, and $clientSecret before running.
#>

# ---- Configuration ---------------------------------------------------------

$orgUrl       = "https://integrator-8880746.okta.com"
$clientId     = "YOUR_CLIENT_ID"
$clientSecret = "YOUR_CLIENT_SECRET"
$scope        = "iamlab:invoke"

$tokenUrl = "$orgUrl/oauth2/default/v1/token"
$jwksUrl  = "$orgUrl/oauth2/default/v1/keys"

# ---- Helpers ----------------------------------------------------------------

function Convert-ToBase64Url {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Convert-FromBase64Url {
    param([string]$Base64Url)
    $s = $Base64Url.Replace('-', '+').Replace('_', '/')
    switch ($s.Length % 4) {
        2 { $s += '==' }
        3 { $s += '=' }
    }
    [Convert]::FromBase64String($s)
}

function New-DpopProof {
    param(
        [System.Security.Cryptography.ECDsa]$Ecdsa,
        [string]$HeaderB64,
        [string]$TokenUrl,
        [string]$Nonce = $null
    )

    $payloadObj = @{
        jti = [guid]::NewGuid().ToString()
        htm = "POST"
        htu = $TokenUrl
        iat = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    if ($Nonce) { $payloadObj["nonce"] = $Nonce }

    $payloadJson = $payloadObj | ConvertTo-Json -Compress
    $payloadB64  = Convert-ToBase64Url ([System.Text.Encoding]::UTF8.GetBytes($payloadJson))

    $signingInput   = "$HeaderB64.$payloadB64"
    $signatureBytes = $Ecdsa.SignData(
        [System.Text.Encoding]::UTF8.GetBytes($signingInput),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    $signatureB64 = Convert-ToBase64Url $signatureBytes

    return "$signingInput.$signatureB64"
}

function Invoke-TokenRequest {
    param([hashtable]$Headers, [string]$Body)
    try {
        $resp = Invoke-RestMethod -Method Post -Uri $tokenUrl -Headers $Headers -Body $Body
        return @{ Success = $true; Response = $resp }
    } catch {
        $errResp = $_.Exception.Response
        $reader  = New-Object System.IO.StreamReader($errResp.GetResponseStream())
        $errBody = $reader.ReadToEnd()
        $nonce   = $errResp.Headers["DPoP-Nonce"]
        return @{ Success = $false; ErrorBody = $errBody; Nonce = $nonce }
    }
}

# ---- Step 1: Build the Basic Auth header ------------------------------------

$pair    = "$($clientId):$($clientSecret)"
$base64  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pair))
$headers = @{
    Authorization  = "Basic $base64"
    "Content-Type" = "application/x-www-form-urlencoded"
}
$body = "grant_type=client_credentials&scope=$scope"

# ---- Step 2: First attempt, no DPoP proof (expected to fail) ---------------

Write-Host "`n[1] Requesting token without DPoP proof..." -ForegroundColor Cyan
$attempt1 = Invoke-TokenRequest -Headers $headers -Body $body
if (-not $attempt1.Success) {
    Write-Host "Rejected as expected: $($attempt1.ErrorBody)" -ForegroundColor Yellow
}

# ---- Step 3: Generate DPoP key pair and retry with a signed proof ----------

Write-Host "`n[2] Generating EC (P-256) key pair and signing DPoP proof..." -ForegroundColor Cyan
$ecdsa  = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
$params = $ecdsa.ExportParameters($false)

$jwk = @{
    kty = "EC"
    crv = "P-256"
    x   = Convert-ToBase64Url $params.Q.X
    y   = Convert-ToBase64Url $params.Q.Y
} | ConvertTo-Json -Compress

$header = @{
    typ = "dpop+jwt"
    alg = "ES256"
    jwk = ($jwk | ConvertFrom-Json)
} | ConvertTo-Json -Compress -Depth 5

$headerB64 = Convert-ToBase64Url ([System.Text.Encoding]::UTF8.GetBytes($header))

$headers["DPoP"] = New-DpopProof -Ecdsa $ecdsa -HeaderB64 $headerB64 -TokenUrl $tokenUrl

Write-Host "Retrying with DPoP proof attached..." -ForegroundColor Cyan
$attempt2 = Invoke-TokenRequest -Headers $headers -Body $body
if (-not $attempt2.Success) {
    Write-Host "Rejected again (expected): $($attempt2.ErrorBody)" -ForegroundColor Yellow
}

# ---- Step 4: Rebuild proof with server-issued nonce, final retry -----------

$dpopNonce = $attempt2.Nonce
Write-Host "`n[3] Nonce received: $dpopNonce" -ForegroundColor Cyan
Write-Host "Rebuilding proof with nonce and retrying..." -ForegroundColor Cyan

$headers["DPoP"] = New-DpopProof -Ecdsa $ecdsa -HeaderB64 $headerB64 -TokenUrl $tokenUrl -Nonce $dpopNonce

$final = Invoke-TokenRequest -Headers $headers -Body $body
if (-not $final.Success) {
    Write-Host "Token request failed: $($final.ErrorBody)" -ForegroundColor Red
    return
}

$response = $final.Response
Write-Host "`nToken issued:" -ForegroundColor Green
$response | Format-List

# ---- Step 5: Decode the token (no verification yet) -------------------------

Write-Host "`n[4] Decoding token header and payload..." -ForegroundColor Cyan

$accessToken = $response.access_token
$tokenParts  = $accessToken.Split('.')

$headerJson  = [System.Text.Encoding]::UTF8.GetString((Convert-FromBase64Url $tokenParts[0]))
$payloadJson = [System.Text.Encoding]::UTF8.GetString((Convert-FromBase64Url $tokenParts[1]))

Write-Host "HEADER:" -ForegroundColor Cyan
$headerJson | ConvertFrom-Json | Format-List

Write-Host "PAYLOAD:" -ForegroundColor Cyan
$payloadJson | ConvertFrom-Json | Format-List

# ---- Step 6: Fetch JWKS and independently verify the signature -------------

Write-Host "`n[5] Fetching JWKS and verifying signature..." -ForegroundColor Cyan

$jwks        = Invoke-RestMethod -Uri $jwksUrl
$headerObj   = $headerJson | ConvertFrom-Json
$matchingKey = $jwks.keys | Where-Object { $_.kid -eq $headerObj.kid }

if (-not $matchingKey) {
    Write-Host "No matching key found in JWKS for kid: $($headerObj.kid)" -ForegroundColor Red
    return
}

$modulus  = Convert-FromBase64Url $matchingKey.n
$exponent = Convert-FromBase64Url $matchingKey.e

$rsa = [System.Security.Cryptography.RSA]::Create()
$rsaParams = New-Object System.Security.Cryptography.RSAParameters
$rsaParams.Modulus  = $modulus
$rsaParams.Exponent = $exponent
$rsa.ImportParameters($rsaParams)

$signingInputBytes = [System.Text.Encoding]::UTF8.GetBytes("$($tokenParts[0]).$($tokenParts[1])")
$signatureBytes    = Convert-FromBase64Url $tokenParts[2]

$isValid = $rsa.VerifyData(
    $signingInputBytes,
    $signatureBytes,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
)

if ($isValid) {
    Write-Host "`nSIGNATURE VALID - Token was genuinely issued by Okta" -ForegroundColor Green
} else {
    Write-Host "`nSIGNATURE INVALID" -ForegroundColor Red
}