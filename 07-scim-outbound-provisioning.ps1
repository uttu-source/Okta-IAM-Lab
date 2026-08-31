<#
.SYNOPSIS
    Minimal SCIM 2.0 server for testing Okta outbound provisioning.
    Implements enough of RFC 7644 to handle Okta's "Test API Credentials"
    check plus real user create / read / update / deactivate / delete.
 
.USAGE
    powershell ./scim-server.ps1 -Port 8888 -ApiToken "some-secret-value"
    Requires Windows PowerShell 5.1+ (no PowerShell 7-only cmdlets used).
 
    Expose it publicly with ngrok, rewriting the Host header so it matches
    what HttpListener is registered for:
        ngrok http --host-header=rewrite 8888
 
    Point Okta's Provisioning > Integration > Base URL at
    <ngrok-url>/scim/v2, with the API Token field set to the same value as
    -ApiToken above. Note: Okta's "SCIM 2.0 Test App (Header Auth)" sends
    the token as a raw Authorization header value with no "Bearer " prefix,
    so Test-Auth below accepts both forms.
#>
 
param(
    [int]$Port = 8888,
    [string]$ApiToken = "IAMLab-SCIM-Secret-2026"
)
 
# In-memory user store. Resets every time the server restarts -
# that's expected for a lab test harness, not a bug.
$Script:Users = @{}
 
function Get-Timestamp {
    (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}
 
function ConvertTo-ScimUser {
    param($User)
    [ordered]@{
        schemas  = @("urn:ietf:params:scim:schemas:core:2.0:User")
        id       = $User.id
        userName = $User.userName
        name     = [ordered]@{
            givenName  = $User.givenName
            familyName = $User.familyName
        }
        emails   = @(
            [ordered]@{ value = $User.email; primary = $true }
        )
        active   = $User.active
        meta     = [ordered]@{
            resourceType = "User"
            created      = $User.created
            lastModified = $User.lastModified
            location     = "/scim/v2/Users/$($User.id)"
        }
    }
}
 
function Send-Json {
    param($Context, [int]$StatusCode, $Body)
    $json = $Body | ConvertTo-Json -Depth 10
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = "application/scim+json"
    $Context.Response.ContentLength64 = $buffer.Length
    $Context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Context.Response.OutputStream.Close()
}
 
function Send-ScimError {
    param($Context, [int]$StatusCode, [string]$Detail)
    Send-Json -Context $Context -StatusCode $StatusCode -Body ([ordered]@{
        schemas = @("urn:ietf:params:scim:api:messages:2.0:Error")
        status  = "$StatusCode"
        detail  = $Detail
    })
}
 
function Read-Body {
    param($Request)
    if (-not $Request.HasEntityBody) { return $null }
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    $raw = $reader.ReadToEnd()
    $reader.Close()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}
 
function Test-Auth {
    param($Context)
    $authHeader = $Context.Request.Headers["Authorization"]
    if ($authHeader -ne "Bearer $ApiToken" -and $authHeader -ne $ApiToken) {
        Send-ScimError -Context $Context -StatusCode 401 -Detail "Invalid or missing bearer token"
        return $false
    }
    return $true
}
 
function Get-ServiceProviderConfig {
    [ordered]@{
        schemas           = @("urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig")
        patch             = [ordered]@{ supported = $true }
        bulk              = [ordered]@{ supported = $false; maxOperations = 0; maxPayloadSize = 0 }
        filter            = [ordered]@{ supported = $true; maxResults = 200 }
        changePassword    = [ordered]@{ supported = $false }
        sort              = [ordered]@{ supported = $false }
        etag              = [ordered]@{ supported = $false }
        authenticationSchemes = @(
            [ordered]@{
                type        = "oauthbearertoken"
                name        = "OAuth Bearer Token"
                description = "Authentication via static bearer token"
                primary     = $true
            }
        )
    }
}
 
function Get-ResourceTypes {
    [ordered]@{
        schemas    = @("urn:ietf:params:scim:api:messages:2.0:ListResponse")
        totalResults = 1
        Resources  = @(
            [ordered]@{
                schemas     = @("urn:ietf:params:scim:schemas:core:2.0:ResourceType")
                id          = "User"
                name        = "User"
                endpoint    = "/Users"
                schema      = "urn:ietf:params:scim:schemas:core:2.0:User"
            }
        )
    }
}
 
function Handle-Request {
    param($Context)
 
    $req    = $Context.Request
    $method = $req.HttpMethod
    $path   = $req.Url.AbsolutePath.TrimEnd('/')
    $query  = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query)
 
    Write-Host "$(Get-Timestamp)  $method  $path$($req.Url.Query)" -ForegroundColor Cyan
 
    # ServiceProviderConfig / ResourceTypes are unauthenticated capability
    # discovery endpoints per the SCIM spec - Okta may probe these before
    # sending the bearer token on the Users calls.
    if ($path -eq "/scim/v2/ServiceProviderConfig" -and $method -eq "GET") {
        Send-Json -Context $Context -StatusCode 200 -Body (Get-ServiceProviderConfig)
        return
    }
    if ($path -eq "/scim/v2/ResourceTypes" -and $method -eq "GET") {
        Send-Json -Context $Context -StatusCode 200 -Body (Get-ResourceTypes)
        return
    }
 
    if (-not (Test-Auth -Context $Context)) { return }
 
    # GET /scim/v2/Users?filter=userName eq "value"
    if ($path -eq "/scim/v2/Users" -and $method -eq "GET") {
        $filter = $query["filter"]
        $matches = $Script:Users.Values
        if ($filter -match 'userName\s+eq\s+"([^"]+)"') {
            $target = $Matches[1]
            $matches = $Script:Users.Values | Where-Object { $_.userName -eq $target }
        }
        $resources = @($matches | ForEach-Object { ConvertTo-ScimUser $_ })
        Send-Json -Context $Context -StatusCode 200 -Body ([ordered]@{
            schemas      = @("urn:ietf:params:scim:api:messages:2.0:ListResponse")
            totalResults = $resources.Count
            startIndex   = 1
            itemsPerPage = $resources.Count
            Resources    = $resources
        })
        return
    }
 
    # POST /scim/v2/Users
    if ($path -eq "/scim/v2/Users" -and $method -eq "POST") {
        $body = Read-Body -Request $req
        if (-not $body -or -not $body.userName) {
            Send-ScimError -Context $Context -StatusCode 400 -Detail "userName is required"
            return
        }
        $existing = $Script:Users.Values | Where-Object { $_.userName -eq $body.userName }
        if ($existing) {
            Send-ScimError -Context $Context -StatusCode 409 -Detail "User already exists"
            return
        }
        $id  = [guid]::NewGuid().ToString()
        $now = Get-Timestamp
        $user = @{
            id          = $id
            userName    = $body.userName
            givenName   = $body.name.givenName
            familyName  = $body.name.familyName
            email       = if ($body.emails -and $body.emails.Count -gt 0) { $body.emails[0].value } else { $null }
            active      = if ($null -ne $body.active) { $body.active } else { $true }
            created     = $now
            lastModified = $now
        }
        $Script:Users[$id] = $user
        Write-Host "  -> created user '$($user.userName)' (id: $id)" -ForegroundColor Green
        Send-Json -Context $Context -StatusCode 201 -Body (ConvertTo-ScimUser $user)
        return
    }
 
    # /scim/v2/Users/{id}
    if ($path -match '^/scim/v2/Users/([^/]+)$') {
        $id = $Matches[1]
 
        if ($method -eq "GET") {
            if (-not $Script:Users.ContainsKey($id)) {
                Send-ScimError -Context $Context -StatusCode 404 -Detail "User not found"
                return
            }
            Send-Json -Context $Context -StatusCode 200 -Body (ConvertTo-ScimUser $Script:Users[$id])
            return
        }
 
        if ($method -eq "PUT") {
            if (-not $Script:Users.ContainsKey($id)) {
                Send-ScimError -Context $Context -StatusCode 404 -Detail "User not found"
                return
            }
            $body = Read-Body -Request $req
            $user = $Script:Users[$id]
            $user.userName     = $body.userName
            $user.givenName    = $body.name.givenName
            $user.familyName   = $body.name.familyName
            $user.email        = if ($body.emails -and $body.emails.Count -gt 0) { $body.emails[0].value } else { $user.email }
            $user.active       = if ($null -ne $body.active) { $body.active } else { $user.active }
            $user.lastModified = Get-Timestamp
            Send-Json -Context $Context -StatusCode 200 -Body (ConvertTo-ScimUser $user)
            return
        }
 
        if ($method -eq "PATCH") {
            if (-not $Script:Users.ContainsKey($id)) {
                Send-ScimError -Context $Context -StatusCode 404 -Detail "User not found"
                return
            }
            $body = Read-Body -Request $req
            $user = $Script:Users[$id]
            foreach ($op in $body.Operations) {
                if ($op.path -eq "active") {
                    $user.active = [bool]$op.value
                    Write-Host "  -> $($user.userName) active set to $($user.active)" -ForegroundColor Yellow
                }
                elseif (-not $op.path -and $op.value.PSObject.Properties.Name -contains "active") {
                    $user.active = [bool]$op.value.active
                    Write-Host "  -> $($user.userName) active set to $($user.active)" -ForegroundColor Yellow
                }
            }
            $user.lastModified = Get-Timestamp
            Send-Json -Context $Context -StatusCode 200 -Body (ConvertTo-ScimUser $user)
            return
        }
 
        if ($method -eq "DELETE") {
            if (-not $Script:Users.ContainsKey($id)) {
                Send-ScimError -Context $Context -StatusCode 404 -Detail "User not found"
                return
            }
            $Script:Users.Remove($id)
            $Context.Response.StatusCode = 204
            $Context.Response.OutputStream.Close()
            return
        }
    }
 
    Send-ScimError -Context $Context -StatusCode 404 -Detail "Route not found: $method $path"
}
 
Add-Type -AssemblyName System.Web
 
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
 
Write-Host "SCIM 2.0 test server listening on http://localhost:$Port/scim/v2" -ForegroundColor Green
Write-Host "Bearer token: $ApiToken" -ForegroundColor Green
Write-Host "Press Ctrl+C to stop.`n"
 
try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            Handle-Request -Context $context
        }
        catch {
            Write-Host "ERROR handling request: $_" -ForegroundColor Red
            try { Send-ScimError -Context $context -StatusCode 500 -Detail "$_" } catch {}
        }
    }
}
finally {
    $listener.Stop()
}
 