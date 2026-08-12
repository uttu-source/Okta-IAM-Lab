<#
.SYNOPSIS
    OIDC Authorization Code grant with PKCE against a public (no-secret) SPA
    client in Okta, followed by a refresh token exchange.

.DESCRIPTION
    Companion script to Entry 06 of the Okta-IAM-Lab repo.

    Flow:
      1. Generate a cryptographically random code_verifier.
      2. Derive code_challenge = Base64URL(SHA256(code_verifier)).
      3. Build the /authorize URL with the code_challenge and open it in the
         default browser. User logs in; Okta redirects to a non-listening
         localhost callback with an authorization code in the query string.
      4. Exchange the authorization code for tokens at /token, sending the
         original code_verifier instead of a client secret. Errors are
         caught and their JSON body printed, since Okta's actual error
         detail (e.g. invalid_grant / PKCE verification failed) is not
         surfaced by Invoke-RestMethod's default exception message.
      5. Use the returned refresh_token to request a new access token via a
         separate grant_type=refresh_token call. No browser interaction and
         no code_verifier are required for this step, since the refresh
         token itself is the proof of trust.

.NOTES
    Requires PowerShell 5.1+ with .NET's System.Security.Cryptography.
    Uses RNGCryptoServiceProvider rather than RandomNumberGenerator::Fill(),
    since the latter is only available on .NET Core/.NET 5+ and throws
    MethodNotFound under Windows PowerShell 5.1's .NET Framework runtime.
    Replace $orgUrl, $clientId, and $redirectUri before running.
#>

# ---- Configuration ---------------------------------------------------------

$orgUrl       = "https://YOUR_OKTA_ORG.okta.com"
$clientId     = "YOUR_SPA_CLIENT_ID"
$redirectUri  = "http://localhost:8080/login/callback"
$scope        = "openid profile offline_access"
$state        = "abc123"

$authUrl  = "$orgUrl/oauth2/default/v1/authorize"
$tokenUrl = "$orgUrl/oauth2/default/v1/token"

# ---- Helpers ----------------------------------------------------------------

function Convert-ToBase64Url {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Invoke-TokenRequest {
    param([hashtable]$Body)
    try {
        $resp = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $Body -ContentType "application/x-www-form-urlencoded"
        return @{ Success = $true; Response = $resp }
    } catch {
        $errResp = $_.Exception.Response
        $reader  = New-Object System.IO.StreamReader($errResp.GetResponseStream())
        $errBody = $reader.ReadToEnd()
        return @{ Success = $false; ErrorBody = $errBody }
    }
}

# ---- Step 1: Generate code_verifier and code_challenge ---------------------

Write-Host "`n[1] Generating PKCE code_verifier and code_challenge..." -ForegroundColor Cyan

$rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
$verifierBytes = [byte[]]::new(32)
$rng.GetBytes($verifierBytes)
$codeVerifier = Convert-ToBase64Url $verifierBytes

$sha256 = [System.Security.Cryptography.SHA256]::Create()
$verifierBytesForHash = [System.Text.Encoding]::ASCII.GetBytes($codeVerifier)
$hashBytes = $sha256.ComputeHash($verifierBytesForHash)
$codeChallenge = Convert-ToBase64Url $hashBytes

Write-Host "code_verifier:  $codeVerifier"
Write-Host "code_challenge: $codeChallenge"

# ---- Step 2: Build and open the /authorize URL ------------------------------

Write-Host "`n[2] Opening /authorize in default browser..." -ForegroundColor Cyan

$encodedScope = [uri]::EscapeDataString($scope)
$fullAuthUrl = "$authUrl`?client_id=$clientId&response_type=code&scope=$encodedScope&redirect_uri=$redirectUri&state=$state&code_challenge=$codeChallenge&code_challenge_method=S256"

Write-Host "Authorize URL:`n$fullAuthUrl"
Start-Process $fullAuthUrl

Write-Host "`nLog in, then copy the 'code' value from the failed localhost redirect URL." -ForegroundColor Yellow
$code = Read-Host "Paste the authorization code here"

# ---- Step 3: Exchange the authorization code for tokens ---------------------

Write-Host "`n[3] Exchanging authorization code for tokens..." -ForegroundColor Cyan

$tokenBody = @{
    grant_type    = "authorization_code"
    client_id     = $clientId
    redirect_uri  = $redirectUri
    code          = $code
    code_verifier = $codeVerifier
}

$tokenResult = Invoke-TokenRequest -Body $tokenBody

if (-not $tokenResult.Success) {
    Write-Host "Token exchange failed: $($tokenResult.ErrorBody)" -ForegroundColor Red
    return
}

$response = $tokenResult.Response
Write-Host "`nToken issued:" -ForegroundColor Green
$response | Format-List

# ---- Step 4: Use the refresh_token to get a new access token ---------------

Write-Host "`n[4] Exchanging refresh_token for a new access token..." -ForegroundColor Cyan

$refreshBody = @{
    grant_type    = "refresh_token"
    client_id     = $clientId
    refresh_token = $response.refresh_token
}

$refreshResult = Invoke-TokenRequest -Body $refreshBody

if (-not $refreshResult.Success) {
    Write-Host "Refresh token exchange failed: $($refreshResult.ErrorBody)" -ForegroundColor Red
    return
}

Write-Host "`nRefreshed token (new access_token and rotated refresh_token):" -ForegroundColor Green
$refreshResult.Response | Format-List