# 05 - Client Credentials Flow with DPoP and JWT Validation via JWKS

## Objective
Implement the OAuth 2.0 Client Credentials grant (machine-to-machine, no user
involved) in Okta, and validate the resulting access token by decoding it and
verifying its signature against the Authorization Server's public JWKS.

## Context
Builds on 01-oidc-web-app.md and 02-access-policy-token-verification.md, which
covered the Authorization Code grant (a user logging in through a browser).
Client Credentials is a different grant entirely: there's no user, no browser,
no redirect. A backend service authenticates as itself using a client ID and
secret, directly against the token endpoint.

## What I Built

1. Created a new **API Services** app integration in Okta named
   **IAM Lab Service Client**, separate from the existing OIDC web app, since
   a service-to-service integration shouldn't share an app registration with
   a user-facing one.
2. Generated a client secret via the dedicated clipboard icon and stored it
   outside the repo.
3. Added a new **Access Policy** (`IAM Lab Service Client Policy`) on the
   default Authorization Server, scoped specifically to the IAM Lab Service
   Client app rather than "All clients."
4. Added a rule to that policy (`Client Credentials Rule`) restricted to the
   **Client Credentials** grant type only.
5. Created a custom scope, **`iamlab:invoke`**, since the default scopes
   (`openid`, `profile`, `email`, etc.) are all user-identity scopes and don't
   apply to a machine client with no user attached.
6. Updated the access policy rule to require the specific `iamlab:invoke`
   scope instead of "Any scopes," to keep the client's access explicitly
   least-privilege.

## Issue Encountered #1: Missing DPoP Proof

Requesting a token via PowerShell (`Invoke-RestMethod` against the `/token`
endpoint with Basic Auth) initially failed with:

```json
{"error":"invalid_dpop_proof","error_description":"The DPoP proof JWT header is missing."}
```

Okta's API Services app type enforces **DPoP** (Demonstrating Proof-of-Possession)
by default. Instead of just trusting a bearer token, DPoP requires the client
to sign each token request with a private key it holds, so a stolen token
alone isn't enough to use it, whoever holds it also needs the matching key.

To fix this, I:
- Generated an EC (P-256) key pair in PowerShell using `System.Security.Cryptography.ECDsa`.
- Built a DPoP proof JWT: a header containing the public key as a JWK, and a
  payload containing `jti` (unique ID), `htm` (HTTP method), `htu` (the token
  URL), and `iat` (issued-at timestamp).
- Signed the header+payload with the private key (ES256) and attached the
  result as a `DPoP` header on the token request.

## Issue Encountered #2: Missing Nonce

Retrying with the signed DPoP proof attached produced a second, different error:

```json
{"error":"use_dpop_nonce","error_description":"Authorization server requires nonce in DPoP proof."}
```

This is a normal part of the DPoP protocol, not a misconfiguration. Okta
requires a server-issued nonce inside the proof to prevent an attacker from
pre-computing a valid proof and replaying it later. The nonce comes back in
a `DPoP-Nonce` response header on the rejected request.

Fix: read the `DPoP-Nonce` header from the failed response, rebuild the proof
JWT with a fresh `jti`, fresh `iat`, and the `nonce` claim added, sign it
again with the same private key, and retry. That request succeeded:

```
token_type: DPoP
expires_in: 3600
access_token: eyJraWQiOi...
```

The `token_type` returned is literally `DPoP`, not `Bearer`, marking the
token as proof-of-possession bound.

## JWT Validation via JWKS

To confirm the access token was genuinely issued by Okta rather than just
trusting it, I decoded and independently verified it:

1. Split the JWT into header/payload/signature and Base64URL-decoded the
   header and payload (JWTs are encoded, not encrypted, so this doesn't
   require a key).
2. Header revealed `kid` (the specific signing key ID) and `alg: RS256`.
3. Payload revealed the claims Okta issued, notably:
   - `cid` and `sub` both equal the client ID (`0oa168ire3fKAL7Fb698`),
     confirming the client is the subject, since there's no user.
   - `scp: {iamlab:invoke}`, confirming the scope restriction worked as
     configured.
   - `cnf: {jkt=...}`, the confirmation claim: a thumbprint of the DPoP
     public key, cryptographically bound into the token. This is the
     mechanical reason the token is DPoP-bound instead of a plain bearer
     token, any resource server receiving it must verify a fresh DPoP proof
     matching this thumbprint before honoring the token.
4. Fetched Okta's public key set from `/oauth2/default/v1/keys` and found
   the key matching the token's `kid`.
5. Rebuilt an RSA public key from that JWKS entry's `n` (modulus) and `e`
   (exponent), then used `RSA.VerifyData()` to verify the token's signature
   against the `header.payload` bytes.

Result: `SIGNATURE VALID - Token was genuinely issued by Okta`.

## Verification
- PowerShell output confirmed `token_type: DPoP` on successful token issuance.
- Decoded payload confirmed `scp`, `cid`/`sub`, and `cnf.jkt` claims matched
  expected values.
- Independent RSA signature verification against the JWKS returned valid.
- Full run output, both DPoP rejections through final signature verification,
  captured in a single unedited execution:
  (Screenshot: 05-full-run-output.png)
- The complete PowerShell script used to reproduce this flow is included in
  this repo as `05-client-credentials-dpop-jwt-validation.ps1`.

## Post-Entry Cleanup
The client secret was visible in plaintext in an earlier working screenshot.
Generated a new secret via the clipboard icon, deactivated the exposed one,
and re-validated the full token flow against the new secret before treating
the entry as complete.

## Key Takeaway
Client Credentials has no user in the loop, the client authenticates as
itself. DPoP adds a second layer on top of that: even a valid client secret
isn't enough to get a usable token without also proving possession of a
private key via a signed, nonce-bound proof JWT. A resource server can verify
that binding, and the token's own signature, entirely offline using the
Authorization Server's published JWKS, without ever calling back to Okta.
